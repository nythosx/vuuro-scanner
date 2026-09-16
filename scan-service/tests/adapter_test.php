<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;

$failures = [];
$checks = 0;

function t_check(string $label, bool $pass, string $detail = ''): void
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

function t_approx(float $a, float $b, float $tol = 0.01): bool
{
    return abs($a - $b) <= $tol;
}

$identity = [
    'scan_session_id' => 'sess-test-1',
    'property_id' => 'prop-test-1',
    'unit_id' => 'unit-test-1',
    'organisation_id' => 'org-test-1',
    'purpose' => 'listing',
];

$adapter = new RoomPlanSimulatorAdapter();

echo "== Regression: rectangular room ==\n";
$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$result = $adapter->adapt($fixture, $identity);

t_check('scan_session_id bound', $result['scan_session_id'] === 'sess-test-1');
t_check('property_id bound', $result['property_id'] === 'prop-test-1');
t_check('unit_id bound', $result['unit_id'] === 'unit-test-1');
t_check('organisation_id bound', $result['organisation_id'] === 'org-test-1');
t_check('measurement_basis is indicative, never certified', $result['measurement_basis'] === 'indicative_nen2580_inspired');
t_check('exactly one room for one floor', count($result['rooms']) === 1);
t_check('area is 4.20 x 3.10 = 13.02 m2', t_approx($result['rooms'][0]['floor_area_m2'], 13.02));
t_check('perimeter is 2*(4.20+3.10) = 14.60 m', t_approx($result['rooms'][0]['perimeter_m'], 14.60));
t_check('photos present and empty (Phase 1)', $result['photos'] === []);
t_check('notes present and empty (Phase 1)', $result['notes'] === []);
t_check('outline_m has 4 points for a 4-corner rectangle', count($result['rooms'][0]['outline_m']) === 4);
t_check('outline_m is room-local: min x is 0', min(array_column($result['rooms'][0]['outline_m'], 0)) === 0.0);
t_check('outline_m is room-local: min z is 0', min(array_column($result['rooms'][0]['outline_m'], 1)) === 0.0);
t_check('outline_m bounding box matches bounding_dimensions_m width',
    t_approx(max(array_column($result['rooms'][0]['outline_m'], 0)), $result['rooms'][0]['bounding_dimensions_m']['width_m']));

t_check('coverage score for the mostly-high-confidence fixture is 94', $result['rooms'][0]['coverage']['score'] === 94);
t_check('coverage.usable is true at 94', $result['rooms'][0]['coverage']['usable'] === true);
t_check('coverage.message is null when usable', $result['rooms'][0]['coverage']['message'] === null);
t_check('coverage.confidence_counts has 6 high, 1 medium, 0 low',
    $result['rooms'][0]['coverage']['confidence_counts'] === ['high' => 6, 'medium' => 1, 'low' => 0]);
echo "\n";

echo "== LIDAR-10: openings, height/volume, and objects ==\n";
$room = $result['rooms'][0];
t_check('openings has 2 entries (1 door + 1 window)', count($room['openings']) === 2);
t_check('openings[0] is the door, room-local position (2.40, 0.00)',
    $room['openings'][0]['category'] === 'door' && $room['openings'][0]['position_m'] === [2.4, 0.0]);
t_check('openings[1] is the window, room-local position (0.60, 3.10)',
    $room['openings'][1]['category'] === 'window' && $room['openings'][1]['position_m'] === [0.6, 3.1]);
t_check('openings[0].confidence is high, matching the fixture', $room['openings'][0]['confidence'] === 'high');
t_check('height_m is 2.60, the tallest (only) wall dimensions[1] in the fixture', t_approx($room['height_m'], 2.60));
t_check('volume_m3_indicative is floor_area_m2 * height_m = 13.02 * 2.60 = 33.85',
    t_approx($room['volume_m3_indicative'], 33.85));
t_check('objects has 1 entry (the fixture bed)', count($room['objects']) === 1);
t_check('objects[0].category is "bed", passed through as the fixture reported it', $room['objects'][0]['category'] === 'bed');
t_check('objects[0].position_m is room-local (3.00, 2.20)', $room['objects'][0]['position_m'] === [3.0, 2.2]);
t_check('objects[0].dimensions_m matches the fixture (1.60, 0.55, 2.00)', $room['objects'][0]['dimensions_m'] === [1.6, 0.55, 2.0]);
t_check('room_type round-trips the fixture\'s guess/guess_source/confirmed',
    $room['room_type'] === ['guess' => 'bedroom', 'guess_source' => 'roomplan_section', 'confirmed' => 'bedroom']);
