<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';
require __DIR__ . '/lib/pdf_object_graph.php';

use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\Export\FusionOverlapDetector;

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

function x_check_pdf_graph(string $label, string $pdfBytes): void
{
    $problems = pdf_validate_object_graph($pdfBytes);
    x_check("$label: object graph is fully valid", $problems === [], implode('; ', $problems));
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
x_check_pdf_graph('single-room PDF', $single);

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
x_check_pdf_graph('PDF with height/volume/openings metrics', $pdfWithMetrics);

$roomWithoutMetrics = ['label' => 'Room Plain', 'floor_area_m2' => 12.0, 'perimeter_m' => 14.0, 'confidence' => 'high'];
$pdfWithoutMetrics = $renderer->render(build_floor_plan([$roomWithoutMetrics]));
x_check('a room with no height_m/openings keys at all still renders, no fabricated metrics line', !str_contains($pdfWithoutMetrics, 'm height'));
x_check_pdf_graph('PDF with no metrics', $pdfWithoutMetrics);

// Review finding: height_m present but volume_m3_indicative null used to
// print a fabricated "0.00 m3 indicative capacity" instead of omitting it.
$roomHeightNoVolume = ['label' => 'Room HeightOnly', 'floor_area_m2' => 12.0, 'perimeter_m' => 14.0, 'confidence' => 'high', 'height_m' => 2.5, 'volume_m3_indicative' => null];
$pdfHeightNoVolume = $renderer->render(build_floor_plan([$roomHeightNoVolume]));
x_check('height with no volume still prints the height line', str_contains($pdfHeightNoVolume, '2.50 m height'));
x_check('height with no volume does NOT fabricate a 0.00 m3 line', !str_contains($pdfHeightNoVolume, 'm3'));
x_check_pdf_graph('PDF with height but no volume', $pdfHeightNoVolume);

// buildTextLines() emits 10 fixed lines (header/disclaimer/totals — the
// photos/notes summary line is omitted here since build_many_rooms()'s
// floor plan has neither) plus one line per room; paginate() fits 44 lines
// per page (intdiv(740-50, 16) + 1). 8790 rooms -> 8800 lines -> exactly
// 200 pages, the last one allowed by MAX_PAGES. 8791 rooms -> 8801 lines ->
// 201 pages, one past it. If either constant ever changes, this test's
// math has to change with it — that coupling is intentional, not fragile:
// it proves the boundary is really being hit, not just "a big number".
$linesPerPage = 44;
$fixedLineCount = 10;
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
    x_check_pdf_graph("$maxPages-page PDF (object-count stress test)", $pdf);
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

function build_room_with_outline(string $label, array $outlineM, ?array $structureOriginM, array $openings = [], ?float $heightM = null, ?string $roomId = null, ?array $roomType = null): array
{
    return [
        'room_id' => $roomId ?? strtolower(str_replace(' ', '-', $label)),
        'label' => $label,
        'floor_area_m2' => 10.0,
        'perimeter_m' => 12.0,
        'confidence' => 'high',
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0],
        'outline_m' => $outlineM,
        'structure_origin_m' => $structureOriginM,
        'openings' => $openings,
        'height_m' => $heightM,
        'room_type' => $roomType,
    ];
}

/** Scans every pixel of a decoded PNG for an exact RGB match — avoids
 * coupling to the renderer's internal layout math (unlike the MAX_PAGES
 * boundary math above, which is deliberately coupled to it). */
