<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;
use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanStyle;
use VuuroScan\Export\FloorPlanSvgRenderer;
use VuuroScan\RoomSplitter;
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$failures = [];
$checks = 0;

function s_check(string $label, bool $pass, string $detail = ''): void
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

function s_rejects(callable $fn): ?string
{
    try {
        $fn();
    } catch (\InvalidArgumentException $e) {
        return $e->getMessage();
    }
    return null;
}

function s_area(array $points): float
{
    $sum = 0.0;
    $n = count($points);
    for ($i = 0; $i < $n; $i++) {
        $sum += $points[$i][0] * $points[($i + 1) % $n][1] - $points[($i + 1) % $n][0] * $points[$i][1];
    }
    return abs($sum) / 2;
}

$rectangle = [[0, 0], [8.5, 0], [8.5, 3.5], [0, 3.5]];

echo "== Cutting an outline ==\n";
$parts = RoomSplitter::cut($rectangle, [], [6, -1], [6, 4.5]);
s_check('a straight cut makes two parts', count($parts) === 2);
$areas = array_map(static fn (array $p) => round($p['area'], 3), $parts);
sort($areas);
s_check('the parts add up to the room (8.75 + 21.0 m2)', $areas === [8.75, 21.0], json_encode($areas));
foreach ($parts as $k => $part) {
    s_check("part $k marks exactly its cut edge as open", count($part['open_edges']) === 1, json_encode($part['open_edges']));
    $edge = $part['open_edges'][0];
    $p = $part['points'][$edge];
    $q = $part['points'][($edge + 1) % count($part['points'])];
    s_check("part $k open edge lies on the cut line x=6", abs($p[0] - 6) < 1e-9 && abs($q[0] - 6) < 1e-9, json_encode([$p, $q]));
}

$lShape = [[0, 0], [9, 0], [9, 6], [3, 6], [3, 3], [0, 3]];
$lParts = RoomSplitter::cut($lShape, [], [3, -1], [3, 7]);
$lAreas = array_map(static fn (array $p) => round($p['area'], 3), $lParts);
sort($lAreas);
s_check('an L-shaped room cut at its inner corner gives 9 + 36 m2', $lAreas === [9.0, 36.0], json_encode($lAreas));

$cornerParts = RoomSplitter::cut($rectangle, [], [-1, -1], [5, 5]);
$cornerAreas = array_map(static fn (array $p) => round($p['area'], 3), $cornerParts);
sort($cornerAreas);
s_check('a cut through a corner still makes two clean parts', $cornerAreas === [6.125, 23.625], json_encode($cornerAreas));
s_check('the corner cut part has no zero-length edge', array_reduce($cornerParts, static function (bool $ok, array $part) {
    $n = count($part['points']);
    for ($i = 0; $i < $n; $i++) {
        $a = $part['points'][$i];
        $b = $part['points'][($i + 1) % $n];
        if (abs($a[0] - $b[0]) < 1e-9 && abs($a[1] - $b[1]) < 1e-9) {
            return false;
        }
    }
    return $ok;
}, true));

s_check('a line that stays inside the room is refused', s_rejects(fn () => RoomSplitter::cut($rectangle, [], [2, 1], [4, 1])) !== null);
s_check('a line that misses the room is refused', s_rejects(fn () => RoomSplitter::cut($rectangle, [], [10, -1], [10, 5])) !== null);
$uShape = [[0, 0], [9, 0], [9, 6], [6, 6], [6, 2], [3, 2], [3, 6], [0, 6]];
s_check('a line crossing the outline four times is refused', s_rejects(fn () => RoomSplitter::cut($uShape, [], [-1, 4], [10, 4])) !== null);
s_check('a cut leaving a sliver under 0.5 m2 is refused', s_rejects(fn () => RoomSplitter::cut($rectangle, [], [8.4, -1], [8.4, 4.5])) !== null);
s_check('a zero-length line is refused', s_rejects(fn () => RoomSplitter::cut($rectangle, [], [3, 1], [3, 1])) !== null);

$bigPart = $parts[0]['area'] > $parts[1]['area'] ? $parts[0] : $parts[1];
$again = RoomSplitter::cut($bigPart['points'], $bigPart['open_edges'], [3, -1], [3, 4.5]);
$openCounts = array_map(static fn (array $p) => count($p['open_edges']), $again);
sort($openCounts);
s_check('cutting a part again keeps the earlier open edge on the side that has it', $openCounts === [1, 2], json_encode($openCounts));