echo "\n";

echo "== Room-type guess: absent, invalid, and heuristic-only cases ==\n";
$noRoomType = $fixture;
unset($noRoomType['room_type']);
t_check('room_type is null when the capture reported none',
    $adapter->adapt($noRoomType, $identity)['rooms'][0]['room_type'] === null);

$invalidGuess = $fixture;
$invalidGuess['room_type'] = ['guess' => 'garage', 'guess_source' => 'roomplan_section', 'confirmed' => null];
t_check('room_type is null when guess is not one of the known section labels',
    $adapter->adapt($invalidGuess, $identity)['rooms'][0]['room_type'] === null);

$customConfirmed = $fixture;
$customConfirmed['room_type'] = ['guess' => 'kitchen', 'guess_source' => 'object_heuristic', 'confirmed' => 'not-a-real-answer'];
t_check('a confirmed value outside the fixed list is kept as free-text, not dropped to null',
    $adapter->adapt($customConfirmed, $identity)['rooms'][0]['room_type'] === ['guess' => 'kitchen', 'guess_source' => 'object_heuristic', 'confirmed' => 'not-a-real-answer']);

$malformedConfirmed = $fixture;
$malformedConfirmed['room_type'] = ['guess' => 'kitchen', 'guess_source' => 'object_heuristic', 'confirmed' => "  \x01  "];
t_check('a confirmed value that is empty/control-chars-only after trimming is still dropped to null',
    $adapter->adapt($malformedConfirmed, $identity)['rooms'][0]['room_type'] === ['guess' => 'kitchen', 'guess_source' => 'object_heuristic', 'confirmed' => null]);
echo "\n";

echo "== LIDAR-10: multiple openings/objects, and height/volume null with no walls ==\n";
$openingsFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_openings_and_objects.json'), true, 512, JSON_THROW_ON_ERROR);
$openingsResult = $adapter->adapt($openingsFixture, $identity);
$openingsRoom = $openingsResult['rooms'][0];

t_check('floor_area_m2 is 5.0 x 4.0 = 20.00 m2', t_approx($openingsRoom['floor_area_m2'], 20.00));
t_check('openings has 4 entries (2 doors + 2 windows), not just the first of each group', count($openingsRoom['openings']) === 4);
t_check('openings category breakdown is 2 door + 2 window',
    array_count_values(array_column($openingsRoom['openings'], 'category')) === ['door' => 2, 'window' => 2]);
t_check('height_m is null when the capture call reported no walls[]', $openingsRoom['height_m'] === null);
t_check('volume_m3_indicative is null, not a fabricated 0, when height_m is null', $openingsRoom['volume_m3_indicative'] === null);
t_check('objects has 2 entries', count($openingsRoom['objects']) === 2);
t_check('objects categories round-trip as reported (sofa, table)',
    array_column($openingsRoom['objects'], 'category') === ['sofa', 'table']);
echo "\n";

echo "== LIDAR-10: a door present in capture must not go missing from the contract ==\n";
$doorCount = count($fixture['doors'] ?? []) + count($fixture['windows'] ?? []) + count($fixture['openings'] ?? []);
t_check('every door/window in the raw capture has a matching openings[] entry',
    count($result['rooms'][0]['openings']) === $doorCount);
echo "\n";

echo "== LIDAR-10 review fix: a multi-floor capture call is rejected, not silently mis-attributed ==\n";
try {
    $adapter->adapt([
        'floors' => [
            ['identifier' => 'floor-A', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]],
            ['identifier' => 'floor-B', 'confidence' => 'high', 'polygonCorners' => [[10, 0, 10], [13, 0, 10], [13, 0, 13], [10, 0, 13]]],
        ],
        'doors' => [
            ['identifier' => 'door-only-in-room-A', 'confidence' => 'high', 'polygonCorners' => [[1, 0, 0], [2, 0, 0], [2, 2, 0], [1, 2, 0]]],
        ],
    ], $identity);
    t_check('adapt() rejects a capture with more than one floor', false, 'no exception was thrown — this used to silently duplicate the door into floor B\'s openings[] at a wrong position');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a capture with more than one floor', true);
}