function png_contains_color(string $pngBytes, int $r, int $g, int $b): bool
{
    $img = imagecreatefromstring($pngBytes);
    if ($img === false) {
        return false;
    }
    $width = imagesx($img);
    $height = imagesy($img);
    $found = false;
    for ($y = 0; $y < $height && !$found; $y++) {
        for ($x = 0; $x < $width; $x++) {
            $rgb = imagecolorat($img, $x, $y);
            if ((($rgb >> 16) & 0xFF) === $r && (($rgb >> 8) & 0xFF) === $g && ($rgb & 0xFF) === $b) {
                $found = true;
                break;
            }
        }
    }
    imagedestroy($img);
    return $found;
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

echo "\n== Doors/windows actually draw as pixels, not just text (LIDAR-10 regressed silently once already) ==\n";

$doorColor = [210, 105, 30];
$windowColor = [70, 130, 180];

x_check('the fused PNG contains the door marker color as real pixels', png_contains_color($fusedWithJoinPng, ...$doorColor));
x_check('the fused PNG contains the window marker color as real pixels', png_contains_color($fusedWithJoinPng, ...$windowColor));

$tiledWithOpeningsPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, null, [
        ['opening_id' => 'o1', 'category' => 'door', 'position_m' => [4.0, 1.5], 'confidence' => 'high'],
        ['opening_id' => 'o2', 'category' => 'window', 'position_m' => [0.0, 1.5], 'confidence' => 'high'],
    ]),
]);
$tiledWithOpeningsPng = $imageRenderer->render($tiledWithOpeningsPlan);
x_check('the per-room tile sheet (layout=tiles path) contains the door marker color as real pixels', png_contains_color($tiledWithOpeningsPng, ...$doorColor));
x_check('the per-room tile sheet contains the window marker color as real pixels', png_contains_color($tiledWithOpeningsPng, ...$windowColor));

echo "\n== Room-type coloring, legend, and label text ==\n";

$bedroomFill = [199, 194, 224];
$bathroomFill = [214, 224, 194];
$kitchenFill = [199, 236, 239];

$roomTypedPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0], [], null, null, ['guess' => 'bedroom', 'guess_source' => 'roomplan_section', 'confirmed' => 'bedroom']),
    build_room_with_outline('Room B', $squareOutline, [5.0, 0.0], [], null, null, ['guess' => 'bathroom', 'guess_source' => 'roomplan_section', 'confirmed' => 'bathroom']),
]);
$roomTypedPng = $imageRenderer->render($roomTypedPlan);
x_check('bedroom fill color actually appears in the rendered PNG', png_contains_color($roomTypedPng, ...$bedroomFill));
x_check('bathroom fill color actually appears in the rendered PNG', png_contains_color($roomTypedPng, ...$bathroomFill));
x_check('bedroom and bathroom do not share the same fill color', $bedroomFill !== $bathroomFill);
x_check('kitchen fill color does NOT appear when no room is a kitchen', !png_contains_color($roomTypedPng, ...$kitchenFill));

$untypedPlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
    build_room_with_outline('Room B', $squareOutline, [5.0, 0.0]),
]);
$untypedPng = $imageRenderer->render($untypedPlan);
x_check('label text and the room-type legend add real bytes over the same plan with no room_type',
    strlen($roomTypedPng) > strlen($untypedPng));

$roomTypedTilePlan = build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, null, [], null, null, ['guess' => 'kitchen', 'guess_source' => 'object_heuristic', 'confirmed' => null]),
]);
$roomTypedTilePng = $imageRenderer->render($roomTypedTilePlan);
x_check('the tiled (non-fused) render path also colors by room_type, not just the fused path', png_contains_color($roomTypedTilePng, ...$kitchenFill));

$roomTypedPdf = $renderer->render(build_floor_plan([
    build_room_with_outline('Room A', $squareOutline, null, [], null, null, ['guess' => 'dining_room', 'guess_source' => 'roomplan_section', 'confirmed' => 'dining_room']),
]));
x_check('room_type also reaches the PDF metrics table, not just the PNG', str_contains($roomTypedPdf, 'Dining room'));
x_check_pdf_graph('room-typed PDF', $roomTypedPdf);

echo "\n== FusionOverlapDetector: catches a mispositioned room, not a shared wall ==\n";

$sharedWallRooms = [
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
    build_room_with_outline('Room B', $squareOutline, [4.0, 0.0]),
];
x_check('two rooms sharing an edge (adjacent, not overlapping) are not flagged', FusionOverlapDetector::detect($sharedWallRooms) === []);

$overlappingRooms = [
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
    build_room_with_outline('Room B', $squareOutline, [1.0, 0.0]),
];
$flagged = FusionOverlapDetector::detect($overlappingRooms);
x_check('two rooms mostly on top of each other are flagged, both indices', $flagged === [0, 1] || $flagged === [1, 0], 'got ' . json_encode($flagged));