echo "\n== Applying a split to a room ==\n";
$room = [
    'room_id' => 'room-01-abc', 'label' => 'Room 1', 'floor_area_m2' => 29.75, 'perimeter_m' => 24.0,
    'bounding_dimensions_m' => ['width_m' => 8.5, 'length_m' => 3.5], 'confidence' => 'high',
    'outline_m' => $rectangle, 'coverage' => ['score' => 0.9], 'height_m' => 2.5, 'volume_m3_indicative' => 74.38,
    'openings' => [
        ['opening_id' => 'w-left', 'category' => 'window', 'position_m' => [2.0, 0.0], 'confidence' => 'high'],
        ['opening_id' => 'd-right', 'category' => 'door', 'position_m' => [8.5, 1.5], 'confidence' => 'high'],
    ],
    'objects' => [
        ['object_id' => 'sofa', 'category' => 'sofa', 'position_m' => [3.0, 1.5], 'dimensions_m' => [2, 0.8, 0.9], 'confidence' => 'high'],
        ['object_id' => 'table', 'category' => 'table', 'position_m' => [7.5, 2.0], 'dimensions_m' => [1, 0.7, 1], 'confidence' => 'high'],
    ],
    'walk_path_m' => [[1.0, 1.0], [7.0, 1.0]],
    'structure_origin_m' => [10.0, 20.0],
    'room_type' => ['guess' => 'living_room', 'guess_source' => 'roomplan_section', 'confirmed' => 'living_room'],
    'floor' => 'Attic', 'capture_group_id' => 'walk-1',
];
$split = RoomSplitter::apply($room, [6, -1], [6, 4.5], [3, 1], 'split', 'room-01-abc-split-1', 'Room 2');
s_check('split returns two rooms', count($split) === 2);
[$kept, $other] = $split;
s_check('the part with the keep point keeps id, label and type', $kept['room_id'] === 'room-01-abc' && $kept['label'] === 'Room 1' && $kept['room_type']['confirmed'] === 'living_room');
s_check('the other part is a new room with no type', $other['room_id'] === 'room-01-abc-split-1' && $other['label'] === 'Room 2' && $other['room_type'] === null);
s_check('areas are recomputed (21.0 and 8.75)', $kept['floor_area_m2'] === 21.0 && $other['floor_area_m2'] === 8.75, $kept['floor_area_m2'] . '/' . $other['floor_area_m2']);
s_check('volume follows the new area', $kept['volume_m3_indicative'] === 52.5);
s_check('bounding box is recomputed', $other['bounding_dimensions_m'] === ['width_m' => 2.5, 'length_m' => 3.5], json_encode($other['bounding_dimensions_m']));
s_check('each outline starts at 0,0 again', min(array_column($other['outline_m'], 0)) == 0 && min(array_column($other['outline_m'], 1)) == 0);
s_check('structure origin moves with the part so the plan stays in place', $other['structure_origin_m'] === [16.0, 20.0], json_encode($other['structure_origin_m']));
s_check('openings go to the part whose wall they sit on', array_column($kept['openings'], 'opening_id') === ['w-left'] && array_column($other['openings'], 'opening_id') === ['d-right']);
s_check('opening positions are shifted into the new part', $other['openings'][0]['position_m'] === [2.5, 1.5], json_encode($other['openings'][0]['position_m']));
s_check('objects go to the part they stand in', array_column($kept['objects'], 'object_id') === ['sofa'] && array_column($other['objects'], 'object_id') === ['table']);
s_check('walk path points are split by part', count($kept['walk_path_m']) === 1 && $other['walk_path_m'] === [[1.0, 1.0]]);
s_check('floor and walkthrough are kept on both parts', $other['floor'] === 'Attic' && $other['capture_group_id'] === 'walk-1');

$trimmed = RoomSplitter::apply($room, [6, -1], [6, 4.5], [7, 1], 'trim', 'unused', 'unused');
s_check('trim keeps only the part with the keep point', count($trimmed) === 1 && $trimmed[0]['room_id'] === 'room-01-abc' && $trimmed[0]['floor_area_m2'] === 8.75);
s_check('trim drops what stood in the other part', array_column($trimmed[0]['objects'], 'object_id') === ['table']);
s_check('a keep point on no part is refused', s_rejects(fn () => RoomSplitter::apply($room, [6, -1], [6, 4.5], [20, 1], 'split', 'x', 'y')) !== null);
s_check('an unknown mode is refused', s_rejects(fn () => RoomSplitter::apply($room, [6, -1], [6, 4.5], [3, 1], 'merge', 'x', 'y')) !== null);

