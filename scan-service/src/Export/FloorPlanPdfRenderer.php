<?php

declare(strict_types=1);

namespace VuuroScan\Export;

/**
 * Renders a FloorPlan contract array to a minimal, hand-built single-page
 * PDF: identity, honest-measurement disclaimer, and a per-room metrics
 * table. No external PDF library — the PDF spec's object/xref/trailer
 * structure is simple enough for one text-only page that pulling in a
 * dependency for it isn't worth it. Does not attempt any spatial layout;
 * see docs/adr/0002-export-coordinate-frame.md for why FloorPlanImageRenderer
 * doesn't either.
 */
final class FloorPlanPdfRenderer
{
    public function render(array $floorPlan): string
    {
        $lines = $this->buildTextLines($floorPlan);
        $contentStream = $this->buildContentStream($lines);

        $objects = [];
        $objects[1] = "<< /Type /Catalog /Pages 2 0 R >>";
        $objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";
        $objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>";
        $objects[4] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";
        $objects[5] = "<< /Length " . strlen($contentStream) . " >>\nstream\n" . $contentStream . "\nendstream";

        return $this->assemblePdf($objects);
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