echo "== LIDAR-10 review fix, narrowed: a floors-only multi-floor capture (no ambiguous data) still succeeds ==\n";
$manyFloorsOnly = ['floors' => array_map(
    static fn (int $i) => ['identifier' => "floor-many-$i", 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]],
    range(0, 4)
)];
$manyFloorsResult = $adapter->adapt($manyFloorsOnly, $identity);
t_check('a 5-floor, geometry-only capture (no walls/doors/objects) is still accepted', count($manyFloorsResult['rooms']) === 5);
t_check('each room in it has empty openings[] (nothing to misattribute)',
    array_column($manyFloorsResult['rooms'], 'openings') === array_fill(0, 5, []));
t_check('each room in it has null height_m (no walls[] reported)',
    array_column($manyFloorsResult['rooms'], 'height_m') === array_fill(0, 5, null));

echo "== LIDAR-10 review fix: absurd objects[].dimensions / walls[].dimensions are rejected ==\n";
try {
    $adapter->adapt([
        'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
        'objects' => [['identifier' => 'o', 'confidence' => 'high', 'position' => [1, 0, 1], 'dimensions' => [99999, 1, 1]]],
    ], $identity);
    t_check('adapt() rejects an absurd objects[].dimensions coordinate', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects an absurd objects[].dimensions coordinate', true);
}

try {
    $adapter->adapt([
        'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
        'walls' => [['identifier' => 'w', 'confidence' => 'high', 'dimensions' => [4, 1e400, 0.1]]],
    ], $identity);
    t_check('adapt() rejects a non-finite walls[].dimensions height', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-finite walls[].dimensions height', true);
}

$truncatedDimsResult = $adapter->adapt([
    'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
    'objects' => [
        ['identifier' => 'truncated', 'confidence' => 'high', 'position' => [1, 0, 1], 'dimensions' => [1, 1]],
        ['identifier' => 'missing', 'confidence' => 'high', 'position' => [2, 0, 1]],
        ['identifier' => 'real', 'confidence' => 'high', 'position' => [3, 0, 1], 'dimensions' => [0.5, 0.5, 0.5]],
    ],
], $identity);
t_check('a truncated or missing objects[].dimensions drops the object instead of fabricating [0,0,0]',
    array_column($truncatedDimsResult['rooms'][0]['objects'], 'object_id') === ['real']);

echo "\n== LIDAR-5/11: structure_origin_m ==\n";
$noOriginResult = $adapter->adapt([
    'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
], $identity);
t_check('structure_origin_m is null when absent from raw_capture', $noOriginResult['rooms'][0]['structure_origin_m'] === null);

$withOriginResult = $adapter->adapt([
    'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
    'structure_origin_m' => [1.5, 2.25],
], $identity);
t_check('structure_origin_m passes through when present', $withOriginResult['rooms'][0]['structure_origin_m'] === [1.5, 2.25]);

try {
    $adapter->adapt([
        'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
        'structure_origin_m' => [1e400, 0],
    ], $identity);
    t_check('adapt() rejects a non-finite structure_origin_m coordinate', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-finite structure_origin_m coordinate', true);
}

try {
    $adapter->adapt([
        'floors' => [
            ['identifier' => 'f1', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]],
            ['identifier' => 'f2', 'confidence' => 'high', 'polygonCorners' => [[10, 0, 0], [14, 0, 0], [14, 0, 3], [10, 0, 3]]],
        ],
        'structure_origin_m' => [1.5, 2.25],
    ], $identity);
    t_check('adapt() rejects a multi-floor capture carrying structure_origin_m', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a multi-floor capture carrying structure_origin_m', true);
}
echo "\n";

echo "== heading_deg: real compass reading, never fabricated ==\n";
$noHeadingResult = $adapter->adapt([
    'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
], $identity);
t_check('heading_deg is null when absent from raw_capture, not fabricated as 0/north', $noHeadingResult['rooms'][0]['heading_deg'] === null);

$withHeadingResult = $adapter->adapt([
    'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
    'heading_deg' => 271.5,
], $identity);
t_check('heading_deg passes through when present', $withHeadingResult['rooms'][0]['heading_deg'] === 271.5);

$zeroHeadingResult = $adapter->adapt([
    'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
    'heading_deg' => 0.0,
], $identity);
t_check('a real 0.0 heading_deg reading is kept, not confused with "absent"', $zeroHeadingResult['rooms'][0]['heading_deg'] === 0.0);

foreach ([-0.001, 360.0, 360.5] as $outOfRange) {
    try {
        $adapter->adapt([
            'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
            'heading_deg' => $outOfRange,
        ], $identity);
        t_check("adapt() rejects an out-of-range heading_deg ($outOfRange)", false, 'no exception was thrown');
    } catch (\InvalidArgumentException) {
        t_check("adapt() rejects an out-of-range heading_deg ($outOfRange)", true);
    }
}

try {
    $adapter->adapt([
        'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
        'heading_deg' => 'north',
    ], $identity);
    t_check('adapt() rejects a non-numeric heading_deg', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-numeric heading_deg', true);
}

try {
    $adapter->adapt([
        'floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 0], [4, 0, 3], [0, 0, 3]]]],
        'heading_deg' => 1e400,
    ], $identity);
    t_check('adapt() rejects a non-finite (overflowed-to-INF) heading_deg', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-finite (overflowed-to-INF) heading_deg', true);
}
echo "\n";
echo "\n";

echo "== Adjacent case: L-shaped concave room ==\n";
$lshaped = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$lResult = $adapter->adapt($lshaped, $identity);
$lRoom = $lResult['rooms'][0];

t_check('L-shaped area is 10.20 m2, not the 12.0 m2 bounding-box area', t_approx($lRoom['floor_area_m2'], 10.20));
t_check('L-shaped area is NOT the naive bounding-box area (12.0)', !t_approx($lRoom['floor_area_m2'], 12.00, 0.001));
t_check('L-shaped perimeter is 14.0 m', t_approx($lRoom['perimeter_m'], 14.00));
t_check('L-shaped bounding width is 4.0 m (bbox, not perimeter-derived)', t_approx($lRoom['bounding_dimensions_m']['width_m'], 4.00));
t_check('L-shaped bounding length is 3.0 m', t_approx($lRoom['bounding_dimensions_m']['length_m'], 3.00));
echo "\n";

echo "== Adjacent case: coverage reflects wall/door/window confidence, not just the floor's ==\n";
$lowConfFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_low_confidence_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$lowConfResult = $adapter->adapt($lowConfFixture, $identity);
$lowConfCoverage = $lowConfResult['rooms'][0]['coverage'];

t_check('coverage score for the low-confidence fixture is 43, not the floor-only 100', $lowConfCoverage['score'] === 43);
t_check('coverage.usable is false below the 70 threshold', $lowConfCoverage['usable'] === false);
t_check('coverage.message is a non-empty rescan prompt when not usable', is_string($lowConfCoverage['message']) && $lowConfCoverage['message'] !== '');
t_check('coverage.confidence_counts has 1 high (the floor), not 6', $lowConfCoverage['confidence_counts']['high'] === 1);
echo "\n";

echo "== Multi-room: room numbering continues across capture calls ==\n";
$secondCallResult = $adapter->adapt($fixture, $identity, 1);
t_check('second call with offset 1 labels its room "Room 2"', $secondCallResult['rooms'][0]['label'] === 'Room 2');
t_check('first call (offset 0) labeled its room "Room 1"', $result['rooms'][0]['label'] === 'Room 1');
t_check('room_id differs between offset 0 and offset 1 calls even for the same fixture',
    $result['rooms'][0]['room_id'] !== $secondCallResult['rooms'][0]['room_id']);
echo "\n";

echo "== Error handling ==\n";
try {
    $adapter->adapt(['floors' => []], $identity);
    t_check('adapt() rejects a capture with no floors', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a capture with no floors', true);
}

try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [1, 0, 0]]]]], $identity);
    t_check('adapt() rejects a floor with fewer than 3 corners', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a floor with fewer than 3 corners', true);
}
echo "\n";

echo "== Security: reject non-finite and oversized capture geometry ==\n";

try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [1e400, 0, 0], [1e400, 0, 1], [0, 0, 1]]]]], $identity);
    t_check('adapt() rejects a non-finite (INF) coordinate', false, 'no exception was thrown -- this is the exact payload that previously crashed the live server');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-finite (INF) coordinate', true);
}