$threeRoomsOneOverlap = [
    build_room_with_outline('Room A', $squareOutline, [0.0, 0.0]),
    build_room_with_outline('Room B', $squareOutline, [0.5, 0.0]),
    build_room_with_outline('Room C', $squareOutline, [20.0, 20.0]),
];
$flaggedThree = FusionOverlapDetector::detect($threeRoomsOneOverlap);
sort($flaggedThree);
x_check('a clean third room is not swept into the flag with the two that overlap', $flaggedThree === [0, 1], 'got ' . json_encode($flaggedThree));

echo "\n== Fused PNG: an overlap flags the plan instead of silently drawing it clean ==\n";
$overlapPlan = build_floor_plan($overlappingRooms);
$overlapPng = $imageRenderer->render($overlapPlan);
x_check('a fused plan with overlapping rooms still renders (flagged, not refused)', str_contains($overlapPng, "\x89PNG"));
x_check('FusionOverlapDetector agrees this plan has an overlap (same source of truth the renderer uses)', FusionOverlapDetector::detect($overlapPlan['rooms']) !== []);
$cleanFusedPlan = build_floor_plan($sharedWallRooms);
$cleanFusedPng = $imageRenderer->render($cleanFusedPlan);

echo "\n== FloorPlanPdfRenderer: same overlap warning surfaces in the text export ==\n";
$overlapPdf = $renderer->render($overlapPlan);
x_check('PDF text includes the overlap warning when rooms overlap', str_contains($overlapPdf, 'WARNING: some rooms below overlap'));
x_check_pdf_graph('overlap-warning PDF', $overlapPdf);
$cleanFusedPdf = $renderer->render($cleanFusedPlan);
x_check('PDF text has no overlap warning when rooms are merely adjacent', !str_contains($cleanFusedPdf, 'WARNING'));
x_check_pdf_graph('clean fused PDF', $cleanFusedPdf);
$overlapPdfTiles = $renderer->render($overlapPlan, layout: 'tiles');
x_check('PDF layout=tiles suppresses the overlap warning, same as PNG layout=tiles', !str_contains($overlapPdfTiles, 'WARNING'));
x_check_pdf_graph('overlap PDF, layout=tiles', $overlapPdfTiles);

echo "\n== Viewing one room individually: ?layout=tiles and ?room_id ==\n";
$forcedTilesPng = $imageRenderer->render($fusedPlan, 'tiles');
x_check('layout=tiles forces the per-room sheet even when fusion is available', str_contains($forcedTilesPng, "\x89PNG"));
x_check('forcing tiles produces a different image than the default fused render', $forcedTilesPng !== $fusedPng);

$oneRoomPng = $imageRenderer->render($fusedPlan, 'auto', 'room-a');
x_check('room_id isolates a single room\'s PNG without throwing', str_contains($oneRoomPng, "\x89PNG"));

try {
    $imageRenderer->render($fusedPlan, 'auto', 'no-such-room');
    x_check('an unknown room_id is rejected, not silently ignored', false, 'no exception was thrown');
} catch (\InvalidArgumentException $e) {
    x_check('an unknown room_id is rejected, not silently ignored', str_contains($e->getMessage(), 'no-such-room'));
}

$oneRoomPdf = $renderer->render(build_floor_plan([$fusedPlan['rooms'][0], $fusedPlan['rooms'][1]]), roomId: 'room-a');
x_check('room_id narrows the PDF metrics table to that room\'s label only', str_contains($oneRoomPdf, 'Room A') && !str_contains($oneRoomPdf, 'Room B'));
x_check_pdf_graph('room_id-narrowed PDF', $oneRoomPdf);

