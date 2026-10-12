<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$failures = [];
$checks = 0;

function check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label — $detail";
        echo "  [FAIL] $label — $detail\n";
    }
}

function edge_session(string $baseUrl, string $suffix): array
{
    [, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => "prop-net-edges-$suffix",
        'unit_id' => "unit-net-edges-$suffix",
        'organisation_id' => 'org-net-edges',
        'purpose' => 'listing',
        'occupied' => false,
        'floor' => 'Ground',
    ]);
    return [$session['id'] ?? '', $session['access_token'] ?? ''];
}

function edge_capture(array $fixture, string $group, array $origin, ?string $joinedTo = null): array
{
    $capture = $fixture;
    $capture['capture_group_id'] = $group;
    $capture['structure_origin_m'] = $origin;
    if ($joinedTo !== null) {
        $capture['joined_to_group_id'] = $joinedTo;
    }
    return $capture;
}

function edge_room(array $plan, string $group, string $floor): ?array
{
    foreach ($plan['rooms'] ?? [] as $room) {
        if (($room['capture_group_id'] ?? null) === $group && ($room['floor'] ?? null) === $floor) {
            return $room;
        }
    }
    return null;
}

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

echo "== Continuing a scan after its link was refreshed ==\n";
[$rotId, $oldToken] = edge_session($baseUrl, 'rotate');
[, $first] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/capture", ['raw_capture' => edge_capture($fixture, 'walk-A', [0.0, 0.0]), 'floor' => 'Ground'], $oldToken);
$firstRoomId = $first['rooms'][0]['room_id'] ?? null;
check('the first scan is saved', $firstRoomId !== null, json_encode($first));
[$rotateStatus, $rotated] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/rotate-token", [], $oldToken);
$newToken = $rotated['access_token'] ?? '';
check('the link is refreshed', $rotateStatus === 200 && $newToken !== '' && $newToken !== $oldToken, "got HTTP $rotateStatus");
[$oldStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/rooms", ['captures' => [['raw_capture' => edge_capture($fixture, 'walk-B', [4.0, 0.0], 'walk-A'), 'floor' => 'Ground']]], $oldToken);
check('the old token can no longer continue the scan', in_array($oldStatus, [401, 403], true), "got HTTP $oldStatus");
[$continueStatus, $continued] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/rooms", ['captures' => [['raw_capture' => edge_capture($fixture, 'walk-B', [4.0, 0.0], 'walk-A'), 'floor' => 'Ground']]], $newToken);
check('the new token continues the scan', $continueStatus === 200, "got HTTP $continueStatus");
check('the earlier room is kept', count($continued['rooms'] ?? []) === 2 && ($continued['rooms'][0]['room_id'] ?? null) === $firstRoomId, json_encode(array_column($continued['rooms'] ?? [], 'room_id')));
check('the new room is joined to the first scan', (edge_room($continued, 'walk-B', 'Ground')['joined_to_group_id'] ?? null) === 'walk-A');
$replacement = $fixture;
$replacement['replaces_room_id'] = $firstRoomId;
[$replaceStatus, $replaced] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/capture", ['raw_capture' => $replacement, 'floor' => 'Ground'], $newToken);
check('replace still works with the new token', $replaceStatus === 200 && count($replaced['rooms'] ?? []) === 2 && ($replaced['rooms'][0]['room_id'] ?? null) === $firstRoomId, "got HTTP $replaceStatus");
[, $activityNew] = net_http_json('POST', "$baseUrl/scan-sessions/activity", ['sessions' => [['id' => $rotId, 'token' => $newToken]]]);
check('Home and History see both rooms with the new token', count($activityNew['sessions'][0]['rooms'] ?? []) === 2, json_encode($activityNew));
[, $activityOld] = net_http_json('POST', "$baseUrl/scan-sessions/activity", ['sessions' => [['id' => $rotId, 'token' => $oldToken]]]);
check('the old token sees nothing', ($activityOld['sessions'] ?? null) === [], json_encode($activityOld));

echo "\n== A replace answered after the room was deleted falls back to a new room ==\n";
$secondRoomId = edge_room($replaced, 'walk-B', 'Ground')['room_id'] ?? '';
[$deleteStatus] = net_http_json('DELETE', "$baseUrl/scan-sessions/$rotId/rooms/$secondRoomId", null, $newToken);
check('the room is deleted elsewhere', $deleteStatus === 200, "got HTTP $deleteStatus");
$stale = $fixture;
$stale['replaces_room_id'] = $secondRoomId;
[$staleStatus, $staleBody] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/capture", ['raw_capture' => $stale, 'floor' => 'Ground'], $newToken);
check('replacing the deleted room is refused with unknown_room_id', $staleStatus === 422 && ($staleBody['error'] ?? null) === 'unknown_room_id', "got HTTP $staleStatus " . json_encode($staleBody));
[$plainStatus, $plainBody] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/capture", ['raw_capture' => $fixture, 'floor' => 'Ground'], $newToken);
check('the same scan without the replace is added as a new room', $plainStatus === 200 && count($plainBody['rooms'] ?? []) === 2, "got HTTP $plainStatus, " . count($plainBody['rooms'] ?? []) . ' rooms');
$moved = $fixture;
$moved['replaces_room_id'] = $firstRoomId;
[$movedStatus, $movedBody] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/capture", ['raw_capture' => $moved, 'floor' => 'Attic'], $newToken);
check('replacing a room that is on another floor now is refused with replace_floor_mismatch', $movedStatus === 409 && ($movedBody['error'] ?? null) === 'replace_floor_mismatch', "got HTTP $movedStatus " . json_encode($movedBody));
[, $afterRefused] = net_http_json('GET', "$baseUrl/scan-sessions/$rotId", null, $newToken);
check('nothing was changed by the refused replace', count($afterRefused['rooms'] ?? []) === 2 && ($afterRefused['rooms'][0]['room_id'] ?? null) === $firstRoomId && ($afterRefused['rooms'][0]['floor'] ?? null) === 'Ground', json_encode(array_column($afterRefused['rooms'] ?? [], 'floor')));

echo "\n== Replace from a whole-unit continue (POST /rooms) ==\n";
[$unitId, $unitToken] = edge_session($baseUrl, 'unit-replace');
[, $unitFirst] = net_http_json('POST', "$baseUrl/scan-sessions/$unitId/capture", ['raw_capture' => edge_capture($fixture, 'walk-U', [0.0, 0.0]), 'floor' => 'Attic'], $unitToken);
$unitRoomId = $unitFirst['rooms'][0]['room_id'] ?? '';
[$labelStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$unitId/rooms/$unitRoomId/label", ['label' => 'Master bedroom'], $unitToken);
check('the room is named by the user', $labelStatus === 200, "got HTTP $labelStatus");
$sameFloor = edge_capture($fixture, 'walk-V', [0.0, 0.0]);
$sameFloor['replaces_room_id'] = $unitRoomId;
[$sameStatus, $samePlan] = net_http_json('POST', "$baseUrl/scan-sessions/$unitId/rooms", ['captures' => [['raw_capture' => $sameFloor, 'floor' => 'Attic']]], $unitToken);
check('replacing on the same floor is accepted', $sameStatus === 200 && count($samePlan['rooms'] ?? []) === 1, "got HTTP $sameStatus");
check('the replaced room keeps its name', ($samePlan['rooms'][0]['label'] ?? null) === 'Master bedroom', json_encode($samePlan['rooms'][0]['label'] ?? null));
check('the replaced room keeps its id', ($samePlan['rooms'][0]['room_id'] ?? null) === $unitRoomId);
$otherFloor = edge_capture($fixture, 'walk-W', [0.0, 0.0]);
$otherFloor['replaces_room_id'] = $unitRoomId;
[$otherStatus, $otherPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$unitId/rooms", ['captures' => [['raw_capture' => $otherFloor, 'floor' => 'Ground']]], $unitToken);
check('a replace onto a room on another floor does not fail the upload', $otherStatus === 200, "got HTTP $otherStatus " . json_encode($otherPlan));
check('the Attic room is kept with its name', (edge_room($otherPlan, 'walk-V', 'Attic')['label'] ?? null) === 'Master bedroom', json_encode(array_column($otherPlan['rooms'] ?? [], 'label')));
$groundRoom = edge_room($otherPlan, 'walk-W', 'Ground');
check('the scan is added as a new Ground room with its own id', $groundRoom !== null && ($groundRoom['room_id'] ?? null) !== $unitRoomId, json_encode($groundRoom['room_id'] ?? null));
$goneTarget = edge_capture($fixture, 'walk-X', [0.0, 0.0]);
$goneTarget['replaces_room_id'] = 'room-that-was-deleted';
[$goneStatus, $gonePlan] = net_http_json('POST', "$baseUrl/scan-sessions/$unitId/rooms", ['captures' => [['raw_capture' => $goneTarget, 'floor' => 'Ground']]], $unitToken);
check('a replace onto a deleted room does not fail the upload', $goneStatus === 200 && count($gonePlan['rooms'] ?? []) === 3, "got HTTP $goneStatus");
check('the deleted id is not brought back', !in_array('room-that-was-deleted', array_column($gonePlan['rooms'] ?? [], 'room_id'), true), json_encode(array_column($gonePlan['rooms'] ?? [], 'room_id')));

echo "\n== Continuing a notes-only scan ==\n";
[$noteId, $noteToken] = edge_session($baseUrl, 'notes');
[$markStatus, $marked] = net_http_json('POST', "$baseUrl/scan-sessions/$noteId/note-only", null, $noteToken);
check('the scan is saved as notes only', $markStatus === 200 && ($marked['rooms'] ?? null) === [], "got HTTP $markStatus");
[$noteStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$noteId/notes", ['text' => 'meter cupboard by the door'], $noteToken);
check('a note is attached', $noteStatus === 201, "got HTTP $noteStatus");
[, $activityNotes] = net_http_json('POST', "$baseUrl/scan-sessions/activity", ['sessions' => [['id' => $noteId, 'token' => $noteToken]]]);
check('Home and History see zero rooms', ($activityNotes['sessions'][0]['rooms'] ?? null) === [], json_encode($activityNotes));
[$walkStatus, $walked] = net_http_json('POST', "$baseUrl/scan-sessions/$noteId/rooms", ['captures' => [['raw_capture' => edge_capture($fixture, 'walk-N', [0.0, 0.0]), 'floor' => 'Ground']]], $noteToken);
check('a whole-unit continue on a notes-only scan is accepted', $walkStatus === 200, "got HTTP $walkStatus " . json_encode($walked));
check('the scan now has the room', count($walked['rooms'] ?? []) === 1);
check('the note is kept', count($walked['notes'] ?? []) === 1 && ($walked['notes'][0]['text'] ?? null) === 'meter cupboard by the door', json_encode($walked['notes'] ?? null));
[$roomStatus, $added] = net_http_json('POST', "$baseUrl/scan-sessions/$noteId/capture", ['raw_capture' => $fixture, 'floor' => 'Attic'], $noteToken);
check('a single-room continue adds a second room', $roomStatus === 200 && count($added['rooms'] ?? []) === 2, "got HTTP $roomStatus");
check('the note is still kept', count($added['notes'] ?? []) === 1);
[, $activityAfter] = net_http_json('POST', "$baseUrl/scan-sessions/activity", ['sessions' => [['id' => $noteId, 'token' => $noteToken]]]);
check('Home and History now see two rooms on two floors', array_column($activityAfter['sessions'][0]['rooms'] ?? [], 'floor') === ['Ground', 'Attic'], json_encode($activityAfter));

echo "\n== Rooms placed by hand across two floors ==\n";
[$placeId, $placeToken] = edge_session($baseUrl, 'place');
net_http_json('POST', "$baseUrl/scan-sessions/$placeId/capture", ['raw_capture' => edge_capture($fixture, 'walk-A', [0.0, 0.0]), 'floor' => 'Ground'], $placeToken);
net_http_json('POST', "$baseUrl/scan-sessions/$placeId/capture", ['raw_capture' => edge_capture($fixture, 'walk-B', [0.0, 0.0]), 'floor' => 'Ground'], $placeToken);
[, $setup] = net_http_json('POST', "$baseUrl/scan-sessions/$placeId/capture", ['raw_capture' => edge_capture($fixture, 'walk-B', [0.0, 0.0]), 'floor' => 'Attic'], $placeToken);
check('three rooms on two floors', count($setup['rooms'] ?? []) === 3, (string) count($setup['rooms'] ?? []));
$placementPath = "$baseUrl/scan-sessions/$placeId/groups/walk-B/placement";
[$noFloorStatus, $noFloorBody] = net_http_json('POST', $placementPath, ['rotation_deg' => 0.0, 'translation_m' => [4.0, 0.0], 'join_to_group_id' => 'walk-A'], $placeToken);
check('placing a scan that spans two floors needs a floor', $noFloorStatus === 409 && ($noFloorBody['error'] ?? null) === 'floor_required', "got HTTP $noFloorStatus " . json_encode($noFloorBody));
[$groundStatus, $ground] = net_http_json('POST', $placementPath, ['rotation_deg' => 0.0, 'translation_m' => [4.0, 0.0], 'join_to_group_id' => 'walk-A', 'floor' => 'Ground'], $placeToken);
check('placing the Ground floor is accepted', $groundStatus === 200, "got HTTP $groundStatus " . json_encode($ground));
check('the Ground room moved', (edge_room($ground, 'walk-B', 'Ground')['structure_origin_m'] ?? null) == [4.0, 0.0], json_encode(edge_room($ground, 'walk-B', 'Ground')['structure_origin_m'] ?? null));
check('the Ground room is joined', (edge_room($ground, 'walk-B', 'Ground')['joined_to_group_id'] ?? null) === 'walk-A');
check('the Attic room did not move', (edge_room($ground, 'walk-B', 'Attic')['structure_origin_m'] ?? null) == [0.0, 0.0], json_encode(edge_room($ground, 'walk-B', 'Attic')['structure_origin_m'] ?? null));
check('the Attic room is not joined', (edge_room($ground, 'walk-B', 'Attic')['joined_to_group_id'] ?? null) === null);
[$atticJoinStatus, $atticJoinBody] = net_http_json('POST', $placementPath, ['rotation_deg' => 0.0, 'translation_m' => [1.0, 1.0], 'join_to_group_id' => 'walk-A', 'floor' => 'Attic'], $placeToken);
check('joining the Attic to a scan with no Attic rooms is refused', $atticJoinStatus !== 200, "got HTTP $atticJoinStatus " . json_encode($atticJoinBody));
[$atticStatus, $attic] = net_http_json('POST', $placementPath, ['rotation_deg' => 0.0, 'translation_m' => [1.0, 1.0], 'floor' => 'Attic'], $placeToken);
check('placing the Attic on its own is accepted', $atticStatus === 200, "got HTTP $atticStatus " . json_encode($attic));
check('the Attic room moved', (edge_room($attic, 'walk-B', 'Attic')['structure_origin_m'] ?? null) == [1.0, 1.0], json_encode(edge_room($attic, 'walk-B', 'Attic')['structure_origin_m'] ?? null));
check('the Ground room stays where it was placed', (edge_room($attic, 'walk-B', 'Ground')['structure_origin_m'] ?? null) == [4.0, 0.0], json_encode(edge_room($attic, 'walk-B', 'Ground')['structure_origin_m'] ?? null));
check('the Ground room stays joined', (edge_room($attic, 'walk-B', 'Ground')['joined_to_group_id'] ?? null) === 'walk-A');
[$pngStatus] = net_http_json('GET', "$baseUrl/scan-sessions/$placeId/export/floorplan.png?floor=Attic", null, $placeToken);
check('the Attic plan still renders', $pngStatus === 200, "got HTTP $pngStatus");

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nNET VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}
echo "\nNET VERDICT: GREEN\n";
exit(0);
