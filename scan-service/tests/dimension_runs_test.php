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

echo "== Per side: each side shows only the walls that face it ==\n";
$stepped = [[0.0, 0.0], [5.8, 0.0], [5.8, 3.9], [2.9, 3.9], [2.9, 6.7], [5.2, 6.7], [5.2, 8.9], [4.6, 8.9], [4.6, 10.8], [0.7, 10.8], [0.7, 9.0], [0.0, 9.0]];
$top = DimensionRuns::forOutline($stepped, 0, [], 'min');
dr_check('top side: the long straight wall is one dimension', dr_near($top, [0.0, 5.8]), dr_show($top));
$bottom = DimensionRuns::forOutline($stepped, 0, [], 'max');
dr_check('bottom side: the jogs on that side break the chain', dr_near($bottom, [0.0, 0.7, 4.6, 5.2, 5.8]), dr_show($bottom));
$left = DimensionRuns::forOutline($stepped, 1, [], 'min');
dr_check('left side: the long wall stays one dimension', dr_near($left, [0.0, 9.0, 10.8]), dr_show($left));
$right = DimensionRuns::forOutline($stepped, 1, [], 'max');
dr_check('right side: the recess and steps keep their breaks', dr_near($right, [0.0, 3.9, 6.7, 8.9, 10.8]), dr_show($right));

$markAttic = [[0.536, 10.77], [0.714, 8.983], [0.0, 8.912], [0.499, 3.904], [0.888, 0.0], [6.648, 0.574], [6.263, 4.438], [4.008, 4.214], [3.732, 6.991], [5.979, 7.215], [5.758, 9.433], [5.116, 9.369], [4.932, 11.208]];
$angle = -atan2(0.574, 5.76);
$rotatedAttic = array_map(static fn (array $p): array => [$p[0] * cos($angle) - $p[1] * sin($angle), $p[0] * sin($angle) + $p[1] * cos($angle)], $markAttic);
$atticTop = DimensionRuns::forOutline($rotatedAttic, 0, [], 'min');
dr_check('device attic: the top wall is one dimension', count($atticTop) === 2, dr_show($atticTop));
$atticLeft = DimensionRuns::forOutline($rotatedAttic, 1, [], 'min');
dr_check('device attic: the long left wall is one 8.96 m dimension', count($atticLeft) === 3 && abs($atticLeft[1] - $atticLeft[0] - 8.96) < 0.02, dr_show($atticLeft));

$splitWallAttic = [[1.79, 0.0], [4.10, 0.03], [6.85, -0.02], [10.74, 0.01], [10.75, 5.76], [6.85, 5.78], [4.10, 5.74], [1.80, 5.76], [1.79, 5.09], [0.0, 5.09], [0.01, 3.2], [0.0, 0.69], [1.78, 0.69]];
$splitTop = DimensionRuns::forOutline($splitWallAttic, 0, [], 'min');
dr_check('split long wall: top is the step plus one long dimension', count($splitTop) === 3 && abs($splitTop[2] - $splitTop[1] - 8.96) < 0.03, dr_show($splitTop));
$splitRight = DimensionRuns::forOutline($splitWallAttic, 1, [], 'max');
dr_check('split long wall: the straight right side is one dimension', count($splitRight) === 2, dr_show($splitRight));

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
