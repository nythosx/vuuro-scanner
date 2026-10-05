<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$failures = [];
$checks = 0;

function rm_check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label - $detail";
        echo "  [FAIL] $label - $detail\n";
    }
}

function rm_room(string $id, ?string $group, array $origin = [0.0, 0.0]): array
{
    return [
        'room_id' => $id, 'label' => $id, 'floor_area_m2' => 12.0, 'perimeter_m' => 14.0,
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0], 'confidence' => 'high',
        'outline_m' => [[0, 0], [4, 0], [4, 3], [0, 3]],
        'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
        'openings' => [], 'objects' => [],
        'structure_origin_m' => $origin, 'capture_group_id' => $group, 'floor' => 'Ground',
    ];
}

function rm_capture(ScanSessionRepository $repo, string $sessionId, array $rooms): void
{
    $repo->appendCapture($sessionId, [
        'scan_session_id' => $sessionId,
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => $rooms, 'photos' => [], 'notes' => [],
    ]);
}

$repo = new ScanSessionRepository(Database::connect(':memory:'));

echo "== Continuing a whole-unit scan keeps the rooms that were already there ==\n";
$session = $repo->create('prop-rm', 'unit-rm', 'org-rm', 'listing', false, false);
$sid = $session['id'];
rm_capture($repo, $sid, [rm_room('a-1', 'walk-A'), rm_room('a-2', 'walk-A', [4.0, 0.0]), rm_room('a-3', 'walk-A', [8.0, 0.0])]);
$repo->appendNote($sid, ['note_id' => 'note-a2', 'text' => 'crack above the door', 'room_id' => 'a-2', 'created_at' => gmdate('c')]);
rm_capture($repo, $sid, [rm_room('b-tile-1', 'walk-B', [0.0, 5.0]), rm_room('b-tile-2', 'walk-B', [4.0, 5.0])]);

$after = $repo->replaceRooms($sid, [rm_room('b-fused-1', 'walk-B', [0.0, 3.0]), rm_room('b-fused-2', 'walk-B', [4.0, 3.0])], 'roomplan', gmdate('c'), ['walk-B']);
$ids = array_column($after['rooms'], 'room_id');
rm_check('the three earlier rooms and the two fused rooms are all there', $ids === ['a-1', 'a-2', 'a-3', 'b-fused-1', 'b-fused-2'], json_encode($ids));
rm_check('the walkthrough tiles are replaced, not kept twice', !in_array('b-tile-1', $ids, true) && !in_array('b-tile-2', $ids, true), json_encode($ids));
rm_check('the note on an earlier room stays attached to it', ($after['notes'][0]['room_id'] ?? null) === 'a-2', json_encode($after['notes']));
$stored = $repo->findFloorPlan($sid);
rm_check('the stored plan has the same five rooms', count($stored['rooms']) === 5, (string) count($stored['rooms']));

echo "\n== A fresh whole-unit scan still ends up with exactly its own rooms ==\n";
$fresh = $repo->create('prop-rm', 'unit-rm-2', 'org-rm', 'listing', false, false);
rm_capture($repo, $fresh['id'], [rm_room('c-tile-1', 'walk-C'), rm_room('c-tile-2', 'walk-C', [4.0, 0.0])]);
$freshAfter = $repo->replaceRooms($fresh['id'], [rm_room('c-fused-1', 'walk-C'), rm_room('c-fused-2', 'walk-C', [4.0, 0.0])], 'roomplan', gmdate('c'), ['walk-C']);
rm_check('only the fused rooms remain', array_column($freshAfter['rooms'], 'room_id') === ['c-fused-1', 'c-fused-2'], json_encode(array_column($freshAfter['rooms'], 'room_id')));

echo "\n== New rooms are placed where the walkthrough tiles were ==\n";
$middle = $repo->create('prop-rm', 'unit-rm-3', 'org-rm', 'listing', false, false);
rm_capture($repo, $middle['id'], [rm_room('d-1', 'walk-D')]);
rm_capture($repo, $middle['id'], [rm_room('e-tile', 'walk-E', [5.0, 0.0])]);
rm_capture($repo, $middle['id'], [rm_room('f-1', null, [10.0, 0.0])]);
$middleAfter = $repo->replaceRooms($middle['id'], [rm_room('e-fused', 'walk-E', [5.0, 0.0])], 'roomplan', gmdate('c'), ['walk-E']);
rm_check('order is kept around the replaced walkthrough', array_column($middleAfter['rooms'], 'room_id') === ['d-1', 'e-fused', 'f-1'], json_encode(array_column($middleAfter['rooms'], 'room_id')));

echo "\n== A new room id that clashes with a kept room is refused ==\n";
$clash = $repo->create('prop-rm', 'unit-rm-4', 'org-rm', 'listing', false, false);
rm_capture($repo, $clash['id'], [rm_room('g-1', 'walk-G')]);
rm_capture($repo, $clash['id'], [rm_room('h-tile', 'walk-H', [5.0, 0.0])]);
$clashError = null;
try {
    $repo->replaceRooms($clash['id'], [rm_room('g-1', 'walk-H', [5.0, 0.0])], 'roomplan', gmdate('c'), ['walk-H']);
} catch (\InvalidArgumentException $e) {
    $clashError = $e->getMessage();
}
rm_check('the clash is refused', $clashError !== null, 'no exception');
rm_check('nothing was saved', array_column($repo->findFloorPlan($clash['id'])['rooms'], 'room_id') === ['g-1', 'h-tile'], json_encode(array_column($repo->findFloorPlan($clash['id'])['rooms'], 'room_id')));

