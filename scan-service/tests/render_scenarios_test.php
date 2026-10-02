<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/render_scenarios.php';

use VuuroScan\Export\FloorGroups;
use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\Export\FloorPlanSvgRenderer;
use VuuroScan\Export\RoomFusionSolver;

$failures = [];
$checks = 0;

function rs_wall_distance(array $outline, array $point): float
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

function rs_world_box(array $room, array $pose): array
{
    $xs = [];
    $zs = [];
    foreach ($room['outline_m'] as [$x, $z]) {
        [$wx, $wz] = RoomFusionSolver::transformPoint($pose, (float) $x, (float) $z);
        $xs[] = $wx;
        $zs[] = $wz;
    }
    return [min($xs), min($zs), max($xs), max($zs)];
}

function rs_check(string $label, bool $pass, string $detail = ''): void
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

$imageRenderer = new FloorPlanImageRenderer();
$svgRenderer = new FloorPlanSvgRenderer();

foreach (render_scenarios() as $key => $scenario) {
    $plan = $scenario['plan'];
    $layout = $scenario['layout'] ?? 'auto';
    $roomId = $scenario['room_id'] ?? null;
    $expectedRooms = count($plan['rooms']);

    try {
        $png = $imageRenderer->render($plan, $layout, $roomId, \VuuroScan\Export\UnitFormatter::METRIC, null);
        $svg = $svgRenderer->render($plan, $layout, $roomId, \VuuroScan\Export\UnitFormatter::METRIC, null);
        $pdf = (new FloorPlanPdfRenderer())->render($plan, $layout, $roomId, \VuuroScan\Export\UnitFormatter::METRIC, null);
    } catch (\Throwable $e) {
        rs_check("$key: renders without throwing", false, get_class($e) . ': ' . $e->getMessage());
        continue;
    }

    echo "== $key ==\n";
    $info = @getimagesizefromstring($png);
    rs_check('PNG is a non-empty image', $info !== false && $info[0] > 0 && $info[1] > 0, $info === false ? 'not an image' : ($info[0] . 'x' . $info[1]));
    rs_check('PNG stays within the canvas bound', ($info[0] ?? 0) <= 4000 && ($info[1] ?? 0) <= 4000, ($info[0] ?? 0) . 'x' . ($info[1] ?? 0));
    rs_check('PDF is produced', str_starts_with($pdf, '%PDF') && strlen($pdf) > 1000, strlen($pdf) . ' bytes');
    $roomCount = substr_count($svg, 'class="room-fill"');
    rs_check('SVG draws one room fill per room', $roomCount === $expectedRooms, "got $roomCount, expected $expectedRooms");
    $sections = FloorGroups::split($plan['rooms']);
    if (isset($scenario['sections'])) {
        rs_check('the plan has the expected number of sections', count($sections) === $scenario['sections'], 'got ' . count($sections) . ', expected ' . $scenario['sections']);
    }

    $worstOpening = 0.0;
    foreach ($plan['rooms'] as $room) {
        foreach ($room['openings'] ?? [] as $opening) {
            $worstOpening = max($worstOpening, rs_wall_distance($room['outline_m'], $opening['position_m']));
        }
    }
    rs_check('every door and window sits on a wall (<= 0.05 m)', $worstOpening <= 0.05, sprintf('worst %.3f m', $worstOpening));

    $worstOverlap = 0.0;
    foreach ($sections as $section) {
        $sectionRooms = array_values($section['rooms']);
        if ($layout === 'tiles' || !FloorGroups::isFusable($sectionRooms)) {
            continue;
        }
        $poses = RoomFusionSolver::solve($sectionRooms)['poses'];
        $boxes = array_map(static fn (array $room, int $i) => rs_world_box($room, $poses[$i]), $sectionRooms, array_keys($sectionRooms));
        foreach ($boxes as $i => $a) {
            foreach ($boxes as $j => $b) {
                if ($j <= $i) {
                    continue;
                }
                $overlapX = min($a[2], $b[2]) - max($a[0], $b[0]);
                $overlapZ = min($a[3], $b[3]) - max($a[1], $b[1]);
                if ($overlapX > 0 && $overlapZ > 0) {
                    $worstOverlap = max($worstOverlap, $overlapX * $overlapZ);
                }
            }
        }
    }
    rs_check('no two rooms of a fused section overlap after snapping (<= 0.05 m²)', $worstOverlap <= 0.05, sprintf('worst %.3f m²', $worstOverlap));
}

$device = render_scenarios()['device_single'];
$deviceSvg = (new FloorPlanSvgRenderer())->render($device['plan'], 'auto', null, \VuuroScan\Export\UnitFormatter::METRIC, null);
$openingCount = substr_count($deviceSvg, 'class="opening-punch"');
$deviceOpenings = array_sum(array_map(static fn (array $room) => count($room['openings'] ?? []), $device['plan']['rooms']));
echo "== device openings ==\n";
rs_check('every device-shaped door/window/opening is drawn', $openingCount === $deviceOpenings, "got $openingCount, expected $deviceOpenings");

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