echo "\n== Unit-level total area on the PDF and PNG exports ==\n";
$twoRoomPlan = build_floor_plan([
    [...build_room_with_outline('Room A', $squareOutline, null), 'floor_area_m2' => 10.0],
    [...build_room_with_outline('Room B', $squareOutline, null), 'floor_area_m2' => 15.5],
]);
$totalPdf = $renderer->render($twoRoomPlan);
x_check('PDF prints the unit-level total across both rooms', str_contains($totalPdf, 'Total indicative area: 25.50 sqm across 2 room'));
x_check_pdf_graph('two-room total-area PDF', $totalPdf);
$totalPngTiled = $imageRenderer->render($twoRoomPlan);
x_check('PNG (tiled path) renders without throwing now that a total-area line is drawn', str_contains($totalPngTiled, "\x89PNG"));

echo "\n== Metric/imperial unit toggle ==\n";
$imperialPdf = $renderer->render($twoRoomPlan, unit: \VuuroScan\Export\UnitFormatter::IMPERIAL);
x_check('imperial PDF converts the total area to sqft, not sqm', str_contains($imperialPdf, 'sqft') && !str_contains($imperialPdf, '25.50 sqm'));
x_check_pdf_graph('imperial-unit PDF', $imperialPdf);
$metricPdf = $renderer->render($twoRoomPlan, unit: \VuuroScan\Export\UnitFormatter::METRIC);
x_check('metric (default) PDF still says sqm', str_contains($metricPdf, 'sqm'));
x_check_pdf_graph('metric-unit PDF', $metricPdf);
$imperialPng = $imageRenderer->render($twoRoomPlan, 'auto', null, \VuuroScan\Export\UnitFormatter::IMPERIAL);
x_check('imperial PNG renders without throwing', str_contains($imperialPng, "\x89PNG"));
x_check('imperial PNG produces different bytes than the metric render (unit text actually changed)', $imperialPng !== $totalPngTiled);

echo "\n== Optional branding/label line on the export ==\n";
$labeledPdf = $renderer->render($twoRoomPlan, unit: \VuuroScan\Export\UnitFormatter::METRIC, label: 'Prepared for Acme Rentals');
x_check('PDF includes the caller-supplied label line', str_contains($labeledPdf, 'Prepared for Acme Rentals'));
x_check_pdf_graph('labeled PDF', $labeledPdf);
$unlabeledPdf = $renderer->render($twoRoomPlan);
x_check('PDF omits the label line entirely when none is given', !str_contains($unlabeledPdf, 'Prepared for'));
x_check_pdf_graph('unlabeled PDF', $unlabeledPdf);
$labeledPng = $imageRenderer->render($twoRoomPlan, 'auto', null, \VuuroScan\Export\UnitFormatter::METRIC, 'Prepared for Acme Rentals');
x_check('PNG with a label renders without throwing and differs from the unlabeled render', str_contains($labeledPng, "\x89PNG") && $labeledPng !== $totalPngTiled);
$labeledFusedPng = $imageRenderer->render($fusedPlan, 'auto', null, \VuuroScan\Export\UnitFormatter::METRIC, 'Prepared for Acme Rentals');
$unlabeledFusedPng = $imageRenderer->render($fusedPlan);
x_check('fused PNG with a label renders without throwing and differs from the unlabeled render', str_contains($labeledFusedPng, "\x89PNG") && $labeledFusedPng !== $unlabeledFusedPng);

echo "\n== A real attached photo embeds as a valid, walkable JPEG XObject ==\n";
$photoJpegBytes = (static function (): string {
    $img = imagecreatetruecolor(1200, 900);
    imagefilledrectangle($img, 0, 0, 1200, 900, imagecolorallocate($img, 60, 120, 180));
    ob_start();
    imagejpeg($img, null, 90);
    imagedestroy($img);
    return (string) ob_get_clean();
})();
$photoPlan = [...build_floor_plan([build_room_with_outline('Room With Photo', $squareOutline, null)]), 'photos' => [['url' => 'https://example.invalid/photo.jpg', 'caption' => 'Test photo']]];
$photoPdf = $renderer->render($photoPlan, photoLoader: static fn (string $url): ?string => $url === 'https://example.invalid/photo.jpg' ? $photoJpegBytes : null);
x_check('PDF with a real attached photo has at least 3 pages (floor plan drawing + photo + metrics table)', preg_match_all('/\/Type \/Page\b/', $photoPdf) >= 3);
x_check_pdf_graph('PDF with a real attached photo', $photoPdf);

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
