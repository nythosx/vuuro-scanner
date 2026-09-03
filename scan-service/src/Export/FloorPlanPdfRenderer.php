<?php

declare(strict_types=1);

namespace VuuroScan\Export;

/**
 * Renders a FloorPlan contract array to a minimal, hand-built PDF: identity,
 * honest-measurement disclaimer, and a per-room metrics table, paginated
 * across as many pages as the room count needs. No external PDF library —
 * the PDF spec's object/xref/trailer structure is simple enough for
 * text-only pages that pulling in a dependency for it isn't worth it. Does
 * not attempt any spatial layout; see docs/adr/0002-export-coordinate-frame.md
 * for why FloorPlanImageRenderer doesn't either. Paginates real content
 * across as many pages as needed rather than silently clipping rows past
 * the bottom of a single fixed-size page.
 */
final class FloorPlanPdfRenderer
{
    private const PAGE_TOP_Y = 740;
    private const PAGE_BOTTOM_MARGIN_Y = 50;
    private const LINE_HEIGHT = 16;
    // Defense-in-depth, same spirit as FloorPlanImageRenderer's
    // MAX_CANVAS_DIMENSION_PX — bounds how many PDF pages/objects a single
    // render can build. Generous; thousands of rooms is not a real unit.
    private const MAX_PAGES = 200;

    /** @param string|null $roomId When set, the metrics table covers only that one room. */
    public function render(array $floorPlan, ?string $roomId = null): string
    {
        if ($roomId !== null) {
            $rooms = array_values(array_filter($floorPlan['rooms'], static fn (array $room) => $room['room_id'] === $roomId));
            if ($rooms === []) {
                throw new \InvalidArgumentException("No room with room_id '{$roomId}' in this floor plan.");
            }
            $floorPlan = [...$floorPlan, 'rooms' => $rooms];
        }
        $lines = $this->buildTextLines($floorPlan);
        $pages = $this->paginate($lines);

        if (count($pages) > self::MAX_PAGES) {
            throw new \InvalidArgumentException(sprintf(
                'This floor plan would need %d PDF pages, exceeding the %d page sanity bound — refusing to render it.',
                count($pages),
                self::MAX_PAGES
            ));
        }

        $objects = [];
        $objects[1] = null; // filled in below once page object numbers are known
        $fontObjNum = 3;
        $objects[$fontObjNum] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";

        $pageObjNums = [];
        $nextObjNum = $fontObjNum + 1;
        foreach ($pages as $pageLines) {
            $pageObjNum = $nextObjNum++;
            $contentObjNum = $nextObjNum++;
            $pageObjNums[] = $pageObjNum;

            $contentStream = $this->buildContentStream($pageLines);
            $objects[$pageObjNum] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                . "/Resources << /Font << /F1 {$fontObjNum} 0 R >> >> /Contents {$contentObjNum} 0 R >>";
            $objects[$contentObjNum] = "<< /Length " . strlen($contentStream) . " >>\nstream\n" . $contentStream . "\nendstream";
        }

        $kids = implode(' ', array_map(static fn (int $n) => "{$n} 0 R", $pageObjNums));
        $objects[1] = "<< /Type /Catalog /Pages 2 0 R >>";
        $objects[2] = "<< /Type /Pages /Kids [{$kids}] /Count " . count($pageObjNums) . ' >>';
        ksort($objects);

        return $this->assemblePdf($objects);
    }

    /**
     * Splits lines across pages so every line lands within the visible
     * MediaBox. Always returns at least one page, even for zero lines, so a
     * session with rooms but otherwise-empty text still gets a real (if
     * sparse) PDF.
     *
     * @param string[] $lines
     * @return array<int, string[]>
     */
    private function paginate(array $lines): array
    {
        $maxLinesPerPage = intdiv(self::PAGE_TOP_Y - self::PAGE_BOTTOM_MARGIN_Y, self::LINE_HEIGHT) + 1;
        $pages = array_chunk($lines, max($maxLinesPerPage, 1));
        return $pages === [] ? [[]] : $pages;
    }

