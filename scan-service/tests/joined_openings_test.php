<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;
use VuuroScan\Export\FloorGroups;
use VuuroScan\Export\FloorPlanSvgRenderer;
use VuuroScan\Export\ObjectFootprint;
use VuuroScan\Export\OpeningDedup;
use VuuroScan\Export\RoomFusionSolver;
use VuuroScan\GroupPlacement;

$failures = [];
$checks = 0;

function jo_check(string $label, bool $pass, string $detail = ''): void
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

function jo_rotate(array $p, float $deg, float $tx, float $tz): array
{
    $t = deg2rad($deg);
    return [$p[0] * cos($t) - $p[2] * sin($t) + $tx, $p[1], $p[0] * sin($t) + $p[2] * cos($t) + $tz];
}

function jo_in_frame(array $raw, float $deg, float $tx, float $tz): array
{
    foreach (['floors', 'walls', 'doors', 'windows', 'openings', 'objects'] as $group) {
        foreach ($raw[$group] ?? [] as $i => $item) {
            if (!empty($item['polygonCorners'])) {
                $raw[$group][$i]['polygonCorners'] = array_map(static fn (array $c) => jo_rotate($c, $deg, $tx, $tz), $item['polygonCorners']);
            }
            if (isset($item['position'])) {
                $raw[$group][$i]['position'] = jo_rotate($item['position'], $deg, $tx, $tz);
            }
            if (isset($item['yawDeg'])) {
                $raw[$group][$i]['yawDeg'] = fmod(fmod($item['yawDeg'] + $deg, 360.0) + 360.0, 360.0);
            }
        }
    }
    $corners = $raw['floors'][0]['polygonCorners'];
    $raw['structure_origin_m'] = [min(array_column($corners, 0)), min(array_column($corners, 2))];
    return $raw;
}

function jo_wall_distance(array $outline, array $point): float
{
    $best = INF;
    $n = count($outline);
    for ($i = 0; $i < $n; $i++) {
        [$ax, $az] = $outline[$i];
        [$bx, $bz] = $outline[($i + 1) % $n];
        $dx = $bx - $ax;
        $dz = $bz - $az;
        $len = $dx * $dx + $dz * $dz;
        $t = $len > 0 ? max(0.0, min(1.0, (($point[0] - $ax) * $dx + ($point[1] - $az) * $dz) / $len)) : 0.0;
        $best = min($best, hypot($point[0] - ($ax + $t * $dx), $point[1] - ($az + $t * $dz)));
    }
    return $best;
}

$raw = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_device_openings.json'), true, 512, JSON_THROW_ON_ERROR);
$raw['objects'] = [[
    'identifier' => 'bed-dev-1', 'category' => 'bed', 'confidence' => 'high',
    'dimensions' => [2.0, 0.5, 1.4], 'position' => [3.0, 0.25, 2.5], 'yawDeg' => 0.0,
]];
$identity = ['scan_session_id' => 's', 'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o', 'purpose' => 'listing', 'floor' => 'Ground floor'];
$adapter = new RoomPlanSimulatorAdapter();

$rawA = jo_in_frame($raw, 0.0, 0.0, 0.0);
$rawA['capture_group_id'] = 'walk-A';
$planA = $adapter->adapt($rawA, $identity);
$roomA = $planA['rooms'][0];
$widthA = max(array_column($roomA['outline_m'], 0));

foreach ([0.0, 3.0, 37.0, 90.0] as $theta) {
    echo "\n== Second scan in a frame turned {$theta}°, placed next to the first ==\n";
    $t0 = [20.0, 10.0];
    $rawB = jo_in_frame($raw, $theta, $t0[0], $t0[1]);
    $rawB['capture_group_id'] = 'walk-B';
    $roomB = $adapter->adapt($rawB, $identity, 1)['rooms'][0];

    $back = deg2rad(-$theta);
    $tx = -($t0[0] * cos($back) - $t0[1] * sin($back)) + $widthA;
    $tz = -($t0[0] * sin($back) + $t0[1] * cos($back));
    $placed = GroupPlacement::transformRoom($roomB, -$theta, $tx, $tz);
    $placed['joined_to_group_id'] = 'walk-A';

    $expectedOrigin = [$roomA['structure_origin_m'][0] + $widthA, $roomA['structure_origin_m'][1]];
    jo_check('the placed room lands next to the first one', abs($placed['structure_origin_m'][0] - $expectedOrigin[0]) < 0.01 && abs($placed['structure_origin_m'][1] - $expectedOrigin[1]) < 0.01, json_encode([$placed['structure_origin_m'], $expectedOrigin]));
    $sameShape = true;
    foreach ($roomA['outline_m'] as $i => [$ax, $az]) {
        [$bx, $bz] = $placed['outline_m'][$i] ?? [INF, INF];
        $sameShape = $sameShape && abs($ax - $bx) < 0.01 && abs($az - $bz) < 0.01;
    }
    jo_check('the placed room has the same shape as the first one', $sameShape, json_encode($placed['outline_m']));

    $maxOff = 0.0;
    foreach ($placed['openings'] as $opening) {
        $maxOff = max($maxOff, jo_wall_distance($placed['outline_m'], $opening['position_m']));
    }
    jo_check('every door and window still sits on a wall of its own room (<= 0.05 m)', count($placed['openings']) === 4 && $maxOff <= 0.05, sprintf('%d openings, max %.3f m', count($placed['openings']), $maxOff));
    $openingPositionsMatch = true;
    foreach ($roomA['openings'] as $i => $opening) {
        $other = $placed['openings'][$i]['position_m'] ?? [INF, INF];
        $openingPositionsMatch = $openingPositionsMatch && abs($opening['position_m'][0] - $other[0]) < 0.01 && abs($opening['position_m'][1] - $other[1]) < 0.01;
    }
    jo_check('each door and window is at the same spot as in the first room', $openingPositionsMatch, json_encode(array_column($placed['openings'], 'position_m')));

    [, , $halfWA, $halfDA] = ObjectFootprint::fit($roomA, $roomA['objects'][0], 0.05);
    [, , $halfWB, $halfDB] = ObjectFootprint::fit($placed, $placed['objects'][0], 0.05);
    jo_check('furniture keeps its footprint after the turn', abs($halfWA - $halfWB) < 0.001 && abs($halfDA - $halfDB) < 0.001, json_encode([[$halfWA, $halfDA], [$halfWB, $halfDB]]));

    $rooms = [$roomA, $placed];
    jo_check('the joined scans form one plan section', count(FloorGroups::split($rooms)) === 1);
    $poses = RoomFusionSolver::solve($rooms)['poses'];
    $expectedDrawn = array_sum(array_map(static fn (array $room) => count($room['openings']), OpeningDedup::filter($rooms, $poses)));
    $svg = (new FloorPlanSvgRenderer())->render([...$planA, 'rooms' => $rooms]);
    $drawn = substr_count($svg, 'class="opening-punch"');
    jo_check('every door and window that should be drawn is drawn', $drawn === $expectedDrawn && $expectedDrawn >= 7, "drawn $drawn, expected $expectedDrawn");
}

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