$loose = $room;
unset($loose['structure_origin_m'], $loose['capture_group_id']);
$looseSplit = RoomSplitter::apply($loose, [6, -1], [6, 4.5], [3, 1], 'split', 'n', 'Room 2', [0.0, 0.0], 'split-room-01-abc');
s_check('a lone room without a structure origin gets one so both parts are drawn together', $looseSplit[1]['structure_origin_m'] === [6.0, 0.0] && $looseSplit[1]['capture_group_id'] === 'split-room-01-abc');

echo "\n== Session: split, undo, and re-upload ==\n";
$repo = new ScanSessionRepository(Database::connect(':memory:'));
$adapter = new RoomPlanSimulatorAdapter();
$session = $repo->create('prop-split', 'unit-split', 'org-split', 'listing', false, false);
$identity = ['scan_session_id' => $session['id'], 'property_id' => 'prop-split', 'unit_id' => 'unit-split', 'organisation_id' => 'org-split', 'purpose' => 'listing'];
$raw = static fn (array $origin) => [
    'floors' => [['identifier' => 'F1', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [8.5, 0, 0], [8.5, 0, 3.5], [0, 0, 3.5]]]],
    'structure_origin_m' => $origin,
    'objects' => [['identifier' => 'o1', 'category' => 'table', 'confidence' => 'high', 'position' => [7.5, 0, 2.0], 'dimensions' => [1, 0.7, 1]]],
];
$second = [
    'floors' => [['identifier' => 'F2', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]],
    'structure_origin_m' => [8.5, 0.0],
];
$adapted = $adapter->adapt($raw([0.0, 0.0]), $identity);
$adapted['rooms'] = array_merge($adapted['rooms'], $adapter->adapt($second, $identity, 1)['rooms']);
$repo->appendCapture($session['id'], $adapted);
$roomId = $adapted['rooms'][0]['room_id'];

$afterSplit = $repo->splitRoom($session['id'], $roomId, [[6, -1], [6, 4.5]], [3, 1], 'split');
s_check('the session now has three rooms, the new one right after the split room', array_column($afterSplit['rooms'], 'room_id') === [$roomId, $roomId . '-split-1', $adapted['rooms'][1]['room_id']], json_encode(array_column($afterSplit['rooms'], 'room_id')));
s_check('the new room gets the next free label', $afterSplit['rooms'][1]['label'] === 'Room 3', $afterSplit['rooms'][1]['label']);
s_check('the split is recorded for re-uploads', count($afterSplit['room_splits']) === 1);

$reuploaded = $adapter->adapt($raw([0.0, 0.0]), $identity);
$reuploaded['rooms'] = array_merge($reuploaded['rooms'], $adapter->adapt($second, $identity, 1)['rooms']);
$afterContinue = $repo->replaceRooms($session['id'], $reuploaded['rooms'], 'roomplan', gmdate('c'));
s_check('Continue re-upload keeps the split', array_column($afterContinue['rooms'], 'floor_area_m2') === [21.0, 8.75, 9.0], json_encode(array_column($afterContinue['rooms'], 'floor_area_m2')));
s_check('Continue re-upload keeps the new room id', $afterContinue['rooms'][1]['room_id'] === $roomId . '-split-1');

$shifted = $adapter->adapt($raw([1.0, 0.5]), $identity);
$afterShift = $repo->replaceRooms($session['id'], $shifted['rooms'], 'roomplan', gmdate('c'));
s_check('the cut follows the room when its structure origin moves', $afterShift['rooms'][0]['floor_area_m2'] === 21.0 && $afterShift['rooms'][1]['structure_origin_m'] === [7.0, 0.5], json_encode($afterShift['rooms'][1]['structure_origin_m'] ?? null));