    /** @return string[] */
    private function buildTextLines(array $floorPlan): array
    {
        $lines = [];
        $lines[] = 'Vuuro Scan — Floor Plan Metrics';
        $lines[] = '';
        $lines[] = sprintf('Property: %s   Unit: %s   Organisation: %s', $floorPlan['property_id'], $floorPlan['unit_id'], $floorPlan['organisation_id']);
        $lines[] = sprintf('Purpose: %s   Captured: %s   Provider: %s', $floorPlan['purpose'], $floorPlan['captured_at'], $floorPlan['capture_provider']);
        $lines[] = '';
        $lines[] = $floorPlan['measurement_basis'] === 'indicative_nen2580_inspired'
            ? 'Indicative, NEN2580-inspired measurements. This is NOT a certified survey.'
            : 'Measurement basis: ' . $floorPlan['measurement_basis'];
        $lines[] = '';
        $isFused = count($floorPlan['rooms']) > 1 && array_reduce(
            $floorPlan['rooms'],
            fn (bool $carry, array $room) => $carry && isset($room['structure_origin_m']),
            true
        );
        if ($isFused && FusionOverlapDetector::detect($floorPlan['rooms']) !== []) {
            $lines[] = 'WARNING: some rooms below overlap in captured position — verify against the real layout before use.';
            $lines[] = '';
        }
        $lines[] = 'Rooms';
        $lines[] = '-----';
        $totalArea = 0.0;
        foreach ($floorPlan['rooms'] as $room) {
            $totalArea += $room['floor_area_m2'];
            $lines[] = sprintf(
                '%-12s %8.2f m2   %8.2f m perimeter   confidence: %s',
                $room['label'],
                $room['floor_area_m2'],
                $room['perimeter_m'],
                $room['confidence']
            );
            $heightM = $room['height_m'] ?? null;
            $volumeM3 = $room['volume_m3_indicative'] ?? null;
            if ($heightM !== null && $volumeM3 !== null) {
                $lines[] = sprintf('             %8.2f m height   %8.2f m3 indicative capacity', $heightM, $volumeM3);
            } elseif ($heightM !== null) {
                $lines[] = sprintf('             %8.2f m height', $heightM);
            }
            $openings = $room['openings'] ?? [];
            if ($openings !== []) {
                $counts = [];
                foreach ($openings as $opening) {
                    $counts[$opening['category']] = ($counts[$opening['category']] ?? 0) + 1;
                }
                $summary = implode(', ', array_map(
                    static fn (string $category, int $count) => "{$count} {$category}" . ($count === 1 ? '' : 's'),
                    array_keys($counts),
                    array_values($counts)
                ));
                $lines[] = "             {$summary}";
            }
        }
        $lines[] = '';
        $lines[] = sprintf('Total indicative area: %.2f m2 across %d room(s)', $totalArea, count($floorPlan['rooms']));
        $lines[] = '';
        $lines[] = sprintf('Photos attached: %d   Notes attached: %d', count($floorPlan['photos']), count($floorPlan['notes']));

        return $lines;
    }

    /** @param string[] $lines */
    private function buildContentStream(array $lines): string
    {
        $stream = "BT\n/F1 11 Tf\n";
        $y = 740;
        foreach ($lines as $line) {
            // Base-14 Helvetica in a plain PDF string literal is
            // single-byte StandardEncoding, not UTF-8 — raw multi-byte
            // characters (e.g. an em dash) would render as mojibake in a
            // real viewer, so this stays ASCII-only rather than risk that.
            $ascii = preg_replace('/[^\x20-\x7E]/', '-', $line) ?? $line;
            $escaped = str_replace(['\\', '(', ')'], ['\\\\', '\\(', '\\)'], $ascii);
            $stream .= "1 0 0 1 50 {$y} Tm\n({$escaped}) Tj\n";
            $y -= 16;
        }
        $stream .= "ET";
        return $stream;
    }

    /** @param array<int, string> $objects Object bodies keyed by object number (1-indexed, contiguous) */
    private function assemblePdf(array $objects): string
    {
        $pdf = "%PDF-1.4\n";
        $offsets = [];

        foreach ($objects as $number => $body) {
            $offsets[$number] = strlen($pdf);
            $pdf .= "{$number} 0 obj\n{$body}\nendobj\n";
        }

        $xrefOffset = strlen($pdf);
        $count = count($objects) + 1;
        $pdf .= "xref\n0 {$count}\n";
        $pdf .= "0000000000 65535 f \n";
        for ($i = 1; $i <= count($objects); $i++) {
            $pdf .= sprintf("%010d 00000 n \n", $offsets[$i]);
        }

        $pdf .= "trailer\n<< /Size {$count} /Root 1 0 R >>\n";
        $pdf .= "startxref\n{$xrefOffset}\n%%EOF";

        return $pdf;
    }
}
