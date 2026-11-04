<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;

$failures = 0;

function check(string $label, mixed $actual, mixed $expected): void
{
    global $failures;
    if ($actual !== $expected) {
        fwrite(STDERR, "FAIL $label\n  expected: " . var_export($expected, true) . "\n  actual:   " . var_export($actual, true) . "\n");
        $failures++;
    } else {
        echo "PASS $label\n";
    }
}

$identity = [
    'scan_session_id' => 'sess-full-roomplan',
    'property_id' => 'prop-1',
    'unit_id' => 'unit-1',
    'organisation_id' => 'org-1',
    'purpose' => 'listing',
];

$transform = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3.5, 0.4, 4.5, 1];

$capture = [
    'floors' => [[
        'identifier' => 'floor-1',
        'category' => 'floor',
        'confidence' => 'high',
        'polygonCorners' => [[2, 0, 3], [6, 0, 3], [6, 0, 6], [2, 0, 6]],
    ]],
    'walls' => [],
    'doors' => [[
        'identifier' => 'door-1',
        'category' => 'door',
        'confidence' => 'high',
        'polygonCorners' => [[3, 0, 3], [4, 0, 3], [4, 2, 3], [3, 2, 3]],
        'transform' => $transform,
        'curve' => 'Curve(radius: 2.0)',
    ]],
    'windows' => [],
    'openings' => [],
    'objects' => [[
        'identifier' => 'object-1',
        'category' => 'sofa',
        'confidence' => 'high',
        'dimensions' => [2.0, 0.8, 0.9],
        'position' => [3.5, 0.4, 4.5],
        'transform' => $transform,
        'attributes' => ['SofaType.lShaped', 7, ''],
    ]],
    'sections' => [
        ['label' => 'living_room', 'center' => [4.0, 1.2, 4.5], 'story' => 0],
        ['label' => '', 'center' => [5.0, 1.2, 5.0], 'story' => 0],
        ['label' => 'kitchen', 'center' => [1.0, 'bad', 2.0], 'story' => 0],
    ],
];

echo "== Full RoomPlan result is kept ==\n";
$room = (new RoomPlanSimulatorAdapter())->adapt($capture, $identity)['rooms'][0];

check('two valid sections kept, malformed one dropped', count($room['sections']), 2);
check('section label', $room['sections'][0]['label'], 'living_room');
check('section centre is room-local like the outline', $room['sections'][0]['center_m'], [2.0, 1.5]);
check('section centre height', $room['sections'][0]['center_height_m'], 1.2);
check('section story', $room['sections'][0]['story'], 0);
check('empty label becomes unidentified', $room['sections'][1]['label'], 'unidentified');

check('door keeps its RoomPlan transform', $room['openings'][0]['transform_raw'], [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 3.5, 0.4, 4.5, 1.0]);
check('door keeps its curve', $room['openings'][0]['curve'], 'Curve(radius: 2.0)');
check('object keeps its RoomPlan transform', count($room['objects'][0]['transform_raw']), 16);
check('object attributes keep only non-empty strings', $room['objects'][0]['attributes'], ['SofaType.lShaped']);

echo "\n== Bad values are dropped, not stored ==\n";
$bad = $capture;
$bad['doors'][0]['transform'] = array_fill(0, 15, 1.0);
$bad['objects'][0]['transform'] = array_merge(array_fill(0, 15, 1.0), ['x']);
$bad['objects'][0]['attributes'] = 'not-a-list';
unset($bad['sections'], $bad['doors'][0]['curve']);
$room = (new RoomPlanSimulatorAdapter())->adapt($bad, $identity)['rooms'][0];
check('short transform dropped', array_key_exists('transform_raw', $room['openings'][0]), false);
check('non-numeric transform dropped', array_key_exists('transform_raw', $room['objects'][0]), false);
check('attributes that are not a list dropped', array_key_exists('attributes', $room['objects'][0]), false);
check('no curve when none was sent', array_key_exists('curve', $room['openings'][0]), false);
check('no sections gives an empty list', $room['sections'], []);

echo "\n";
echo $failures === 0 ? "TEST VERDICT: GREEN\n" : "$failures failure(s)\nTEST VERDICT: RED\n";
exit($failures === 0 ? 0 : 1);