$undone = $repo->undoLastSplit($session['id']);
s_check('undo puts the original room back', count($undone['rooms']) === 1 && $undone['rooms'][0]['floor_area_m2'] === 29.75 && ($undone['room_splits'] ?? null) === []);
s_check('undo with nothing left is refused', s_rejects(fn () => $repo->undoLastSplit($session['id'])) !== null);
s_check('splitting an unknown room is refused', s_rejects(fn () => $repo->splitRoom($session['id'], 'nope', [[6, -1], [6, 4.5]], [3, 1], 'split')) !== null);

$repo->splitRoom($session['id'], $roomId, [[6, -1], [6, 4.5]], [3, 1], 'trim');
$tooSmall = $adapter->adapt(['floors' => [['identifier' => 'F1', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [5, 0, 0], [5, 0, 3.5], [0, 0, 3.5]]]], 'structure_origin_m' => [0.0, 0.0]], $identity);
$afterMiss = $repo->replaceRooms($session['id'], $tooSmall['rooms'], 'roomplan', gmdate('c'));
s_check('a cut that no longer crosses the re-uploaded room is dropped, not an error', count($afterMiss['rooms']) === 1 && $afterMiss['rooms'][0]['floor_area_m2'] === 17.5 && $afterMiss['room_splits'] === []);
s_check('the dropped split is reported back so the app can say so', ($afterMiss['room_split_warnings'][0]['reason'] ?? null) === 'geometry_changed', json_encode($afterMiss['room_split_warnings'] ?? null));
s_check('the warning is not stored with the plan', !array_key_exists('room_split_warnings', $repo->findFloorPlan($session['id'])));

echo "\n== Continue that puts the split room at a different position ==\n";
$shiftSession = $repo->create('prop-split-shift', 'unit-split-shift', 'org-split', 'listing', false, false);
$shiftIdentity = ['scan_session_id' => $shiftSession['id']] + $identity;
$shiftPlan = $adapter->adapt($raw([0.0, 0.0]), $shiftIdentity);
$repo->appendCapture($shiftSession['id'], $shiftPlan);
$shiftRoomId = $shiftPlan['rooms'][0]['room_id'];
$repo->splitRoom($shiftSession['id'], $shiftRoomId, [[6, -1], [6, 4.5]], [3, 1], 'split');
$repo->splitRoom($shiftSession['id'], $shiftRoomId, [[3, -1], [3, 4.5]], [1, 1], 'split');
$reordered = array_merge(
    $adapter->adapt($second, $shiftIdentity)['rooms'],
    $adapter->adapt($raw([0.0, 0.0]), $shiftIdentity, 1)['rooms']
);
s_check('the re-uploaded split room really has a new id', $reordered[1]['room_id'] !== $shiftRoomId, $reordered[1]['room_id']);
$afterReorder = $repo->replaceRooms($shiftSession['id'], $reordered, 'roomplan', gmdate('c'));
s_check('both splits are re-applied when the room id index changes', array_column($afterReorder['rooms'], 'floor_area_m2') === [9.0, 10.5, 10.5, 8.75], json_encode(array_column($afterReorder['rooms'], 'floor_area_m2')));
s_check('no warning when every split was re-applied', !isset($afterReorder['room_split_warnings']));
s_check('the split records follow the new room id', $afterReorder['room_splits'][0]['room_id'] === $reordered[1]['room_id'] && $afterReorder['room_splits'][1]['room_id'] === $reordered[1]['room_id']);

