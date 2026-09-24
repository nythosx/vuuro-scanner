<?php

declare(strict_types=1);

namespace VuuroScan\Export;

use VuuroScan\RoomType;

final class FloorPlanPdfRenderer
{
    private const PAGE_TOP_Y = 740;
    private const PAGE_BOTTOM_MARGIN_Y = 50;
    private const LINE_HEIGHT = 16;
    private const PAGE_WIDTH = 612;
    private const PAGE_HEIGHT = 792;
    private const PAGE_MARGIN_X = 50;
    private const MAX_PAGES = 200;
    private const MAX_EMBEDDED_IMAGE_DIMENSION_PX = 1600;

    private const IMAGE_PAGE_MARGIN = 36;


    private const STYLE_FONTS = [
        'title' => ['F2', 17],
        'label' => ['F2', 12],
        'body' => ['F1', 10],
        'italic' => ['F3', 9],
        'section' => ['F2', 12],
        'room' => ['F2', 11],
        'sub' => ['F1', 10],
        'small' => ['F1', 9],
        'warning' => ['F2', 10],
        'captionBold' => ['F2', 11],
        'captionRegular' => ['F1', 10],
    ];

    private const INK = [39, 39, 41];
    private const INK_MUTED = [135, 135, 138];
    private const DANGER = [214, 69, 62];
    private const ACCENT = [255, 130, 18];
    private const BORDER = [236, 236, 238];


    private const STYLE_COLORS = [
        'body' => self::INK_MUTED,
        'italic' => self::INK_MUTED,
        'sub' => self::INK_MUTED,
        'small' => self::INK_MUTED,
        'warning' => self::DANGER,
        'captionRegular' => self::INK_MUTED,
    ];

    public function render(array $floorPlan, string $layout = 'auto', ?string $roomId = null, string $unit = UnitFormatter::METRIC, ?string $label = null, ?callable $photoLoader = null, FloorPlanStyle|string|null $style = null): string
    {
        $planStyle = $style instanceof FloorPlanStyle ? $style : FloorPlanStyle::from($style ?? 'default');
        if ($roomId !== null) {
            $rooms = array_values(array_filter($floorPlan['rooms'], static fn (array $room) => $room['room_id'] === $roomId));
            if ($rooms === []) {
                throw new \InvalidArgumentException("No room with room_id '{$roomId}' in this floor plan.");
            }
            $floorPlan = [...$floorPlan, 'rooms' => $rooms];
        }
        $lines = $this->buildTextLines($floorPlan, $layout, $unit, $label, $planStyle);
        $textPages = $this->paginate($lines);

        $imagePages = $this->buildImagePages($floorPlan, $layout, $roomId, $unit, $label, $photoLoader, $planStyle);

        if (count($textPages) + count($imagePages) > self::MAX_PAGES) {
            throw new \InvalidArgumentException(sprintf(
                'This floor plan would need %d PDF pages, exceeding the %d page sanity bound — refusing to render it.',
                count($textPages) + count($imagePages),
                self::MAX_PAGES
            ));
        }

        $objects = [];
        $objects[1] = null;
        $regularFontObjNum = 3;
        $boldFontObjNum = 4;
        $italicFontObjNum = 5;
        $objects[$regularFontObjNum] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";
        $objects[$boldFontObjNum] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>";
        $objects[$italicFontObjNum] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique >>";
        $fontResources = "/F1 {$regularFontObjNum} 0 R /F2 {$boldFontObjNum} 0 R /F3 {$italicFontObjNum} 0 R";

        $pageObjNums = [];
        $nextObjNum = $italicFontObjNum + 1;
        $totalPages = count($imagePages) + count($textPages);
        $footerLabel = "{$floorPlan['property_id']} - {$floorPlan['unit_id']}";
        $pageIndex = 0;

        foreach ($imagePages as $imagePage) {
            $pageIndex++;
            $imgObjNum = $nextObjNum++;
            $pageObjNum = $nextObjNum++;
            $contentObjNum = $nextObjNum++;
            $pageObjNums[] = $pageObjNum;

            $objects[$imgObjNum] = "<< /Type /XObject /Subtype /Image /Width {$imagePage['width']} /Height {$imagePage['height']} "
                . "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " . strlen($imagePage['jpeg']) . " >>\nstream\n"
                . $imagePage['jpeg'] . "\nendstream";

            $contentStream = $this->buildImagePageContentStream($imagePage, $imgObjNum)
                . "\n" . $this->buildPageChrome($imagePage['pageWidth'], $imagePage['pageHeight'], $footerLabel, $pageIndex, $totalPages);
            $objects[$pageObjNum] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {$imagePage['pageWidth']} {$imagePage['pageHeight']}] "
                . "/Resources << /Font << {$fontResources} >> /XObject << /Im{$imgObjNum} {$imgObjNum} 0 R >> >> /Contents {$contentObjNum} 0 R >>";
            $objects[$contentObjNum] = "<< /Length " . strlen($contentStream) . " >>\nstream\n" . $contentStream . "\nendstream";
        }