try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [50000, 0, 0], [50000, 0, 1], [0, 0, 1]]]]], $identity);
    t_check('adapt() rejects a coordinate far beyond any real room (50000m)', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a coordinate far beyond any real room (50000m)', true);
}

try {
    $tooManyFloors = array_fill(0, 51, ['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]]]);
    $adapter->adapt(['floors' => $tooManyFloors], $identity);
    t_check('adapt() rejects more than 50 floors in one capture call', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects more than 50 floors in one capture call', true);
}

try {
    $tooManyCorners = array_fill(0, 1001, [0, 0, 0]);
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => $tooManyCorners]]], $identity);
    t_check('adapt() rejects a floor with more than 1000 polygonCorners', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a floor with more than 1000 polygonCorners', true);
}

try {
    $floorsAsObject = json_decode('{"floors":{"myFloor":{"identifier":"f","polygonCorners":[[0,0,0],[1,0,0],[1,0,1],[0,0,1]]}}}', true);
    $adapter->adapt($floorsAsObject, $identity);
    t_check('adapt() rejects floors[] sent as a JSON object instead of an array, not a crash', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects floors[] sent as a JSON object instead of an array, not a crash', true);
} catch (\Throwable $e) {
    t_check('adapt() rejects floors[] sent as a JSON object instead of an array, not a crash', false, 'threw ' . get_class($e) . ' instead of InvalidArgumentException: ' . $e->getMessage());
}

try {
    $tooManyWalls = array_fill(0, 501, ['identifier' => 'w', 'confidence' => 'high']);
    $adapter->adapt(['floors' => $fixture['floors'], 'walls' => $tooManyWalls], $identity);
    t_check('adapt() rejects more than 500 walls in one capture call', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects more than 500 walls in one capture call', true);
}

$largeButValid = $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [20, 0, 0], [20, 0, 15], [0, 0, 15]]]]], $identity);
t_check('a large but plausible room (20m x 15m) is still accepted', $largeButValid['rooms'][0]['floor_area_m2'] === 300.0);
echo "\n";