function rm_rescan(string $replacesId, string $group, string $floor, string $label): array
{
    $room = rm_room($replacesId, $group);
    $room['floor'] = $floor;
    $room['label'] = $label;
    return $room;
}

function rm_by_id(array $plan, string $id): ?array
{
    foreach ($plan['rooms'] as $room) {
        if ($room['room_id'] === $id) {
            return $room;
        }
    }
    return null;
}

echo "\n== Replacing a room from a whole-unit continue keeps its name ==\n";
$named = $repo->create('prop-rm-named', 'unit-rm-named', 'org-rm', 'listing', false, false);
rm_capture($repo, $named['id'], [rm_room('k-1', 'walk-K'), rm_room('k-2', 'walk-K', [4.0, 0.0])]);
$repo->updateRoomLabel($named['id'], 'k-1', 'Master bedroom');
$repo->appendNote($named['id'], ['note_id' => 'note-k1', 'text' => 'damp corner', 'room_id' => 'k-1', 'created_at' => gmdate('c')]);
$namedAfter = $repo->replaceRooms($named['id'], [rm_rescan('k-1', 'walk-L', 'Ground', 'Room 1')], 'roomplan', gmdate('c'), ['walk-L'], ['k-1']);
rm_check('the room count stays the same', count($namedAfter['rooms']) === 2, json_encode(array_column($namedAfter['rooms'], 'room_id')));
rm_check('the replaced room keeps the name the user gave it', (rm_by_id($namedAfter, 'k-1')['label'] ?? null) === 'Master bedroom', json_encode(rm_by_id($namedAfter, 'k-1')));
rm_check('the replaced room has the new scan group', (rm_by_id($namedAfter, 'k-1')['capture_group_id'] ?? null) === 'walk-L');
rm_check('its note stays on it', ($namedAfter['notes'][0]['room_id'] ?? null) === 'k-1');
$renamedAfter = $repo->replaceRooms($named['id'], [rm_rescan('k-2', 'walk-M', 'Ground', 'Hallway')], 'roomplan', gmdate('c'), ['walk-M'], ['k-2']);
rm_check('a name chosen during the new scan wins', (rm_by_id($renamedAfter, 'k-2')['label'] ?? null) === 'Hallway');

echo "\n== A replace onto a room that is now on another floor becomes a new room ==\n";
$moved = $repo->create('prop-rm-moved', 'unit-rm-moved', 'org-rm', 'listing', false, false);
$attic = rm_room('m-1', 'walk-N');
$attic['floor'] = 'Attic';
$attic['label'] = 'Room 1';
rm_capture($repo, $moved['id'], [$attic]);
$repo->appendNote($moved['id'], ['note_id' => 'note-m1', 'text' => 'roof window', 'room_id' => 'm-1', 'created_at' => gmdate('c')]);
$movedAfter = $repo->replaceRooms($moved['id'], [rm_rescan('m-1', 'walk-O', 'Ground', 'Room 1')], 'roomplan', gmdate('c'), ['walk-O'], ['m-1']);
$movedIds = array_column($movedAfter['rooms'], 'room_id');
rm_check('the Attic room is kept', (rm_by_id($movedAfter, 'm-1')['floor'] ?? null) === 'Attic', json_encode($movedIds));
rm_check('the scan is added as a second room', count($movedAfter['rooms']) === 2, json_encode($movedIds));
$newRoom = array_values(array_filter($movedAfter['rooms'], static fn ($room) => $room['room_id'] !== 'm-1'))[0] ?? [];
rm_check('the new room gets an id from the server', str_starts_with((string) ($newRoom['room_id'] ?? ''), 'room-rescan-'), (string) ($newRoom['room_id'] ?? ''));
rm_check('the new room is on Ground', ($newRoom['floor'] ?? null) === 'Ground');
rm_check('the new room does not reuse the Attic name', ($newRoom['label'] ?? null) !== 'Room 1', (string) ($newRoom['label'] ?? ''));
rm_check('the Attic note stays on the Attic room', ($movedAfter['notes'][0]['room_id'] ?? null) === 'm-1');
rm_check('the floor check ignores case and spaces', count($repo->replaceRooms($moved['id'], [rm_rescan('m-1', 'walk-P', ' attic ', 'Room 3')], 'roomplan', gmdate('c'), ['walk-P'], ['m-1'])['rooms']) === 2);

echo "\n== A replace onto a room that was deleted becomes a new room ==\n";
$gone = $repo->create('prop-rm-gone', 'unit-rm-gone', 'org-rm', 'listing', false, false);
rm_capture($repo, $gone['id'], [rm_room('q-1', 'walk-Q')]);
$goneAfter = $repo->replaceRooms($gone['id'], [rm_rescan('q-deleted', 'walk-R', 'Ground', 'Room 2')], 'roomplan', gmdate('c'), ['walk-R'], ['q-deleted']);
$goneIds = array_column($goneAfter['rooms'], 'room_id');
rm_check('the existing room is kept and the scan is added', count($goneIds) === 2 && $goneIds[0] === 'q-1', json_encode($goneIds));
rm_check('the deleted id is not brought back', !in_array('q-deleted', $goneIds, true), json_encode($goneIds));

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);
