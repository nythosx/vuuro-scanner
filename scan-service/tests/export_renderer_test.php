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