echo "\n== Undo keeps edits made after the split ==\n";
$editSession = $repo->create('prop-split-edit', 'unit-split-edit', 'org-split', 'listing', false, false);
$editIdentity = ['scan_session_id' => $editSession['id']] + $identity;
$editRaw = [
    'floors' => [['identifier' => 'F1', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [8.5, 0, 0], [8.5, 0, 3.5], [0, 0, 3.5]]]],
    'structure_origin_m' => [0.0, 0.0],
    'objects' => [
        ['identifier' => 'sofa', 'category' => 'sofa', 'confidence' => 'high', 'position' => [3.0, 0, 1.5], 'dimensions' => [2, 0.8, 0.9]],
        ['identifier' => 'table', 'category' => 'table', 'confidence' => 'high', 'position' => [7.5, 0, 2.0], 'dimensions' => [1, 0.7, 1]],
        ['identifier' => 'lamp', 'category' => 'storage', 'confidence' => 'high', 'position' => [1.0, 0, 3.0], 'dimensions' => [0.4, 1.5, 0.4]],
    ],
];
$editPlan = $adapter->adapt($editRaw, $editIdentity);
$repo->appendCapture($editSession['id'], $editPlan);
$editRoomId = $editPlan['rooms'][0]['room_id'];
$repo->splitRoom($editSession['id'], $editRoomId, [[6, -1], [6, 4.5]], [3, 1], 'split');
$newId = $editRoomId . '-split-1';
$repo->batchUpdateObjects($editSession['id'], [
    ['room_id' => $editRoomId, 'object_id' => 'sofa', 'custom_name' => 'Corner sofa'],
    ['room_id' => $editRoomId, 'object_id' => 'lamp', 'delete' => true],
    ['room_id' => $newId, 'object_id' => 'table', 'excluded' => true],
]);
$repo->updateRoomLabel($editSession['id'], $editRoomId, 'Woonkamer');
$repo->updateRoomType($editSession['id'], $editRoomId, 'living_room');
$repo->appendNote($editSession['id'], ['note_id' => 'n1', 'text' => 'Crack in the new part', 'room_id' => $newId, 'created_at' => gmdate('c')]);
$afterUndo = $repo->undoLastSplit($editSession['id']);
$restoredRoom = $afterUndo['rooms'][0];
$restoredObjects = array_column($restoredRoom['objects'], null, 'object_id');
s_check('undo keeps an object renamed after the split', ($restoredObjects['sofa']['custom_name'] ?? null) === 'Corner sofa', json_encode($restoredObjects['sofa'] ?? null));
s_check('undo keeps the object at its original position', ($restoredObjects['sofa']['position_m'] ?? null) == [3.0, 1.5], json_encode($restoredObjects['sofa']['position_m'] ?? null));
s_check('undo keeps an object deleted after the split deleted', !isset($restoredObjects['lamp']));
s_check('undo keeps an exclusion made on the new room', ($restoredObjects['table']['excluded'] ?? null) === true);
s_check('undo keeps the label and type set after the split', $restoredRoom['label'] === 'Woonkamer' && ($restoredRoom['room_type']['confirmed'] ?? null) === 'living_room');
s_check('a note on the removed room moves to the restored room instead of being orphaned', $afterUndo['notes'][0]['room_id'] === $editRoomId);
s_check('undo restores the full outline', count($afterUndo['rooms']) === 1 && $restoredRoom['floor_area_m2'] === 29.75);

$trimSession = $repo->create('prop-split-trim', 'unit-split-trim', 'org-split', 'listing', false, false);
$trimPlan = $adapter->adapt($editRaw, ['scan_session_id' => $trimSession['id']] + $identity);
$repo->appendCapture($trimSession['id'], $trimPlan);
$repo->splitRoom($trimSession['id'], $trimPlan['rooms'][0]['room_id'], [[6, -1], [6, 4.5]], [3, 1], 'trim');
$trimUndone = $repo->undoLastSplit($trimSession['id']);
s_check('undoing a trim brings back what stood in the removed part', in_array('table', array_column($trimUndone['rooms'][0]['objects'], 'object_id'), true));

echo "\n== Drawing the open edge ==\n";
$plan = ['property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o', 'purpose' => 'listing', 'captured_at' => gmdate('c'),
    'capture_provider' => 'test', 'measurement_basis' => 'indicative_nen2580_inspired', 'rooms' => $split, 'photos' => [], 'notes' => []];
foreach (['default', 'funda'] as $style) {
    $svg = (new FloorPlanSvgRenderer())->render($plan, 'auto', null, 'metric', null, FloorPlanStyle::from($style));
    s_check("$style SVG draws the cut as a dashed open edge on both parts", substr_count($svg, 'class="open-edge"') === 2, (string) substr_count($svg, 'class="open-edge"'));
    $png = (new FloorPlanImageRenderer())->render($plan, 'auto', null, 'metric', null, FloorPlanStyle::from($style));
    s_check("$style PNG renders", str_starts_with($png, "\x89PNG"));
}
$closed = $plan;
foreach ($closed['rooms'] as &$closedRoom) {
    $closedRoom['open_edges'] = [];
}
unset($closedRoom);
$openPng = (new FloorPlanImageRenderer())->render($plan);
$closedPng = (new FloorPlanImageRenderer())->render($closed);
s_check('the PNG leaves the wall out where the room was cut', $openPng !== $closedPng);

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
