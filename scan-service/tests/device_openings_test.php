<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;

$failures = [];
$checks = 0;

function do_check(string $label, bool $pass, string $detail = ''): void
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

$raw = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_device_openings.json'), true, 512, JSON_THROW_ON_ERROR);
$identity = ['scan_session_id' => 'sess-device', 'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o', 'purpose' => 'listing'];
$plan = (new RoomPlanSimulatorAdapter())->adapt($raw, $identity);
$openings = $plan['rooms'][0]['openings'];
$byId = array_column($openings, null, 'opening_id');

echo "== Doors and windows from a real device (no polygonCorners) ==\n";
do_check('every door, window and opening reaches the floor plan', count($openings) === 4, 'got ' . count($openings));
do_check('the door keeps its width from dimensions', abs(($byId['door-dev-1']['width_m'] ?? 0) - 0.85) < 0.001, json_encode($byId['door-dev-1'] ?? null));
do_check('the door sits where the surface transform put it, in room coordinates', ($byId['door-dev-1']['position_m'] ?? null) === [1.2, 4.0], json_encode($byId['door-dev-1']['position_m'] ?? null));
do_check('a window on the side wall lands on that wall', ($byId['window-dev-2']['position_m'] ?? null) === [5.0, 1.8], json_encode($byId['window-dev-2']['position_m'] ?? null));
do_check('categories are kept', ($byId['window-dev-1']['category'] ?? null) === 'window' && ($byId['opening-dev-1']['category'] ?? null) === 'opening');

$noPosition = $raw;
unset($noPosition['doors'][0]['position']);
$planWithout = (new RoomPlanSimulatorAdapter())->adapt($noPosition, $identity);
do_check('a door with neither corners nor a position is skipped, not placed at 0,0', !in_array('door-dev-1', array_column($planWithout['rooms'][0]['openings'], 'opening_id'), true));

echo "\n== Server warning when doors and windows are missing ==\n";
do_check('a capture whose openings all made it gives no warning', RoomPlanSimulatorAdapter::openingWarning($raw, $plan) === null);
$wallsOnly = $raw;
$wallsOnly['doors'] = [];
$wallsOnly['windows'] = [];
$wallsOnly['openings'] = [];
$wallsOnly['walls'] = [['identifier' => 'w1'], ['identifier' => 'w2']];
$wallsOnlyWarning = RoomPlanSimulatorAdapter::openingWarning($wallsOnly, (new RoomPlanSimulatorAdapter())->adapt($wallsOnly, $identity));
do_check('walls but no doors or windows is logged', is_string($wallsOnlyWarning) && str_contains($wallsOnlyWarning, '2 walls but no doors'), (string) $wallsOnlyWarning);
$droppedWarning = RoomPlanSimulatorAdapter::openingWarning($noPosition, $planWithout);
do_check('a door the server could not place is logged as dropped', is_string($droppedWarning) && str_starts_with($droppedWarning, '1 of 4'), (string) $droppedWarning);

echo "\n== Doors and windows far from every wall ==\n";
$farPlan = $plan;
$farPlan['rooms'][0]['openings'][] = ['opening_id' => 'door-mid-room', 'category' => 'door', 'position_m' => [2.5, 2.0], 'width_m' => 0.85, 'confidence' => 'high'];
$nearPlan = $plan;
$nearPlan['rooms'][0]['openings'][] = ['opening_id' => 'door-near-wall', 'category' => 'door', 'position_m' => [3.6, 3.75], 'width_m' => 0.85, 'confidence' => 'high'];
foreach (['svg' => new \VuuroScan\Export\FloorPlanSvgRenderer(), 'png' => new \VuuroScan\Export\FloorPlanImageRenderer()] as $format => $renderer) {
    $base = $renderer->render($plan);
    do_check("$format: a door in the middle of the room is not drawn onto a wall", $renderer->render($farPlan) === $base);
    do_check("$format: a door a little off the wall is still drawn", $renderer->render($nearPlan) !== $base);
}

echo "\n== A room named during the scan ==\n";
$named = $raw;
$named['room_label'] = "  Study\n";
$named['room_type'] = ['guess' => 'bedroom', 'guess_source' => 'object_heuristic', 'confirmed' => 'other'];
$namedRoom = (new RoomPlanSimulatorAdapter())->adapt($named, $identity)['rooms'][0];
do_check('the typed name becomes the room label', $namedRoom['label'] === 'Study', json_encode($namedRoom['label']));
do_check('the plan shows the typed name, not "Other"', \VuuroScan\RoomType::planName($namedRoom) === 'Study');
do_check('lists show the typed name without an "(Other)" suffix', \VuuroScan\RoomType::displayLabelForRoom($namedRoom) === 'Study', \VuuroScan\RoomType::displayLabelForRoom($namedRoom));
$long = $raw;
$long['room_label'] = str_repeat('x', 80);
do_check('a very long name is cut to 60 characters', mb_strlen((new RoomPlanSimulatorAdapter())->adapt($long, $identity)['rooms'][0]['label']) === 60);
do_check('without a typed name the room keeps its number', (new RoomPlanSimulatorAdapter())->adapt($raw, $identity)['rooms'][0]['label'] === 'Room 1');

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