        foreach ($textPages as $pageLines) {
            $pageIndex++;
            $pageObjNum = $nextObjNum++;
            $contentObjNum = $nextObjNum++;
            $pageObjNums[] = $pageObjNum;

            $contentStream = $this->buildContentStream($pageLines)
                . "\n" . $this->buildPageChrome(self::PAGE_WIDTH, self::PAGE_HEIGHT, $footerLabel, $pageIndex, $totalPages);
            $objects[$pageObjNum] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " . self::PAGE_WIDTH . ' ' . self::PAGE_HEIGHT . '] '
                . "/Resources << /Font << {$fontResources} >> >> /Contents {$contentObjNum} 0 R >>";
            $objects[$contentObjNum] = "<< /Length " . strlen($contentStream) . " >>\nstream\n" . $contentStream . "\nendstream";
        }

        $kids = implode(' ', array_map(static fn (int $n) => "{$n} 0 R", $pageObjNums));
        $objects[1] = "<< /Type /Catalog /Pages 2 0 R >>";
        $objects[2] = "<< /Type /Pages /Kids [{$kids}] /Count " . count($pageObjNums) . ' >>';
        ksort($objects);

        return $this->assemblePdf($objects);
    }


    private function buildImagePages(array $floorPlan, string $layout, ?string $roomId, string $unit, ?string $label, ?callable $photoLoader, FloorPlanStyle|string|null $style = null): array
    {
        $pages = [];

        try {
            $floorPlanPng = (new FloorPlanImageRenderer())->render($floorPlan, $layout, $roomId, $unit, $label, $style);
            $normalized = $this->toEmbeddableJpeg($floorPlanPng);
            if ($normalized === null) {
                error_log(sprintf(
                    'FloorPlanPdfRenderer: floor plan drawing rendered but could not be re-encoded to JPEG for session %s — GD likely built without JPEG support (see Dockerfile). PDF will ship without the drawing page.',
                    $floorPlan['scan_session_id'] ?? 'unknown'
                ));
            } else {
                $pages[] = $this->layoutImagePage($normalized, [['text' => 'Floor plan drawing', 'style' => 'captionBold']]);
            }
        } catch (\Throwable) {
        }

        if ($photoLoader !== null) {
            foreach ($floorPlan['photos'] as $photo) {
                $bytes = $photoLoader($photo['url']);
                if ($bytes === null) {
                    continue;
                }
                $normalized = $this->toEmbeddableJpeg($bytes);
                if ($normalized === null) {
                    error_log(sprintf('FloorPlanPdfRenderer: photo %s loaded but could not be decoded/re-encoded (unsupported format for GD — e.g. HEIC), skipping embed.', $photo['photo_id'] ?? 'unknown'));
                    continue;
                }
                $roomLabel = $this->roomLabelFor($floorPlan, $photo['room_id'] ?? null);
                $caption = [];
                if ($roomLabel !== null) {
                    $caption[] = ['text' => $roomLabel, 'style' => 'captionBold'];
                }
                if ($photo['caption'] !== '') {
                    $caption[] = ['text' => $photo['caption'], 'style' => 'captionRegular'];
                }
                $pages[] = $this->layoutImagePage($normalized, $caption);
            }
        }

        return $pages;
    }


    private function layoutImagePage(array $normalized, array $caption): array
    {
        $captionHeight = count($caption) * self::LINE_HEIGHT;
        $captionGap = $caption !== [] ? 10 : 0;

        $pageWidth = self::PAGE_WIDTH;
        $pageHeight = self::PAGE_HEIGHT;
        $maxDrawWidth = $pageWidth - 2 * self::IMAGE_PAGE_MARGIN;
        $maxDrawHeight = $pageHeight - 2 * self::IMAGE_PAGE_MARGIN - $captionHeight - $captionGap;

        $aspect = $normalized['width'] / max($normalized['height'], 1);
        $drawWidth = $maxDrawWidth;
        $drawHeight = $drawWidth / $aspect;
        if ($drawHeight > $maxDrawHeight) {
            $drawHeight = $maxDrawHeight;
            $drawWidth = $drawHeight * $aspect;
        }

        return [
            ...$normalized,
            'caption' => $caption,
            'drawWidth' => $drawWidth,
            'drawHeight' => $drawHeight,
            'pageWidth' => $pageWidth,
            'pageHeight' => $pageHeight,
        ];
    }


    private function toEmbeddableJpeg(string $imageBytes): ?array
    {
        $image = @imagecreatefromstring($imageBytes);
        if ($image === false) {
            return null;
        }
        $width = imagesx($image);
        $height = imagesy($image);
        if ($width < 1 || $height < 1) {
            imagedestroy($image);
            return null;
        }

        $longestEdge = max($width, $height);
        if ($longestEdge > self::MAX_EMBEDDED_IMAGE_DIMENSION_PX) {
            $scale = self::MAX_EMBEDDED_IMAGE_DIMENSION_PX / $longestEdge;
            $scaledWidth = max(1, (int) round($width * $scale));
            $scaledHeight = max(1, (int) round($height * $scale));
            $scaledImage = imagecreatetruecolor($scaledWidth, $scaledHeight);
            imagecopyresampled($scaledImage, $image, 0, 0, 0, 0, $scaledWidth, $scaledHeight, $width, $height);
            imagedestroy($image);
            $image = $scaledImage;
            $width = $scaledWidth;
            $height = $scaledHeight;
        }

        ob_start();
        imagejpeg($image, null, 85);
        $jpeg = (string) ob_get_clean();
        imagedestroy($image);
        return $jpeg === '' ? null : ['jpeg' => $jpeg, 'width' => $width, 'height' => $height];
    }

    private const PURPOSE_LABELS = [
        'listing' => 'Listing',
        'check_in' => 'Move-in inspection',
        'check_out' => 'Move-out inspection',
        'renovation' => 'Renovation',
        'other' => 'Other',
    ];

    private static function purposeLabel(string $purpose): string
    {
        return self::PURPOSE_LABELS[$purpose] ?? ucfirst(str_replace('_', ' ', $purpose));
    }

    private static function formatCapturedDate(string $capturedAt): string
    {
        $date = date_create($capturedAt);
        return $date !== false ? $date->format('M j, Y') : $capturedAt;
    }

    private function buildPageChrome(float $pageWidth, float $pageHeight, string $footerLabel, int $pageIndex, int $totalPages): string
    {
        $accentBarHeight = 4;
        $stream = "q\n" . $this->rgOp(self::ACCENT) . "\n0 " . ($pageHeight - $accentBarHeight) . " {$pageWidth} {$accentBarHeight} re\nf\nQ\n";

        $footerText = "{$footerLabel}  -  Page {$pageIndex} of {$totalPages}";
        $ascii = preg_replace('/[^\x20-\x7E]/', '-', $footerText) ?? $footerText;
        $escaped = str_replace(['\\', '(', ')'], ['\\\\', '\\(', '\\)'], $ascii);
        $stream .= "q\n" . $this->rgOp(self::INK_MUTED) . "\nBT\n/F1 8 Tf\n1 0 0 1 24 16 Tm\n({$escaped}) Tj\nET\nQ\n";

        return rtrim($stream);
    }

    private function roomLabelFor(array $floorPlan, ?string $roomId): ?string
    {
        if ($roomId === null) {
            return 'Whole unit';
        }
        foreach ($floorPlan['rooms'] as $room) {
            if ($room['room_id'] === $roomId) {
                return $room['label'];
            }
        }
        return null;
    }

    private function buildImagePageContentStream(array $imagePage, int $imgObjNum): string
    {
        $captionHeight = count($imagePage['caption']) * self::LINE_HEIGHT;
        $captionGap = $imagePage['caption'] !== [] ? 10 : 0;
        $drawWidth = $imagePage['drawWidth'];
        $drawHeight = $imagePage['drawHeight'];

        $x = self::IMAGE_PAGE_MARGIN;
        $y = self::IMAGE_PAGE_MARGIN + $captionHeight + $captionGap;

        $stream = "q\n{$drawWidth} 0 0 {$drawHeight} {$x} {$y} cm\n/Im{$imgObjNum} Do\nQ\n";

        $capY = self::IMAGE_PAGE_MARGIN + $captionHeight;
        foreach ($imagePage['caption'] as $line) {
            [$font, $size] = self::STYLE_FONTS[$line['style']];
            $color = self::STYLE_COLORS[$line['style']] ?? self::INK;
            $ascii = preg_replace('/[^\x20-\x7E]/', '-', $line['text']) ?? $line['text'];
            $escaped = str_replace(['\\', '(', ')'], ['\\\\', '\\(', '\\)'], $ascii);
            $stream .= 'q' . "\n" . $this->rgOp($color) . "\nBT\n/{$font} {$size} Tf\n1 0 0 1 " . self::IMAGE_PAGE_MARGIN . " {$capY} Tm\n({$escaped}) Tj\nET\nQ\n";
            $capY -= self::LINE_HEIGHT;
        }

        return rtrim($stream);
    }


    private function paginate(array $lines): array
    {
        $maxLinesPerPage = intdiv(self::PAGE_TOP_Y - self::PAGE_BOTTOM_MARGIN_Y, self::LINE_HEIGHT) + 1;
        $pages = array_chunk($lines, max($maxLinesPerPage, 1));
        return $pages === [] ? [[]] : $pages;
    }


    private function buildTextLines(array $floorPlan, string $layout = 'auto', string $unit = UnitFormatter::METRIC, ?string $label = null, ?FloorPlanStyle $planStyle = null): array
    {
        $planStyle ??= FloorPlanStyle::from('default');
        $lines = [];
        $add = static function (string $text, string $style = 'body', array $extra = []) use (&$lines): void {
            $lines[] = [...['text' => $text, 'style' => $style], ...$extra];
        };

        $add('Vuuro Scan - Floor Plan Metrics', 'title');
        if ($label !== null && $label !== '') {
            $add($label, 'label');
        }
        $add('');
        $add(sprintf('Property: %s   Unit: %s   Organisation: %s', $floorPlan['property_id'], $floorPlan['unit_id'], $floorPlan['organisation_id']));
        $add(sprintf('Purpose: %s   Captured: %s', self::purposeLabel($floorPlan['purpose']), self::formatCapturedDate($floorPlan['captured_at'])));
        $add('');
        $add(
            $floorPlan['measurement_basis'] === 'indicative_nen2580_inspired'
                ? 'Indicative, NEN2580-inspired measurements. This is NOT a certified survey.'
                : 'Measurement basis: ' . $floorPlan['measurement_basis'],
            'italic'
        );
        $add('');
        $isFused = $layout !== 'tiles' && count($floorPlan['rooms']) > 1 && array_reduce(
            $floorPlan['rooms'],
            fn (bool $carry, array $room) => $carry && isset($room['structure_origin_m']),
            true
        );
        if ($isFused && FusionOverlapDetector::detect($floorPlan['rooms']) !== []) {
            $add('WARNING: some rooms below overlap in captured position - verify against the real layout before use.', 'warning');
            $add('');
        }
        $add('Rooms', 'section');
        $totalArea = 0.0;
        foreach ($floorPlan['rooms'] as $room) {
            $totalArea += $room['floor_area_m2'];
            $roomType = $room['room_type'] ?? null;
            $roomTypeValue = $roomType !== null ? ($roomType['confirmed'] ?? $roomType['guess'] ?? null) : null;
            $roomLabel = RoomType::displayLabelForRoom($room);
            $bulletHex = FloorPlanPalette::roomAccentFor($roomTypeValue) ?? '#9a958a';
            $add(
                sprintf(
                    '%-20s %12s   %14s   confidence: %s',
                    $roomLabel,
                    UnitFormatter::area($room['floor_area_m2'], $unit),
                    UnitFormatter::length($room['perimeter_m'], $unit) . ' perimeter',
                    $room['confidence']
                ),
                'room',
                ['bullet' => FloorPlanPalette::hexToRgb($bulletHex)]
            );
            if ($planStyle->showMetrics) {
            $heightM = $room['height_m'] ?? null;
            $volumeM3 = $room['volume_m3_indicative'] ?? null;
            if ($heightM !== null && $volumeM3 !== null) {
                $add(sprintf('             %s height   %s indicative capacity', UnitFormatter::length($heightM, $unit), UnitFormatter::volume($volumeM3, $unit)), 'sub');
            } elseif ($heightM !== null) {
                $add(sprintf('             %s height', UnitFormatter::length($heightM, $unit)), 'sub');
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
                $add("             {$summary}", 'sub');
            }
            $walkPath = $room['walk_path_m'] ?? [];
            if (count($walkPath) >= 2) {
                $add(sprintf('             walk path: %d point(s) recorded', count($walkPath)), 'sub');
            }
            $objects = $room['objects'] ?? [];
            if ($objects !== []) {
                $objectCounts = [];
                foreach ($objects as $object) {
                    $objectCounts[$object['category']] = ($objectCounts[$object['category']] ?? 0) + 1;
                }
                $objectSummary = implode(', ', array_map(
                    static fn (string $category, int $count) => "{$count} {$category}",
                    array_keys($objectCounts),
                    array_values($objectCounts)
                ));
                $add("             detected objects: {$objectSummary}", 'sub');
                }
            }
            if ($planStyle->showNotes) {
                $roomNotes = array_values(array_filter(
                    $floorPlan['notes'],
                    static fn (array $note) => ($note['room_id'] ?? null) === $room['room_id']
                ));
                foreach ($roomNotes as $note) {
                    $tags = is_array($note['tags'] ?? null) ? $note['tags'] : [];
                    $prefix = in_array('missing_item', $tags, true) ? 'missing item: ' : 'note: ';
                    foreach ($this->wrapTextLines($note['text'], 85) as $i => $wrapped) {
                        $add($i === 0 ? "             {$prefix}{$wrapped}" : "                   {$wrapped}", 'sub');
                    }
                }
            }
        }
        $add('');
        $add(sprintf('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalArea, $unit), count($floorPlan['rooms'])), 'small');

        if ($planStyle->showNotes) {
            $unitNotes = array_values(array_filter(
                $floorPlan['notes'],
                static fn (array $note) => ($note['room_id'] ?? null) === null
            ));
            if ($unitNotes !== []) {
            $add('');
            $add('Whole-unit notes', 'section');
            foreach ($unitNotes as $note) {
                foreach ($this->wrapTextLines($note['text'], 90) as $i => $wrapped) {
                    $add($i === 0 ? "- {$wrapped}" : "  {$wrapped}", 'sub');
                }
            }
        }

        if ($floorPlan['photos'] !== [] || $floorPlan['notes'] !== []) {
            $add('');
            $add(sprintf('Photos attached: %d   Notes attached: %d', count($floorPlan['photos']), count($floorPlan['notes'])), 'small');
            }
        }

        return $lines;
    }


    private function wrapTextLines(string $text, int $maxChars): array
    {
        $wrapped = wordwrap($text, $maxChars, "\n", true);
        return $wrapped === '' ? [''] : explode("\n", $wrapped);
    }

    private function rgOp(array $rgb): string
    {
        return sprintf('%.3f %.3f %.3f rg', $rgb[0] / 255, $rgb[1] / 255, $rgb[2] / 255);
    }


    private function buildContentStream(array $lines): string
    {
        $stream = '';
        $y = self::PAGE_TOP_Y;
        foreach ($lines as $line) {
            if ($line['style'] === 'warning') {
                $stream .= "q\n" . $this->rgOp([250, 214, 212]) . "\n0 " . ($y - 4) . ' ' . self::PAGE_WIDTH . ' ' . self::LINE_HEIGHT . " re\nf\nQ\n";
            }
            if ($line['style'] === 'section') {
                $stream .= "q\n" . $this->rgOp(self::ACCENT) . "\n" . self::PAGE_MARGIN_X . ' ' . ($y - 4) . ' 24 2 re' . "\nf\nQ\n";
            }
            if (isset($line['bullet'])) {
                $stream .= "q\n" . $this->rgOp($line['bullet']) . "\n" . (self::PAGE_MARGIN_X - 14) . ' ' . ($y - 1) . " 8 8 re\nf\n"
                    . $this->rgOp(self::BORDER) . "\n1 w\n" . (self::PAGE_MARGIN_X - 14) . ' ' . ($y - 1) . " 8 8 re\nS\nQ\n";
            }
            if ($line['text'] !== '') {
                [$font, $size] = self::STYLE_FONTS[$line['style']];
                $color = self::STYLE_COLORS[$line['style']] ?? self::INK;




                $ascii = preg_replace('/[^\x20-\x7E]/', '-', $line['text']) ?? $line['text'];
                $escaped = str_replace(['\\', '(', ')'], ['\\\\', '\\(', '\\)'], $ascii);
                $stream .= 'q' . "\n" . $this->rgOp($color) . "\nBT\n/{$font} {$size} Tf\n1 0 0 1 " . self::PAGE_MARGIN_X . " {$y} Tm\n({$escaped}) Tj\nET\nQ\n";
            }
            $y -= self::LINE_HEIGHT;
        }
        return rtrim($stream);
    }


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
