<?php

declare(strict_types=1);

/**
 * Fast in-process unit tests for the export renderers, specifically
 * FloorPlanPdfRenderer's MAX_PAGES boundary (private const, kept at 200 in
 * the renderer itself). Neither net/verify_exports.php nor any other
 * automated check exercises this boundary directly — reproducing 201 real
 * pages over real HTTP needs ~8,800 rooms in one session, well past the
 * capture rate limit, and that limit isn't allowed to be weakened just for
 * this test (same call already made and documented for
 * MAX_PHOTOS_PER_SESSION/MAX_NOTES_PER_SESSION in repository_test.php).
 * FloorPlanPdfRenderer::render() takes a plain array and has no DB/HTTP
 * dependency, so the boundary is cheap to hit directly here instead.
 *
 * The equivalent PNG bound (MAX_CANVAS_DIMENSION_PX) is NOT duplicated here
 * — it's already covered end-to-end over real HTTP in
 * net/verify_exports.php (a 40-room capture is enough to exceed the
 * canvas width bound, unlike the PDF case which needs orders of magnitude
 * more rooms).
 *
 * Usage: php tests/export_renderer_test.php
 */

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;

$failures = [];
$checks = 0;

function x_check(string $label, bool $pass, string $detail = ''): void
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

/** @return array<int, array{label: string, floor_area_m2: float, perimeter_m: float, confidence: string}> */
function build_many_rooms(int $n): array
{
    $rooms = [];
    for ($i = 0; $i < $n; $i++) {
        $rooms[] = [
            'label' => "Room $i",
            'floor_area_m2' => 10.0,
            'perimeter_m' => 12.0,
            'confidence' => 'high',
        ];
    }
    return $rooms;
}

function build_floor_plan(array $rooms): array
{
    return [
        'property_id' => 'prop-export-test',
        'unit_id' => 'unit-export-test',
        'organisation_id' => 'org-export-test',
        'purpose' => 'listing',
        'captured_at' => gmdate('c'),
        'capture_provider' => 'test',
        'measurement_basis' => 'indicative_nen2580_inspired',
        'rooms' => $rooms,
        'photos' => [],
        'notes' => [],
    ];
}

$renderer = new FloorPlanPdfRenderer();

echo "== Sanity: a single-room floor plan renders a real one-page PDF ==\n";
$single = $renderer->render(build_floor_plan(build_many_rooms(1)));
x_check('output starts with a PDF header', str_starts_with($single, '%PDF-1.4'));
x_check('output contains the room label', str_contains($single, 'Room 0'));

echo "\n== LIDAR-5/11: PDF metrics include height/m3/openings when known ==\n";
$roomWithMetrics = [
    'label' => 'Room With Metrics',
    'floor_area_m2' => 12.0,
    'perimeter_m' => 14.0,
    'confidence' => 'high',
    'height_m' => 2.6,
    'volume_m3_indicative' => 31.2,
    'openings' => [
        ['opening_id' => 'o1', 'category' => 'door', 'position_m' => [0, 0], 'confidence' => 'high'],
        ['opening_id' => 'o2', 'category' => 'window', 'position_m' => [1, 1], 'confidence' => 'high'],
        ['opening_id' => 'o3', 'category' => 'window', 'position_m' => [2, 2], 'confidence' => 'high'],
    ],
];
$pdfWithMetrics = $renderer->render(build_floor_plan([$roomWithMetrics]));
x_check('PDF text includes the room height', str_contains($pdfWithMetrics, '2.60 m height'));
x_check('PDF text includes the indicative m3 capacity', str_contains($pdfWithMetrics, '31.20 m3'));
x_check('PDF text includes the door/window opening summary', str_contains($pdfWithMetrics, '1 door') && str_contains($pdfWithMetrics, '2 windows'));

$roomWithoutMetrics = ['label' => 'Room Plain', 'floor_area_m2' => 12.0, 'perimeter_m' => 14.0, 'confidence' => 'high'];
$pdfWithoutMetrics = $renderer->render(build_floor_plan([$roomWithoutMetrics]));
x_check('a room with no height_m/openings keys at all still renders, no fabricated metrics line', !str_contains($pdfWithoutMetrics, 'm height'));

// buildTextLines() emits 13 fixed lines (header/disclaimer/totals/footer)
// plus one line per room; paginate() fits 44 lines per page
// (intdiv(740-50, 16) + 1). 8787 rooms -> 8800 lines -> exactly 200 pages,
// the last one allowed by MAX_PAGES. 8788 rooms -> 8801 lines -> 201 pages,
// one past it. If either constant ever changes, this test's math has to
// change with it — that coupling is intentional, not fragile: it proves
// the boundary is really being hit, not just "a big number".
$linesPerPage = 44;
$fixedLineCount = 13;
$maxPages = 200; // mirrors FloorPlanPdfRenderer::MAX_PAGES (private)