echo "== Adjacent case: a non-numeric polygonCorners coordinate must not silently coerce to 0 ==\n";
foreach (['a string' => 'not_a_number', 'a bool' => true, 'a nested array' => [1, 2]] as $label => $badCoordinate) {
    try {
        $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[$badCoordinate, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]], $identity);
        t_check("adapt() rejects a polygonCorners coordinate that is $label, not silently coerced", false, 'no exception was thrown');
    } catch (\InvalidArgumentException) {
        t_check("adapt() rejects a polygonCorners coordinate that is $label, not silently coerced", true);
    }
}
$nullCoordinate = $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[null, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]], $identity);
t_check('a genuinely-absent (null) coordinate is still accepted, falling back to 0 as before', $nullCoordinate['rooms'][0]['outline_m'][0] === [0.0, 0.0]);
echo "\n";

echo "== Adjacent case: degenerate (collinear-corner) outline is rejected, not silently zero-area ==\n";
$degenerate = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_degenerate_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
try {
    $adapter->adapt($degenerate, $identity);
    t_check('adapt() rejects a collinear-corner (0 m2) outline', false, 'no exception was thrown -- this used to silently produce a "usable" 0 m2 room');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a collinear-corner (0 m2) outline', true);
}

try {
    $bowtie = ['floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 4], [4, 0, 0], [0, 0, 4]]]]];
    $adapter->adapt($bowtie, $identity);
    t_check('adapt() rejects a self-intersecting outline whose area cancels to ~0', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a self-intersecting outline whose area cancels to ~0', true);
}

$smallButReal = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [0.8, 0, 0], [0.8, 0, 0.8], [0, 0, 0.8]]]]], $identity);
t_check('a small but real room (0.64 m2 closet) is still accepted, not rejected as degenerate', t_approx($smallButReal['rooms'][0]['floor_area_m2'], 0.64));
echo "\n";

echo "== Adjacent case: a non-string 'confidence' on any surface must not crash ==\n";
$nonStringConfidence = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => 12345, 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("a numeric 'confidence' (12345) does not crash and maps to 'low', same as an unrecognized string would", $nonStringConfidence['rooms'][0]['confidence'] === 'low');

$arrayConfidence = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => ['nested', 'array'], 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("an array 'confidence' does not crash and maps to 'low'", $arrayConfidence['rooms'][0]['confidence'] === 'low');

