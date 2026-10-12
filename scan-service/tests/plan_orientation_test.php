<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/render_scenarios.php';

use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanStyle;
use VuuroScan\Export\FloorPlanSvgRenderer;
use VuuroScan\Export\UnitFormatter;

$failures = [];
$checks = 0;

function po_check(string $label, bool $pass, string $detail = ''): void
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

function po_rotate(array $point, float $deg): array
{
    $r = deg2rad($deg);
    return [$point[0] * cos($r) - $point[1] * sin($r), $point[0] * sin($r) + $point[1] * cos($r)];
}

function po_unit(float $deg): array
{
    $shapes = [
        ['room-01-tilt', 'Living', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0]],
        ['room-02-tilt', 'Kitchen', [[4.0, 0.0], [7.0, 0.0], [7.0, 3.0], [4.0, 3.0]], [4.0, 0.0]],
        ['room-03-tilt', 'Bedroom', [[4.0, 3.0], [7.0, 3.0], [7.0, 6.0], [4.0, 6.0]], [4.0, 3.0]],
    ];
    $rooms = [];
    foreach ($shapes as [$id, $label, $outline, $origin]) {
        $rotated = array_map(static fn (array $p) => po_rotate($p, $deg), $outline);
        $rooms[] = scenario_room($id, $label, $rotated, po_rotate($origin, $deg), 'Ground', 'tilt-g1', null);
    }
    return scenario_plan($rooms);
}

function po_worst_edge_skew_deg(string $svg): float
{
    preg_match_all('/<polygon class="room-fill" points="([^"]+)"/', $svg, $matches);
    $worst = 0.0;
    foreach ($matches[1] as $pointList) {
        $points = array_map(static fn (string $pair) => array_map('floatval', explode(',', $pair)), preg_split('/\s+/', trim($pointList)));
        $n = count($points);
        for ($i = 0; $i < $n; $i++) {
            [$ax, $ay] = $points[$i];
            [$bx, $by] = $points[($i + 1) % $n];
            if (hypot($bx - $ax, $by - $ay) < 20) {
                continue;
            }
            $angle = rad2deg(atan2($by - $ay, $bx - $ax));
            $off = fmod(abs($angle), 90.0);
            $worst = max($worst, min($off, 90.0 - $off));
        }
    }
    return $worst;
}

$asCaptured = FloorPlanStyle::from('default', null, null, 'as_captured');
$straightened = FloorPlanStyle::from('default', null, null, 'longest_horizontal');

echo "== A unit scanned at 12 degrees ==\n";
$tilted = po_unit(12.0);
$svgAs = (new FloorPlanSvgRenderer())->render($tilted, 'auto', null, UnitFormatter::METRIC, null, $asCaptured);
$svgStraight = (new FloorPlanSvgRenderer())->render($tilted, 'auto', null, UnitFormatter::METRIC, null, $straightened);
$pngAs = (new FloorPlanImageRenderer())->render($tilted, 'auto', null, UnitFormatter::METRIC, null, $asCaptured);
$pngStraight = (new FloorPlanImageRenderer())->render($tilted, 'auto', null, UnitFormatter::METRIC, null, $straightened);

po_check('SVG draws all three rooms in both modes', substr_count($svgAs, 'class="room-fill"') === 3 && substr_count($svgStraight, 'class="room-fill"') === 3);
$skewAs = po_worst_edge_skew_deg($svgAs);
$skewStraight = po_worst_edge_skew_deg($svgStraight);
po_check('as scanned keeps the walls at the scanned angle', $skewAs > 10.0, sprintf('worst skew %.2f deg', $skewAs));
po_check('straightened puts every wall on the horizontal or vertical axis', $skewStraight < 0.5, sprintf('worst skew %.2f deg', $skewStraight));
po_check('the two PNGs are different images', $pngAs !== $pngStraight);
po_check('both PNGs are real images', @getimagesizefromstring($pngAs) !== false && @getimagesizefromstring($pngStraight) !== false);

echo "\n== A unit scanned square to the walls ==\n";
$square = po_unit(0.0);
$squareAs = (new FloorPlanSvgRenderer())->render($square, 'auto', null, UnitFormatter::METRIC, null, $asCaptured);
$squareStraight = (new FloorPlanSvgRenderer())->render($square, 'auto', null, UnitFormatter::METRIC, null, $straightened);
po_check('as scanned is already axis-aligned', po_worst_edge_skew_deg($squareAs) < 0.5);
po_check('straightened stays axis-aligned', po_worst_edge_skew_deg($squareStraight) < 0.5);

$outDir = getenv('PLAN_ORIENTATION_OUT');
if (is_string($outDir) && $outDir !== '' && is_dir($outDir)) {
    file_put_contents($outDir . '/tilted_as_captured.png', $pngAs);
    file_put_contents($outDir . '/tilted_straightened.png', $pngStraight);
}

echo "\n$checks checks, " . count($failures) . " failed\n";
echo count($failures) === 0 ? "TEST VERDICT: GREEN\n" : "TEST VERDICT: RED\n";
exit(count($failures) === 0 ? 0 : 1);