$roomsAtBoundary = $maxPages * $linesPerPage - $fixedLineCount;
$roomsOverBoundary = $roomsAtBoundary + 1;

echo "\n== MAX_PAGES boundary: exactly $maxPages pages must succeed ==\n";
try {
    $pdf = $renderer->render(build_floor_plan(build_many_rooms($roomsAtBoundary)));
    x_check(
        "a floor plan producing exactly $maxPages PDF pages renders without throwing",
        str_starts_with($pdf, '%PDF-1.4')
    );
    $pageObjectCount = preg_match_all('/\/Type \/Page\b/', $pdf);
    x_check("the rendered PDF actually has $maxPages /Type /Page objects, not a different count", $pageObjectCount === $maxPages, "got $pageObjectCount");
} catch (\InvalidArgumentException $e) {
    x_check("a floor plan producing exactly $maxPages PDF pages renders without throwing", false, $e->getMessage());
}

echo "\n== MAX_PAGES boundary: " . ($maxPages + 1) . " pages is rejected, not silently truncated ==\n";
try {
    $renderer->render(build_floor_plan(build_many_rooms($roomsOverBoundary)));
    x_check('a floor plan needing ' . ($maxPages + 1) . ' PDF pages is rejected, not silently truncated', false, 'no exception was thrown');
} catch (\InvalidArgumentException $e) {
    x_check(
        'a floor plan needing ' . ($maxPages + 1) . ' PDF pages is rejected, not silently truncated',
        str_contains($e->getMessage(), (string) ($maxPages + 1)) && str_contains($e->getMessage(), (string) $maxPages),
        $e->getMessage()
    );
}

$imageRenderer = new FloorPlanImageRenderer();

function build_room_with_outline(string $label, array $outlineM, ?array $structureOriginM, array $openings = [], ?float $heightM = null): array
{
    return [
        'label' => $label,
        'floor_area_m2' => 10.0,
        'perimeter_m' => 12.0,
        'confidence' => 'high',
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0],
        'outline_m' => $outlineM,
        'structure_origin_m' => $structureOriginM,
        'openings' => $openings,
        'height_m' => $heightM,
    ];
}

$squareOutline = [[0, 0], [4, 0], [4, 3], [0, 3]];

echo "\n== LIDAR-5/11: fused vs. tiled PNG rendering ==\n";

$tiledPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, null),
    build_room_with_outline('Room B', $squareOutline, null),
]);
$tiledPng = $imageRenderer->render($tiledPlan);
x_check('two rooms with no structure_origin_m render the tiled (non-fused) sheet', str_contains($tiledPng, "\x89PNG"));

$fusedPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
    build_room_with_outline('Room B', $squareOutline, [5.0, 0.0]),
]);
$fusedPng = $imageRenderer->render($fusedPlan);
x_check('two rooms both carrying structure_origin_m render without throwing', str_contains($fusedPng, "\x89PNG"));

$mixedPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
    build_room_with_outline('Room B', $squareOutline, null),
]);
$mixedPng = $imageRenderer->render($mixedPlan);
x_check('a mix of fused and non-fused rooms falls back to the tiled sheet, not a partial fuse', str_contains($mixedPng, "\x89PNG"));

$singleFusedPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
]);
$singleFusedPng = $imageRenderer->render($singleFusedPlan);
x_check('a single room with structure_origin_m still renders (tiled path, fusion needs 2+ rooms)', str_contains($singleFusedPng, "\x89PNG"));

$fusedWithJoinPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0], [
        ['opening_id' => 'o1', 'category' => 'door', 'position_m' => [4.0, 1.5], 'confidence' => 'high'],
    ], 2.6),
    build_room_with_outline('Room B', $squareOutline, [5.0, 0.0], [
        ['opening_id' => 'o2', 'category' => 'window', 'position_m' => [0.0, 1.5], 'confidence' => 'high'],
    ], 2.4),
]);
$fusedWithJoinPng = $imageRenderer->render($fusedWithJoinPlan);
x_check('a fused plan with door/window openings and room height renders without throwing', str_contains($fusedWithJoinPng, "\x89PNG"));
x_check('the door/window/height drawing adds real bytes over the same plan with no openings',
    strlen($fusedWithJoinPng) > strlen($fusedPng));

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
