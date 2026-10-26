<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\DimensionRuns;
use VuuroScan\Export\FloorPlanSvgRenderer;

$failures = [];
$checks = 0;

function dr_check(string $label, bool $pass, string $detail = ''): void
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

function dr_near(array $actual, array $expected): bool
{
    if (count($actual) !== count($expected)) {
        return false;
    }
    foreach ($expected as $i => $v) {
        if (abs($actual[$i] - $v) > 0.01) {
            return false;
        }
    }
    return true;
}

function dr_show(array $values): string
{
    return '[' . implode(', ', array_map(static fn ($v) => number_format($v, 2), $values)) . ']';
}

echo "== One room: a straight wall split into segments ==\n";
$attic = [[0.0, 0.0], [2.30, 0.0], [4.98, 0.0], [8.88, 0.0], [8.88, 6.0], [0.0, 6.0]];
$x = DimensionRuns::forOutline($attic, 0);
dr_check('collinear points on one wall give one dimension', dr_near($x, [0.0, 8.88]), dr_show($x));
$z = DimensionRuns::forOutline($attic, 1);
dr_check('the other axis is the room depth', dr_near($z, [0.0, 6.0]), dr_show($z));

$skewed = [[0.0, 0.0], [2.30, 0.03], [4.98, 0.05], [8.88, 0.09], [8.90, 6.0], [0.0, 6.0]];
$x = DimensionRuns::forOutline($skewed, 0);
dr_check('a slightly crooked wall still gives one dimension', dr_near($x, [0.0, 8.90]), dr_show($x));

echo "== One room: a real jog keeps its break ==\n";
$lShape = [[0.0, 0.0], [5.0, 0.0], [5.0, 2.0], [8.0, 2.0], [8.0, 6.0], [0.0, 6.0]];
$x = DimensionRuns::forOutline($lShape, 0);
dr_check('the step in the outline breaks the chain', dr_near($x, [0.0, 5.0, 8.0]), dr_show($x));
$z = DimensionRuns::forOutline($lShape, 1);
dr_check('the step breaks the other axis too', dr_near($z, [0.0, 2.0, 6.0]), dr_show($z));

$tinyJog = [[0.0, 0.0], [4.0, 0.0], [4.0, 0.1], [8.0, 0.1], [8.0, 5.0], [0.0, 5.0]];
$x = DimensionRuns::forOutline($tinyJog, 0);
dr_check('a jog shorter than 0.3 m does not break the chain', dr_near($x, [0.0, 8.0]), dr_show($x));

echo "== One room: open edges are not walls ==\n";
$open = [[0.0, 0.0], [3.0, 0.0], [3.0, 2.0], [6.0, 2.0], [6.0, 4.0], [0.0, 4.0]];
$x = DimensionRuns::forOutline($open, 0, [1]);
dr_check('an open edge does not add a break', dr_near($x, [0.0, 6.0]), dr_show($x));

echo "== Fused plan: shared walls do not split the outer wall ==\n";
$rooms = [
    ['outline_m' => [[0.0, 0.0], [2.30, 0.0], [2.30, 3.10], [0.0, 3.10]], 'open_edges' => []],
    ['outline_m' => [[0.0, 0.0], [2.68, 0.0], [2.68, 3.10], [0.0, 3.10]], 'open_edges' => []],
    ['outline_m' => [[0.0, 0.0], [3.90, 0.0], [3.90, 3.10], [0.0, 3.10]], 'open_edges' => []],
];
$pose = static fn (float $x) => ['originX' => $x, 'originZ' => 0.0, 'rotationRad' => 0.0];
$poses = [$pose(0.0), $pose(2.30), $pose(4.98)];
$tiers = [0 => [1 => 0.1], 1 => [1 => 0.1, 3 => 0.1], 2 => [3 => 0.1]];
$x = DimensionRuns::forFused($rooms, $poses, $tiers, 0);
dr_check('three rooms in a row give one outer dimension', dr_near($x, [0.0, 8.88]), dr_show($x));
$x = DimensionRuns::forFused($rooms, $poses, [], 0);
dr_check('without shared-wall marks every wall still breaks', dr_near($x, [0.0, 2.30, 4.98, 8.88]), dr_show($x));

echo "== Rendered tile ==\n";
$plan = [
    'property_id' => 'prop-dim-test',
    'unit_id' => 'unit-dim-test',
    'organisation_id' => 'org-dim-test',
    'purpose' => 'listing',
    'captured_at' => gmdate('c'),
    'capture_provider' => 'test',
    'measurement_basis' => 'indicative_nen2580_inspired',
    'rooms' => [[
        'room_id' => 'attic',
        'label' => 'Attic',
        'floor_area_m2' => 53.3,
        'perimeter_m' => 29.8,
        'confidence' => 'high',
        'bounding_dimensions_m' => ['width_m' => 8.88, 'length_m' => 6.0],
        'outline_m' => $attic,
        'structure_origin_m' => null,
        'openings' => [],
        'height_m' => null,
        'room_type' => null,
        'heading_deg' => null,
    ]],
    'photos' => [],
    'notes' => [],
];
$svg = (new FloorPlanSvgRenderer())->render($plan);
dr_check('the SVG shows the full wall length', str_contains($svg, '8.88 m'));
dr_check('the SVG no longer shows the split pieces', !str_contains($svg, '2.30 m') && !str_contains($svg, '2.68 m') && !str_contains($svg, '3.90 m'));

echo "\n$checks check(s), " . count($failures) . " failure(s).\n";
if ($failures !== []) {
    echo "TEST VERDICT: RED\n";
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);