echo "== Adjacent case: a polygonCorners entry that isn't itself an array must not crash ==\n";
try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [1, 2, 3]]]], $identity);
    t_check('adapt() rejects scalar polygonCorners entries with a clean exception, not a crash', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects scalar polygonCorners entries with a clean exception, not a crash', true);
} catch (\TypeError $e) {
    t_check('adapt() rejects scalar polygonCorners entries with a clean exception, not a crash', false, 'threw TypeError instead: ' . $e->getMessage());
}

echo "== Adjacent case: a non-array walls/doors/windows/openings group must not crash ==\n";
$nonArrayWalls = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]], 'walls' => 'not-an-array'], $identity);
t_check("a non-array 'walls' group does not crash and is treated as contributing zero surfaces", $nonArrayWalls['rooms'][0]['coverage']['confidence_counts'] === ['high' => 1, 'medium' => 0, 'low' => 0]);

echo "== Adjacent case: a non-string 'identifier' must not silently corrupt room_id ==\n";
try {
    $adapter->adapt(['floors' => [['identifier' => ['nested', 'array'], 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
    t_check("adapt() rejects a non-string 'identifier' with a clean exception, not silent corruption", false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check("adapt() rejects a non-string 'identifier' with a clean exception, not silent corruption", true);
}
$omittedIdentifier = $adapter->adapt(['floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("omitting 'identifier' entirely still works (falls back to 'floor-N')", $omittedIdentifier['rooms'][0]['room_id'] === 'room-01-floor-0');
$stringIdentifier = $adapter->adapt(['floors' => [['identifier' => 'my-floor', 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("a real string 'identifier' still works normally", $stringIdentifier['rooms'][0]['room_id'] === 'room-01-my-floor');

echo "\n== capture_location ==\n";
$noLocation = $adapter->adapt(['floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check('capture_location is null when absent from identity', $noLocation['capture_location'] === null);

$withLocation = $adapter->adapt(
    ['floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]],
    $identity + ['capture_location' => ['lat' => 52.09, 'lon' => 5.12, 'accuracy_m' => 8.5, 'captured_at' => '2026-09-03T13:08:18+00:00']]
);
t_check('capture_location round-trips lat/lon/accuracy_m/captured_at', $withLocation['capture_location'] === [
    'lat' => 52.09, 'lon' => 5.12, 'accuracy_m' => 8.5, 'captured_at' => '2026-09-03T13:08:18+00:00',
]);

echo "\n== walk_path_m ==\n";
$noWalkPath = $adapter->adapt(['floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check('walk_path_m is empty when walk_path is absent', $noWalkPath['rooms'][0]['walk_path_m'] === []);

$withWalkPath = $adapter->adapt([
    'floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]],
    'walk_path' => [[0.5, 0.0, 0.5], [1.0, 0.0, 0.6], [1.5, 0.0, 0.4]],
], $identity);
t_check('walk_path_m carries the recorded points, translated into room-local frame like outline_m', $withWalkPath['rooms'][0]['walk_path_m'] === [
    [0.5, 0.5], [1.0, 0.6], [1.5, 0.4],
], 'got ' . json_encode($withWalkPath['rooms'][0]['walk_path_m']));

$mixedWalkPath = $adapter->adapt([
    'floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]],
    'walk_path' => [[0.5, 0.0, 0.5], 'not-a-point', ['x' => 1], [1.0, 0.0, 0.6]],
], $identity);
t_check('walk_path_m drops malformed entries rather than crashing or fabricating a point', $mixedWalkPath['rooms'][0]['walk_path_m'] === [
    [0.5, 0.5], [1.0, 0.6],
], 'got ' . json_encode($mixedWalkPath['rooms'][0]['walk_path_m']));

try {
    $adapter->adapt([
        'floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]],
        'walk_path' => array_fill(0, 1001, [0.0, 0.0, 0.0]),
    ], $identity);
    t_check('adapt() rejects a walk_path[] over the sanity limit', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a walk_path[] over the sanity limit', true);
}

try {
    $adapter->adapt([
        'floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]],
        'walk_path' => [[INF, 0.0, 0.0]],
    ], $identity);
    t_check('adapt() rejects a non-finite walk_path coordinate', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-finite walk_path coordinate', true);
}

echo count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}
echo "\nTEST VERDICT: GREEN\n";
exit(0);