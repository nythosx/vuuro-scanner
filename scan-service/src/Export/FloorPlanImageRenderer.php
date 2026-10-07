<?php

declare(strict_types=1);

namespace VuuroScan\Export;

use VuuroScan\RoomType;

final class FloorPlanImageRenderer
{
    private const WALL_GAP_MERGE_M = 0.35;
    private const TILE_BREAKPOINT_MERGE_M = 0.15;
    private const SEAM_OVERLAP_M = 0.015;
    private const MAX_OPENING_WALL_DISTANCE_M = 0.6;
    private const PIXELS_PER_METER = 60;
    private const TILE_PADDING = 34;
    private const LABEL_HEIGHT = 80;
    private const TILE_GAP = 32;
    private const MARGIN = 24;
    private const DIMENSION_GUTTER = 28;
    private const MAX_CANVAS_DIMENSION_PX = 4000;
    private const MAX_GROUPED_CANVAS_HEIGHT_PX = 12000;
    private const GROUP_HEADING_HEIGHT_PX = 40;
    private const ROOM_PALETTE = [
        [255, 229, 208],
        [230, 244, 200],
        [225, 245, 255],
        [240, 231, 247],
        [224, 244, 240],
    ];
    private const WALL_COLOR = [0, 0, 0];
    private const DEFAULT_LINE_THICKNESS_PX = 1;
    private const FONT_SMALL = 1;
    private const NOTE_LINE_HEIGHT = 15;
    private const DOOR_LEAF_M = 0.8;
    private const WINDOW_WIDTH_M = 1.0;
    private const OPENING_WIDTH_M = 0.7;
    private const FOOTER_TEXT = 'Indicative measurements - NEN2580-inspired, not certified. No rights can be derived from this plan.';
    private const WALL_LABEL_INSET_M = 0.35;
    private const TTF_SIZE = [1 => 9.0, 2 => 10.0, 3 => 12.0, 4 => 14.0, 5 => 17.0];

    private function fontPath(): string
    {
        return __DIR__ . '/../../assets/fonts/OpenSans-Variable.ttf';
    }

    private function assertFontAvailable(): void
    {
        $path = $this->fontPath();
        if (!is_file($path) || !is_readable($path)) {
            error_log("VuuroScan: bundled font file missing or unreadable at {$path} — floor plan rendering is unavailable on this server.");
            throw new \RuntimeException('Floor plan rendering is unavailable on this server.');
        }
    }

    private function drawText($image, int $sizeKey, int $x, int $y, string $text, int $color): void
    {
        $size = self::TTF_SIZE[$sizeKey];
        imagettftext($image, $size, 0, $x, $y + (int) round($size * 0.85), $color, $this->fontPath(), $text);
    }

    private function drawTextUp($image, int $sizeKey, int $x, int $y, string $text, int $color): void
    {
        $size = self::TTF_SIZE[$sizeKey];
        imagettftext($image, $size, 90, $x + (int) round($size * 0.85), $y, $color, $this->fontPath(), $text);
    }

    private function textWidth(int $sizeKey, string $text): int
    {
        $box = imagettfbbox(self::TTF_SIZE[$sizeKey], 0, $this->fontPath(), $text);
        return (int) ($box[2] - $box[0]);
    }

    private static function roomTypeValue(array $room): ?string
    {
        $roomType = $room['room_type'] ?? null;
        if ($roomType === null) {
            return null;
        }
        return $roomType['confirmed'] ?? $roomType['guess'] ?? null;
    }

    private function edgeThicknessM(array $roomEdgeTiers, int $edgeIndex): float
    {
        return FloorPlanPalette::wallThicknessM($this->planStyle->isFunda, isset($roomEdgeTiers[$edgeIndex]));
    }

    private function roomWallPointSets(array $outlineM, array $pose, callable $toPx, array $roomEdgeTiers): array
    {
        $n = count($outlineM);
        $sets = [];
        $twiceArea = 0.0;
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $twiceArea += $ax * $bz - $bx * $az;
        }
        $inward = $twiceArea >= 0 ? 1.0 : -1.0;
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $dx = $bx - $ax;
            $dz = $bz - $az;
            $len = sqrt($dx ** 2 + $dz ** 2);
            if ($len < 1e-6 || FloorPlanPalette::isOpenEdge($roomEdgeTiers, $i)) {
                continue;
            }
            $ux = $dx / $len;
            $uz = $dz / $len;
            $nx = -$uz * $inward;
            $nz = $ux * $inward;
            $half = $this->edgeThicknessM($roomEdgeTiers, $i) / 2;
            $seamGap = $roomEdgeTiers[$i] ?? null;
            $outer = is_float($seamGap) ? max($half, $seamGap / 2 + self::SEAM_OVERLAP_M) : $half;

            $eax = $ax - $ux * $half;
            $eaz = $az - $uz * $half;
            $ebx = $bx + $ux * $half;
            $ebz = $bz + $uz * $half;
            $corners = [
                [$eax - $nx * $outer, $eaz - $nz * $outer],
                [$ebx - $nx * $outer, $ebz - $nz * $outer],
                [$ebx + $nx * $half, $ebz + $nz * $half],
                [$eax + $nx * $half, $eaz + $nz * $half],
            ];
            $points = [];
            foreach ($corners as [$cx, $cz]) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $cx, $cz);
                [$px, $py] = $toPx($wx, $wz);
                $points[] = $px;
                $points[] = $py;
            }
            $sets[] = $points;
        }
        return $sets;
    }

    private function drawRoomWalls($image, array $outlineM, array $pose, callable $toPx, array $roomEdgeTiers, int $wallColor): void
    {
        foreach ($this->roomWallPointSets($outlineM, $pose, $toPx, $roomEdgeTiers) as $points) {
            imagefilledpolygon($image, $points, $wallColor);
            imagepolygon($image, $points, $wallColor);
        }
        $n = count($outlineM);
        $openColor = null;
        for ($i = 0; $i < $n; $i++) {
            if (!FloorPlanPalette::isOpenEdge($roomEdgeTiers, $i)) {
                continue;
            }
            $openColor ??= imagecolorallocate($image, 138, 138, 138);
            [$awx, $awz] = RoomFusionSolver::transformPoint($pose, (float) $outlineM[$i][0], (float) $outlineM[$i][1]);
            [$bwx, $bwz] = RoomFusionSolver::transformPoint($pose, (float) $outlineM[($i + 1) % $n][0], (float) $outlineM[($i + 1) % $n][1]);
            [$apx, $apy] = $toPx($awx, $awz);
            [$bpx, $bpy] = $toPx($bwx, $bwz);
            $this->drawDashedSegment($image, (int) round($apx), (int) round($apy), (int) round($bpx), (int) round($bpy), $openColor);
        }
    }

    private function drawRoomWallShadow($image, array $outlineM, array $pose, callable $toPx, array $roomEdgeTiers): void
    {
        $pointSets = $this->roomWallPointSets($outlineM, $pose, $toPx, $roomEdgeTiers);
        if ($pointSets === []) {
            return;
        }
        $shadowDx = 1;
        $shadowDy = 2;
        imagealphablending($image, true);
        $shadowColor = imagecolorallocatealpha($image, 0, 0, 0, 100);
        foreach ($pointSets as $points) {
            $shifted = [];
            for ($k = 0; $k < count($points); $k += 2) {
                $shifted[] = $points[$k] + $shadowDx;
                $shifted[] = $points[$k + 1] + $shadowDy;
            }
            imagefilledpolygon($image, $shifted, $shadowColor);
        }
    }

    private function roomTypeFillColor($image, array $room)
    {
        if ($this->planStyle->isFunda) {
            $type = self::roomTypeValue($room);
            return imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::fundaFillFor(is_string($type) ? $type : null, (string) ($room['room_id'] ?? ''))));
        }
        if ($this->planStyle->roomFill === 'white') {
            return imagecolorallocate($image, 255, 255, 255);
        }
        $hex = FloorPlanPalette::roomFillFor(self::roomTypeValue($room));
        return $hex !== null ? imagecolorallocate($image, ...FloorPlanPalette::hexToRgb($hex)) : null;
    }

    private FloorPlanStyle $planStyle;
    private ?string $resolvedTitle = null;
    private ?string $fundaFloorName = null;
    private string $fundaPlaceLine = '';
    private float $fundaTotalAreaM2 = 0.0;
    private string $fundaUnit = UnitFormatter::METRIC;

    public function __construct()
    {
        $this->planStyle = FloorPlanStyle::from('default');
    }

    public function render(array $floorPlan, string $layout = 'auto', ?string $roomId = null, string $unit = UnitFormatter::METRIC, ?string $label = null, FloorPlanStyle|string|null $style = null): string
    {
        $this->assertFontAvailable();
        $this->planStyle = $style instanceof FloorPlanStyle ? $style : FloorPlanStyle::from($style ?? 'default');
        $this->resolvedTitle = $this->planStyle->resolvedTitle($floorPlan);
        $this->fundaFloorName = $this->singleFloorName($floorPlan['rooms'] ?? []);
        $this->fundaPlaceLine = implode(" \u{00B7} ", array_values(array_filter([
            trim((string) ($floorPlan['property_id'] ?? '')),
            trim((string) ($floorPlan['unit_id'] ?? '')),
        ], static fn (string $part): bool => $part !== '')));
        $rooms = $floorPlan['rooms'];
        $notes = $floorPlan['notes'] ?? [];
        if ($roomId !== null) {
            $rooms = array_values(array_filter($rooms, static fn (array $room) => $room['room_id'] === $roomId));
            if ($rooms === []) {
                throw new \InvalidArgumentException("No room with room_id '{$roomId}' in this floor plan.");
            }
        }
        if ($rooms === []) {
            throw new \InvalidArgumentException('Cannot render a floor plan sheet with zero rooms.');
        }
        foreach ($rooms as $room) {
            if (!isset($room['outline_m'], $room['bounding_dimensions_m']['width_m'], $room['bounding_dimensions_m']['length_m'])) {
                throw new \InvalidArgumentException("Cannot render a floor plan sheet: room '{$room['label']}' is missing outline_m/bounding_dimensions_m.");
            }
        }

        if ($layout !== 'tiles' && $roomId === null) {
            $groups = FloorGroups::split($rooms);
            if (count($groups) > 1) {
                return $this->renderGroups($floorPlan, $groups, $layout, $unit, $label, $style);
            }
        }

        $isFused = $layout !== 'tiles' && $roomId === null && count($rooms) > 1 && array_reduce(
            $rooms,
            fn (bool $carry, array $room) => $carry && isset($room['structure_origin_m']),
            true
        );
        if ($isFused) {
            return $this->renderFused($rooms, $unit, $label, $notes);
        }

        $tiles = array_map(fn (array $room) => $this->tileGeometry($room, $this->planStyle->orientation), $rooms);
        $notesLines = $this->planStyle->showNotes ? $this->buildNotesLines($rooms, $notes) : [];

        $tilesWidth = self::MARGIN * 2 + array_sum(array_column($tiles, 'width'))
            + self::TILE_GAP * (count($tiles) - 1) + 40;
        $totalAreaM2 = array_sum(array_column($rooms, 'floor_area_m2'));
        $headerTextWidth = self::MARGIN * 2 + $this->textWidth(5, ExportLanguage::t('Vuuro Scan - indicative per-room floor plan sheet'));
        $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(2, ExportLanguage::t('Room shapes accurate individually; rooms are not laid out relative to each other.')));
        if ($label !== null && $label !== '') {
            $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(2, $label));
        }
        $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(2, ExportLanguage::t('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms))));
        foreach ($notesLines as $line) {
            $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(1, $line));
        }
        $canvasWidth = max($tilesWidth, $headerTextWidth);
        $canvasHeight = self::MARGIN * 2 + self::LABEL_HEIGHT + (int) max(array_column($tiles, 'height'))
            + count($notesLines) * self::NOTE_LINE_HEIGHT
            + 30;

        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Floor plan sheet would be %dx%d px, exceeding the %d px sanity bound — refusing to allocate it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $image = imagecreatetruecolor(max($canvasWidth, 400), $canvasHeight + 72);

        imageantialias($image, true);
        $surface = $this->planStyle->isFunda ? imagecolorallocate($image, 255, 255, 255) : imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_SURFACE));
        $defaultFill = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::ROOM_BUCKET_FILL['neutral']));
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        $text = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK));
        $subtext = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK_MUTED));
        $doorColor = imagecolorallocate($image, ...$this->planStyle->doorColor);
        $windowColor = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_ACCENT_CYAN));
        $otherOpeningColor = imagecolorallocate($image, 140, 140, 142);
        $walkPathColor = imagecolorallocate($image, 150, 60, 190);
        $objectColor = imagecolorallocate($image, 96, 96, 96);
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $surface);
        if ($this->planStyle->isFunda) {
            $this->drawFundaGrid($image);
        }

        if ($this->planStyle->isFunda) {
            $this->fundaTotalAreaM2 = $totalAreaM2;
            $this->fundaUnit = $unit;
        } else {
            $this->drawText($image, 5, self::MARGIN, 12, ExportLanguage::t('Vuuro Scan - indicative per-room floor plan sheet'), $text);
            $this->drawText($image, 2, self::MARGIN, 32, ExportLanguage::t('Room shapes accurate individually; rooms are not laid out relative to each other.'), $subtext);
            if ($label !== null && $label !== '') {
                $this->drawText($image, 2, self::MARGIN, 46, $label, $subtext);
            }
            $this->drawText($image, 2, self::MARGIN, 60, ExportLanguage::t('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms)), $subtext);
        }

        $tilesContentWidth = array_sum(array_column($tiles, 'width')) + self::TILE_GAP * (count($tiles) - 1);
        $x = max(self::MARGIN, (int) round((imagesx($image) - $tilesContentWidth) / 2));
        $y = self::MARGIN + self::LABEL_HEIGHT;
        foreach ($rooms as $i => $room) {
            $tile = $tiles[$i];
            $roomFill = $this->roomTypeFillColor($image, $room) ?? $defaultFill;
            $this->drawRoomTile($image, $room, $x, $y, $roomFill, $wallColor, $text, $subtext, $doorColor, $windowColor, $otherOpeningColor, $walkPathColor, $objectColor, $unit);
            $x += $tile['width'] + self::TILE_GAP;
        }

        $tilesBottomY = self::MARGIN + self::LABEL_HEIGHT + (int) max(array_column($tiles, 'height'));
        if ($this->planStyle->showNotes) {
            $this->drawNotes($image, $notesLines, $tilesBottomY + 10, $text);
        }
        $this->drawRoomTypeLegend($image, $rooms, imagesy($image) - 28, $text);
        $this->drawTitleBlock($image, $text);
        $this->drawFooter($image, $subtext);

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    private function buildNotesLines(array $rooms, array $notes): array
    {
        if ($notes === []) {
            return [];
        }
        $byRoom = [];
        $unitNotes = [];
        foreach ($notes as $note) {
            $roomId = $note['room_id'] ?? null;
            if ($roomId === null) {
                $unitNotes[] = $note;
            } else {
                $byRoom[$roomId][] = $note;
            }
        }

        $lines = [ExportLanguage::t('Notes:')];
        foreach ($rooms as $room) {
            foreach ($byRoom[$room['room_id']] ?? [] as $note) {
                foreach (TextWrap::lines($note['text'], 95) as $i => $wrapped) {
                    $wrapped = $this->printable($wrapped);
                    $lines[] = $i === 0 ? '  [' . $this->printable(RoomType::localizedLabel((string) $room['label'])) . "] {$wrapped}" : '        ' . $wrapped;
                }
                $tags = is_array($note['tags'] ?? null) ? $note['tags'] : [];
                if ($tags !== []) {
                    $labels = array_map(
                        static fn (string $tagValue) => \VuuroScan\InspectionTag::labelFor($tagValue),
                        $tags
                    );
                    $lines[] = '        ' . ExportLanguage::t('tags:') . ' ' . $this->printable(implode(', ', $labels));
                }
            }
        }
        foreach ($unitNotes as $note) {
            foreach (TextWrap::lines($note['text'], 95) as $i => $wrapped) {
                $wrapped = $this->printable($wrapped);
                $lines[] = $i === 0 ? '  [' . ExportLanguage::t('Whole unit') . "] {$wrapped}" : '        ' . $wrapped;
            }
            $tags = is_array($note['tags'] ?? null) ? $note['tags'] : [];
            if ($tags !== []) {
                $labels = array_map(
                    static fn (string $tagValue) => \VuuroScan\InspectionTag::labelFor($tagValue),
                    $tags
                );
                $lines[] = '        ' . ExportLanguage::t('tags:') . ' ' . $this->printable(implode(', ', $labels));
            }
        }
        return count($lines) > 1 ? $lines : [];
    }

    private function centroidM(array $outlineM): array
    {
        $n = count($outlineM);
        if ($n === 0) {
            return [0.0, 0.0];
        }
        return [array_sum(array_column($outlineM, 0)) / $n, array_sum(array_column($outlineM, 1)) / $n];
    }

    private function roomSummaryLines(array $rooms, string $unit): array
    {
        $lines = [ExportLanguage::t('Room summary:')];
        foreach ($rooms as $room) {
            $parts = [ExportLanguage::t('%s floor area', UnitFormatter::area($room['floor_area_m2'], $unit))];
            $parts[] = ExportLanguage::t('%s perimeter', UnitFormatter::length($room['perimeter_m'], $unit));
            if (($room['height_m'] ?? null) !== null) {
                $parts[] = ExportLanguage::t('%s height', UnitFormatter::length($room['height_m'], $unit));
            }
            if (($room['volume_m3_indicative'] ?? null) !== null) {
                $parts[] = ExportLanguage::t('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit));
            }
            $parts[] = ExportLanguage::t('%s confidence', ExportLanguage::t((string) $room['confidence']));
            $lines[] = '  [' . $this->printable($this->displayLabel($room)) . '] ' . implode(' - ', $parts);
        }
        return $lines;
    }

    private function drawNotes($image, array $lines, int $y, int $color): void
    {
        foreach ($lines as $line) {
            $this->drawText($image, self::FONT_SMALL, self::MARGIN, $y, $line, $color);
            $y += self::NOTE_LINE_HEIGHT;
        }
    }

    private static array $glyphCache = [];

    private function printable(string $s): string
    {
        $s = preg_replace('/[\x{10000}-\x{10FFFF}\x{FE00}-\x{FE0F}\p{Cc}\p{Cf}]/u', '', mb_scrub($s, 'UTF-8')) ?? '';
        $s = preg_replace_callback('/[^\x20-\x7E\p{M}]/u', fn (array $m): string => $this->drawableChar($m[0]), $s) ?? '';
        return preg_replace('/ {2,}/', ' ', $s) ?? $s;
    }

    private function drawableChar(string $char): string
    {
        if (!array_key_exists($char, self::$glyphCache)) {
            $hasGlyph = FontCoverage::has($this->fontPath(), mb_ord($char, 'UTF-8'));
            self::$glyphCache[$char] = $hasGlyph ? $char : (preg_match('/\p{So}/u', $char) === 1 ? '' : '?');
        }
        return self::$glyphCache[$char];
    }

    private function fundaArea(float $m2, string $unit): string
    {
        return $unit === UnitFormatter::IMPERIAL
            ? ExportLanguage::number($m2 * 10.7639104167, 0) . ' sq ft'
            : ExportLanguage::number($m2, 1) . " m\u{00B2}";
    }

    private function singleFloorName(array $rooms): ?string
    {
        $floors = [];
        foreach ($rooms as $room) {
            $floor = $room['floor'] ?? null;
            if (is_string($floor) && trim($floor) !== '') {
                $floors[trim($floor)] = true;
            }
        }
        return count($floors) === 1 ? (string) array_key_first($floors) : null;
    }

    private function drawBoldText($image, int $sizeKey, int $x, int $y, string $text, int $color): void
    {
        $this->drawText($image, $sizeKey, $x, $y, $text, $color);
        $this->drawText($image, $sizeKey, $x + 1, $y, $text, $color);
    }

    private function drawFundaGrid($image): void
    {
        $gridColor = imagecolorallocate($image, 236, 236, 236);
        for ($x = 0; $x < imagesx($image); $x += 20) {
            imageline($image, $x, 0, $x, imagesy($image), $gridColor);
        }
        for ($y = 0; $y < imagesy($image); $y += 20) {
            imageline($image, 0, $y, imagesx($image), $y, $gridColor);
        }
    }

    private function drawFundaTitleBlock($image, int $color): void
    {
        $heading = $this->printable($this->fundaFloorName ?? $this->resolvedTitle ?? ExportLanguage::t('Floor plan'));
        $this->drawBoldText($image, 5, (int) ((imagesx($image) - $this->textWidth(5, $heading)) / 2), imagesy($image) - 66, $heading, $color);
        $parts = [];
        if ($this->fundaFloorName !== null) {
            $explicitTitle = trim((string) $this->planStyle->titleLine);
            $placeLine = $explicitTitle !== '' ? $explicitTitle : $this->fundaPlaceLine;
            if ($placeLine !== '') {
                $parts[] = $this->printable($placeLine);
            }
        }
        $parts[] = ExportLanguage::t('Total floor area %s (indicative)', $this->fundaArea($this->fundaTotalAreaM2, $this->fundaUnit));
        $sub = implode("  \u{00B7}  ", $parts);
        $this->drawText($image, 2, (int) ((imagesx($image) - $this->textWidth(2, $sub)) / 2), imagesy($image) - 38, $sub, $color);
    }

    private function drawFundaRoomLabel($image, int $x, int $y, array $room, string $unit, int $text, int $subtext): void
    {
        $name = $this->printable(RoomType::planName($room));
        $sizeKey = ((float) ($room['floor_area_m2'] ?? 0)) < 4.0 ? 2 : 4;
        $this->drawBoldText($image, $sizeKey, $x - (int) ($this->textWidth($sizeKey, $name) / 2), $y - 9, $name, $text);
    }

    private function drawArrowHead($image, float $tipX, float $tipY, float $fromX, float $fromY, int $color): void
    {
        $dx = $tipX - $fromX;
        $dy = $tipY - $fromY;
        $len = sqrt($dx * $dx + $dy * $dy);
        if ($len < 1e-6) {
            return;
        }
        $ux = $dx / $len;
        $uy = $dy / $len;
        $baseX = $tipX - $ux * 7;
        $baseY = $tipY - $uy * 7;
        imagefilledpolygon($image, [
            (int) round($tipX), (int) round($tipY),
            (int) round($baseX - $uy * 3.5), (int) round($baseY + $ux * 3.5),
            (int) round($baseX + $uy * 3.5), (int) round($baseY - $ux * 3.5),
        ], $color);
    }

    private function drawDimensionSegment($image, int $x1, int $y1, int $x2, int $y2, int $color): void
    {
        imageline($image, $x1, $y1, $x2, $y2, $color);
        if ($this->planStyle->isFunda) {
            $this->drawArrowHead($image, $x1, $y1, $x2, $y2, $color);
            $this->drawArrowHead($image, $x2, $y2, $x1, $y1, $color);
            return;
        }
        if ($y1 === $y2) {
            imageline($image, $x1, $y1 - 4, $x1, $y1 + 4, $color);
            imageline($image, $x2, $y2 - 4, $x2, $y2 + 4, $color);
        } else {
            imageline($image, $x1 - 4, $y1, $x1 + 4, $y1, $color);
            imageline($image, $x2 - 4, $y2, $x2 + 4, $y2, $color);
        }
    }

    private function areaCentroidM(array $outlineM): array
    {
        $n = count($outlineM);
        $twiceArea = 0.0;
        $cx = 0.0;
        $cz = 0.0;
        for ($i = 0; $i < $n; $i++) {
            [$x0, $z0] = $outlineM[$i];
            [$x1, $z1] = $outlineM[($i + 1) % $n];
            $cross = $x0 * $z1 - $x1 * $z0;
            $twiceArea += $cross;
            $cx += ($x0 + $x1) * $cross;
            $cz += ($z0 + $z1) * $cross;
        }
        if (abs($twiceArea) < 1e-9) {
            return $this->centroidM($outlineM);
        }
        return [$cx / (3 * $twiceArea), $cz / (3 * $twiceArea)];
    }

    private function drawFooter($image, int $color): void
    {
        $footerWidth = $this->textWidth(self::FONT_SMALL, ExportLanguage::t(self::FOOTER_TEXT));
        $this->drawText($image, self::FONT_SMALL, (int) ((imagesx($image) - $footerWidth) / 2), imagesy($image) - 14, ExportLanguage::t(self::FOOTER_TEXT), $color);
    }

    private function drawTitleBlock($image, int $color): void
    {
        if ($this->planStyle->isFunda) {
            $this->drawFundaTitleBlock($image, $color);
            return;
        }
        $title = $this->resolvedTitle;
        if ($title === null || $title === '') {
            return;
        }
        $safe = $this->printable($title);
        $titleWidth = $this->textWidth(4, $safe);
        $x = (int) ((imagesx($image) - $titleWidth) / 2);
        $this->drawText($image, 4, $x, imagesy($image) - 44, $safe, $color);
    }

    private function renderGroups(array $floorPlan, array $groups, string $layout, string $unit, ?string $label, FloorPlanStyle|string|null $style): string
    {
        $headings = FloorGroups::headings($groups);
        $bandHeight = $this->planStyle->isFunda ? 0 : self::GROUP_HEADING_HEIGHT_PX;
        $blocks = [];
        $width = 0;
        $height = 0;
        foreach ($groups as $index => $group) {
            $png = (new self())->render([...$floorPlan, 'rooms' => $group['rooms']], $layout, null, $unit, $label, $style);
            $size = getimagesizefromstring($png);
            if ($size === false) {
                throw new \RuntimeException('Could not compose the per-floor plan images.');
            }
            $blocks[] = [$png, $headings[$index]];
            $width = max($width, (int) $size[0]);
            $height += (int) $size[1] + $bandHeight;
        }
        if ($height > self::MAX_GROUPED_CANVAS_HEIGHT_PX || $width * $height > self::MAX_CANVAS_DIMENSION_PX * self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'This floor plan would be %dx%dpx across %d floor sections, which is too large to draw as one image. Export one room at a time or use layout=tiles.',
                $width,
                $height,
                count($groups)
            ));
        }

        $image = imagecreatetruecolor($width, $height);

        imageantialias($image, true);
        $surface = $this->planStyle->isFunda ? imagecolorallocate($image, 255, 255, 255) : imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_SURFACE));
        $text = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK));
        $rule = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK_MUTED));
        imagefilledrectangle($image, 0, 0, $width, $height, $surface);

        $y = 0;
        foreach ($blocks as [$blockPng, $heading]) {
            $block = imagecreatefromstring($blockPng);
            if ($block === false) {
                imagedestroy($image);
                throw new \RuntimeException('Could not compose the per-floor plan images.');
            }
            if ($bandHeight > 0) {
                imageline($image, self::MARGIN, $y + 4, $width - self::MARGIN, $y + 4, $rule);
                $this->drawBoldText($image, 4, self::MARGIN, $y + 14, $this->printable($heading), $text);
                $y += $bandHeight;
            }
            imagecopy($image, $block, 0, $y, 0, 0, imagesx($block), imagesy($block));
            $y += imagesy($block);
            imagedestroy($block);
        }

        ob_start();
        imagepng($image);
        $png = (string) ob_get_clean();
        imagedestroy($image);
        return $png;
    }

    private function renderFused(array $rooms, string $unit = UnitFormatter::METRIC, ?string $label = null, array $notes = []): string
    {
        $minX = INF;
        $minZ = INF;
        $maxX = -INF;
        $maxZ = -INF;
        $fusion = RoomFusionSolver::solve($rooms);
        $overlapping = $fusion['overlapping'];
        $poses = $fusion['poses'];
        $oriented = FusionOrientation::apply($rooms, $poses, $this->planStyle->orientation);
        $poses = $oriented['poses'];
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                [$worldX, $worldZ] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
                $minX = min($minX, $worldX);
                $minZ = min($minZ, $worldZ);
                $maxX = max($maxX, $worldX);
                $maxZ = max($maxZ, $worldZ);
            }
        }
        $notesLines = $this->planStyle->showNotes ? $this->buildNotesLines($rooms, $notes) : [];
        $summaryLines = $this->planStyle->showMetrics ? $this->roomSummaryLines($rooms, $unit) : [];
        $totalAreaM2 = array_sum(array_column($rooms, 'floor_area_m2'));

        $extraHeaderLines = ($overlapping !== [] ? 1 : 0) + (($label !== null && $label !== '') ? 1 : 0) + 1;
        $headerHeight = self::LABEL_HEIGHT + $extraHeaderLines * 16;
        $dimensionLineY = self::MARGIN + $headerHeight;
        $topGutter = $headerHeight + self::DIMENSION_GUTTER;

        $headerTextWidth = self::MARGIN * 2 + $this->textWidth(5, ExportLanguage::t('Vuuro Scan - fused floor plan (rooms captured together in one visit)'));
        $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(2, ExportLanguage::t('Room positions relative to each other, not independently verified beyond this capture (see docs/proposals/multi-room-fusion.md).')));
        if ($overlapping !== []) {
            $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(3, ExportLanguage::t('WARNING: rooms below overlap in captured position - verify against the real layout before use.')));
        }
        if ($label !== null && $label !== '') {
            $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(2, $label));
        }
        $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(2, ExportLanguage::t('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms))));
        foreach ([...$notesLines, ...$summaryLines] as $line) {
            $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + $this->textWidth(1, $line));
        }

        $maxLabelWidth = 0;
        foreach ($rooms as $labelRoom) {
            if ($this->planStyle->isFunda) {
                $sizeKey = ((float) ($labelRoom['floor_area_m2'] ?? 0)) < 4.0 ? 2 : 4;
                $maxLabelWidth = max($maxLabelWidth, $this->textWidth($sizeKey, $this->printable(RoomType::planName($labelRoom))));
            } else {
                $maxLabelWidth = max($maxLabelWidth, $this->textWidth(3, $this->printable($this->displayLabel($labelRoom))));
            }
        }
        $labelPadding = (int) ceil($maxLabelWidth / 2) + 8;
        $planBlockWidth = self::DIMENSION_GUTTER + $labelPadding + (int) round(($maxX - $minX) * self::PIXELS_PER_METER) + $labelPadding;
        $canvasWidth = max($headerTextWidth, self::MARGIN * 2 + $planBlockWidth);
        $canvasHeight = self::MARGIN * 2 + $topGutter + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER)
            + count($notesLines) * self::NOTE_LINE_HEIGHT
            + count($summaryLines) * self::NOTE_LINE_HEIGHT
            + 30;
        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Fused floor plan would be %dx%d px, exceeding the %d px sanity bound — refusing to allocate it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $image = imagecreatetruecolor(max($canvasWidth, 400), $canvasHeight + 72);

        imageantialias($image, true);
        $surface = $this->planStyle->isFunda ? imagecolorallocate($image, 255, 255, 255) : imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_SURFACE));
        $text = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK));
        $subtext = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK_MUTED));
        $dimColor = $this->planStyle->isFunda ? $text : imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_INK_MUTED));
        $doorColor = imagecolorallocate($image, ...$this->planStyle->doorColor);
        $windowColor = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_ACCENT_CYAN));
        $otherOpeningColor = imagecolorallocate($image, 140, 140, 142);
        $walkPathColor = imagecolorallocate($image, 150, 60, 190);
        $objectColor = imagecolorallocate($image, 96, 96, 96);
        $warnFill = imagecolorallocate($image, 250, 214, 212);
        $warnBorder = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BRAND_DANGER));
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        $fallbackFills = array_map(
            fn (array $c) => imagecolorallocate($image, $c[0], $c[1], $c[2]),
            self::ROOM_PALETTE
        );
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $surface);
        if ($this->planStyle->isFunda) {
            $this->drawFundaGrid($image);
        }

        $headerLineY = 46;
        if ($this->planStyle->isFunda) {
            $this->fundaTotalAreaM2 = $totalAreaM2;
            $this->fundaUnit = $unit;
            $headerLineY = 14;
        } else {
            $this->drawText($image, 5, self::MARGIN, 12, ExportLanguage::t('Vuuro Scan - fused floor plan (rooms captured together in one visit)'), $text);
            $this->drawText($image, 2, self::MARGIN, 30, ExportLanguage::t('Room positions relative to each other, not independently verified beyond this capture.'), $subtext);
        }
        if ($overlapping !== []) {
            $this->drawText($image, 3, self::MARGIN, $headerLineY, ExportLanguage::t('WARNING: rooms below overlap in captured position - verify against the real layout before use.'), $warnBorder);
            $headerLineY += 16;
        }
        if ($label !== null && $label !== '' && !$this->planStyle->isFunda) {
            $this->drawText($image, 2, self::MARGIN, $headerLineY, $label, $subtext);
            $headerLineY += 16;
        }
        if (!$this->planStyle->isFunda) {
            $this->drawText($image, 2, self::MARGIN, $headerLineY, ExportLanguage::t('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms)), $subtext);
        }

        $planLeft = max(self::MARGIN, (int) round((imagesx($image) - $planBlockWidth) / 2));
        $originPxX = $planLeft + self::DIMENSION_GUTTER + $labelPadding;
        $originPxY = self::MARGIN + $topGutter;
        $toPx = function (float $worldX, float $worldZ) use ($minX, $minZ, $originPxX, $originPxY): array {
            return [
                $originPxX + (int) round(($worldX - $minX) * self::PIXELS_PER_METER),
                $originPxY + (int) round(($worldZ - $minZ) * self::PIXELS_PER_METER),
            ];
        };

        $xBreakpoints = $this->dimensionChainBreakpoints($rooms, $poses, 0);
        $this->drawHorizontalDimensionChain($image, $xBreakpoints, $dimensionLineY, $toPx, $unit, $dimColor);
        $zBreakpoints = $this->dimensionChainBreakpoints($rooms, $poses, 1);
        $this->drawVerticalDimensionChain($image, $zBreakpoints, $planLeft + 14, $toPx, $unit, $dimColor);

        $edgeTiers = $fusion['edgeTiers'];
        $objectLabelDraws = [];

        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            $outline = $room['outline_m'];
            $points = [];
            foreach ($outline as [$mx, $mz]) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
                [$px, $py] = $toPx($wx, $wz);
                $points[] = $px;
                $points[] = $py;
            }
            $roomFill = in_array($i, $overlapping, true)
                ? $warnFill
                : ($this->roomTypeFillColor($image, $room) ?? $fallbackFills[$i % count($fallbackFills)]);
            imagefilledpolygon($image, $points, $roomFill);
        }

        foreach ($rooms as $i => $room) {
            $this->drawObjects($image, $room, $poses[$i], $toPx, $objectColor, $text, $objectLabelDraws);
        }

        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            if (in_array($i, $overlapping, true)) {
                $points = [];
                foreach ($room['outline_m'] as [$mx, $mz]) {
                    [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
                    [$px, $py] = $toPx($wx, $wz);
                    $points[] = $px;
                    $points[] = $py;
                }
                imagesetthickness($image, (int) round(FloorPlanPalette::EXTERIOR_WALL_THICKNESS_M * self::PIXELS_PER_METER));
                imagepolygon($image, $points, $warnBorder);
                imagesetthickness($image, self::DEFAULT_LINE_THICKNESS_PX);
            } else {
                $this->drawRoomWallShadow($image, $room['outline_m'], $pose, $toPx, FloorPlanPalette::withOpenEdges($edgeTiers[$i] ?? [], $room));
            }
        }
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            if (!in_array($i, $overlapping, true)) {
                $this->drawRoomWalls($image, $room['outline_m'], $pose, $toPx, FloorPlanPalette::withOpenEdges($edgeTiers[$i] ?? [], $room), $wallColor);
            }
        }

        foreach ($rooms as $i => $room) {
            $this->drawWalkPath($image, $room, $poses[$i], $toPx, $walkPathColor);
        }
        foreach (OpeningDedup::filter($rooms, $poses) as $i => $room) {
            $this->drawOpenings($image, $room, $poses[$i], $toPx, $doorColor, $windowColor, $otherOpeningColor, $edgeTiers[$i] ?? []);
        }

        $labelDraws = $objectLabelDraws;
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            [$cx, $cz] = $this->centroidM($room['outline_m']);
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $cx, $cz);
            [$labelX, $labelY] = $toPx($wx, $wz);
            if ($this->planStyle->isFunda) {
                [$px, $pz] = $this->areaCentroidM($room['outline_m']);
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $px, $pz);
                [$labelX, $labelY] = $toPx($wx, $wz);
                $labelDraws[] = fn () => $this->drawFundaRoomLabel($image, $labelX, $labelY, $room, $unit, $text, $subtext);
                continue;
            }
            $displayLabel = $this->printable($this->displayLabel($room));
            $labelWidth = $this->textWidth(3, $displayLabel);
            $labelDraws[] = fn () => $this->drawText($image, 3, $labelX - (int) ($labelWidth / 2), $labelY - 6, $displayLabel, $text);
        }

        foreach ($labelDraws as $draw) {
            $draw();
        }

        $drawingBottomY = $originPxY + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER);
        if ($this->planStyle->showNotes) {
            $this->drawNotes($image, $notesLines, $drawingBottomY + 10, $text);
        }
        if ($this->planStyle->showMetrics) {
            $this->drawNotes($image, $summaryLines, $drawingBottomY + 10 + count($notesLines) * self::NOTE_LINE_HEIGHT, $text);
        }
        $legendY = imagesy($image) - 30;
        $legendX = self::MARGIN;
        if (!$this->planStyle->isFunda) {
            imagefilledellipse($image, $legendX + 4, $legendY, 8, 8, $doorColor);
            $this->drawText($image, 1, $legendX + 12, $legendY - 6, ExportLanguage::t('door'), $subtext);
            $legendX += 12 + $this->textWidth(1, ExportLanguage::t('door')) + 20;
            imagefilledellipse($image, $legendX + 4, $legendY, 8, 8, $windowColor);
            $this->drawText($image, 1, $legendX + 12, $legendY - 6, ExportLanguage::t('window'), $subtext);
            $legendX += 12 + $this->textWidth(1, ExportLanguage::t('window')) + 20;
            imagefilledellipse($image, $legendX + 4, $legendY, 8, 8, $otherOpeningColor);
            $this->drawText($image, 1, $legendX + 12, $legendY - 6, ExportLanguage::t('other opening'), $subtext);
            $legendX += 12 + $this->textWidth(1, ExportLanguage::t('other opening')) + 20;
            imageline($image, $legendX, $legendY, $legendX + 16, $legendY, $walkPathColor);
            $this->drawText($image, 1, $legendX + 20, $legendY - 6, ExportLanguage::t('walk path'), $subtext);
            $legendX += 20 + $this->textWidth(1, ExportLanguage::t('walk path')) + 20;
            imagerectangle($image, $legendX, $legendY - 4, $legendX + 8, $legendY + 4, $objectColor);
            $this->drawText($image, 1, $legendX + 12, $legendY - 6, ExportLanguage::t('detected object'), $subtext);
        }

        $this->drawRoomTypeLegend($image, $rooms, $legendY - 14, $subtext);
        $this->drawTitleBlock($image, $text);
        $this->drawFooter($image, $subtext);

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    private function drawRoomTypeLegend($image, array $rooms, int $y, int $textColor): void
    {
        if (!$this->planStyle->showRoomTypeLegend) {
            return;
        }
        if (count($rooms) < 2) {
            return;
        }
        $typesPresent = [];
        foreach ($rooms as $room) {
            $type = self::roomTypeValue($room);
            if ($type !== null && FloorPlanPalette::roomFillFor($type) !== null && !in_array($type, $typesPresent, true)) {
                $typesPresent[] = $type;
            }
        }
        if ($typesPresent === []) {
            return;
        }
        $x = self::MARGIN;
        foreach ($typesPresent as $type) {
            $fill = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::roomFillFor($type)));
            imagefilledrectangle($image, $x, $y - 4, $x + 8, $y + 4, $fill);
            $label = RoomType::labelFor($type);
            $this->drawText($image, self::FONT_SMALL, $x + 12, $y - 6, $label, $textColor);
            $x += 12 + $this->textWidth(self::FONT_SMALL, $label) + 16;
        }
    }

    private function displayLabel(array $room): string
    {
        return RoomType::displayLabelForRoom($room);
    }

    private static function openingWidthM(array $opening): float
    {
        $category = $opening['category'] ?? 'opening';
        $measured = $opening['width_m'] ?? null;
        if (is_int($measured) || is_float($measured)) {
            $measured = (float) $measured;
            return $category === 'door' ? max(0.6, min(1.2, $measured)) : $measured;
        }
        return match ($category) {
            'door' => self::DOOR_LEAF_M,
            'window' => self::WINDOW_WIDTH_M,
            default => self::OPENING_WIDTH_M,
        };
    }

    private function drawOpenings($image, array $room, array $pose, callable $toPx, int $doorColor, int $windowColor, int $otherOpeningColor, array $roomEdgeTiers): void
    {
        $outline = $room['outline_m'] ?? [];
        $n = count($outline);
        $centroidX = $n > 0 ? array_sum(array_column($outline, 0)) / $n : 0.0;
        $centroidZ = $n > 0 ? array_sum(array_column($outline, 1)) / $n : 0.0;
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        $white = imagecolorallocate($image, 255, 255, 255);

        foreach ($room['openings'] ?? [] as $opening) {
            [$mx, $mz] = $opening['position_m'];
            $category = $opening['category'];
            $color = match ($category) {
                'door' => $doorColor,
                'window' => $windowColor,
                default => $otherOpeningColor,
            };
            [$wallDx, $wallDz, $normalDx, $normalDz, $edgeIndex, $wallDistance] = $this->nearestWallOrientation($outline, $mx, $mz, $centroidX, $centroidZ);
            if ($n >= 3 && $wallDistance > self::MAX_OPENING_WALL_DISTANCE_M) {
                continue;
            }
            if (isset($outline[$edgeIndex])) {
                [$edgeAx, $edgeAz] = $outline[$edgeIndex];
                $along = ($mx - $edgeAx) * $wallDx + ($mz - $edgeAz) * $wallDz;
                $mx = $edgeAx + $wallDx * $along;
                $mz = $edgeAz + $wallDz * $along;
            }
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
            [$px, $py] = $toPx($wx, $wz);
            $wallHalfM = $this->edgeThicknessM($roomEdgeTiers, $edgeIndex) / 2;
            $seamGap = $roomEdgeTiers[$edgeIndex] ?? null;
            $outerHalfM = is_float($seamGap) ? $wallHalfM + $seamGap + self::SEAM_OVERLAP_M : $wallHalfM;
            $widthM = self::openingWidthM($opening);
            $half = $widthM / 2;
            [$wallDx, $wallDz] = $this->pixelDirection($pose, $toPx, $mx, $mz, $px, $py, $wallDx, $wallDz);
            [$normalDx, $normalDz] = $this->pixelDirection($pose, $toPx, $mx, $mz, $px, $py, $normalDx, $normalDz);

            $punchCorner = fn (float $alongSign, float $acrossSign): array => [
                $px + $wallDx * $alongSign * $half * self::PIXELS_PER_METER + $normalDx * $acrossSign * ($acrossSign > 0 ? $wallHalfM : $outerHalfM) * self::PIXELS_PER_METER,
                $py + $wallDz * $alongSign * $half * self::PIXELS_PER_METER + $normalDz * $acrossSign * ($acrossSign > 0 ? $wallHalfM : $outerHalfM) * self::PIXELS_PER_METER,
            ];
            $punchPoints = [];
            foreach ([$punchCorner(-1, -1), $punchCorner(1, -1), $punchCorner(1, 1), $punchCorner(-1, 1)] as [$cx, $cy]) {
                $punchPoints[] = (int) round($cx);
                $punchPoints[] = (int) round($cy);
            }
            imagefilledpolygon($image, $punchPoints, $white);

            if ($category === 'door') {
                $radius = $widthM * self::PIXELS_PER_METER;
                $hingeX = $px - $wallDx * $half * self::PIXELS_PER_METER;
                $hingeY = $py - $wallDz * $half * self::PIXELS_PER_METER;
                $steps = 8;
                $prevX = $hingeX + $wallDx * $radius;
                $prevY = $hingeY + $wallDz * $radius;
                for ($step = 1; $step <= $steps; $step++) {
                    $t = (M_PI / 2) * ($step / $steps);
                    $curX = $hingeX + $radius * (cos($t) * $wallDx + sin($t) * $normalDx);
                    $curY = $hingeY + $radius * (cos($t) * $wallDz + sin($t) * $normalDz);
                    imageline($image, (int) round($prevX), (int) round($prevY), (int) round($curX), (int) round($curY), $color);
                    $prevX = $curX;
                    $prevY = $curY;
                }
                $swingX = $hingeX + $normalDx * $radius;
                $swingY = $hingeY + $normalDz * $radius;
                imageline($image, (int) round($hingeX), (int) round($hingeY), (int) round($swingX), (int) round($swingY), $color);
                $this->drawJambSquares($image, $wallColor, $px, $py, $wallDx, $wallDz, $half * self::PIXELS_PER_METER);
            } elseif ($category === 'window' && $this->planStyle->isFunda) {
                $spanPx = $half * self::PIXELS_PER_METER;
                imageline(
                    $image,
                    (int) round($px - $wallDx * $spanPx),
                    (int) round($py - $wallDz * $spanPx),
                    (int) round($px + $wallDx * $spanPx),
                    (int) round($py + $wallDz * $spanPx),
                    $wallColor
                );
            } elseif ($category === 'window') {
                $half = $half * self::PIXELS_PER_METER;
                imagesetthickness($image, 3);
                imageline(
                    $image,
                    (int) round($px - $wallDx * $half),
                    (int) round($py - $wallDz * $half),
                    (int) round($px + $wallDx * $half),
                    (int) round($py + $wallDz * $half),
                    $windowColor
                );
                imagesetthickness($image, self::DEFAULT_LINE_THICKNESS_PX);
            } else {
                imagefilledellipse($image, $px, $py, 10, 10, $color);
                $this->drawJambSquares($image, $wallColor, $px, $py, $wallDx, $wallDz, $half * self::PIXELS_PER_METER);
            }
        }
    }

    private function pixelDirection(array $pose, callable $toPx, float $mx, float $mz, float $px, float $py, float $dx, float $dz): array
    {
        [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx + $dx, $mz + $dz);
        [$qx, $qy] = $toPx($wx, $wz);
        $length = hypot($qx - $px, $qy - $py);
        if ($length < 1e-6) {
            return [$dx, $dz];
        }
        return [($qx - $px) / $length, ($qy - $py) / $length];
    }

    private function drawJambSquares($image, int $wallColor, float $px, float $py, float $wallDx, float $wallDz, float $halfPx): void
    {
        $jamb = 3;
        foreach ([-1, 1] as $side) {
            $jx = $px + $wallDx * $side * $halfPx;
            $jy = $py + $wallDz * $side * $halfPx;
            imagefilledrectangle($image, (int) round($jx - $jamb / 2), (int) round($jy - $jamb / 2), (int) round($jx + $jamb / 2), (int) round($jy + $jamb / 2), $wallColor);
        }
    }

    private function drawWalkPath($image, array $room, array $pose, callable $toPx, int $color): void
    {
        if (!$this->planStyle->showWalkPath) {
            return;
        }
        $points = $room['walk_path_m'] ?? [];
        if (count($points) < 2) {
            return;
        }
        for ($i = 0; $i < count($points) - 1; $i++) {
            [$ax, $az] = $points[$i];
            [$bx, $bz] = $points[$i + 1];
            [$awx, $awz] = RoomFusionSolver::transformPoint($pose, $ax, $az);
            [$apx, $apy] = $toPx($awx, $awz);
            [$bwx, $bwz] = RoomFusionSolver::transformPoint($pose, $bx, $bz);
            [$bpx, $bpy] = $toPx($bwx, $bwz);
            $this->drawDashedSegment($image, $apx, $apy, $bpx, $bpy, $color);
        }
    }

    private function localRectPoints(array $pose, callable $toPx, float $cx, float $cz, float $halfW, float $halfD): array
    {
        $points = [];
        foreach ([[$cx - $halfW, $cz - $halfD], [$cx + $halfW, $cz - $halfD], [$cx + $halfW, $cz + $halfD], [$cx - $halfW, $cz + $halfD]] as [$lx, $lz]) {
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $lx, $lz);
            [$px, $py] = $toPx($wx, $wz);
            $points[] = $px;
            $points[] = $py;
        }
        return $points;
    }

    private function drawObjectIcon($image, array $pose, callable $toPx, string $category, float $mx, float $mz, float $halfW, float $halfD): bool
    {
        $fixtureFill = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::FIXTURE_FILL));
        $fixtureLine = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::FIXTURE_LINE));
        $fixtureLight = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::FIXTURE_LIGHT));
        $hearth = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::HEARTH_FILL));
        $white = imagecolorallocate($image, 255, 255, 255);
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        [$cwx, $cwz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
        [$cx, $cy] = $toPx($cwx, $cwz);
        $rectFill = function (float $hw, float $hd, int $fill, int $line) use ($image, $pose, $toPx, $mx, $mz): void {
            $pts = $this->localRectPoints($pose, $toPx, $mx, $mz, $hw, $hd);
            imagefilledpolygon($image, $pts, $fill);
            imagepolygon($image, $pts, $line);
        };
        $ellipse = fn (float $rw, float $rd, int $fill, ?int $line) => [
            imagefilledellipse($image, $cx, $cy, (int) round($rw * 2 * self::PIXELS_PER_METER), (int) round($rd * 2 * self::PIXELS_PER_METER), $fill),
            $line !== null ? imageellipse($image, $cx, $cy, (int) round($rw * 2 * self::PIXELS_PER_METER), (int) round($rd * 2 * self::PIXELS_PER_METER), $line) : null,
        ];

        $rectFillAt = function (float $ox, float $oz, float $hw, float $hd, int $fill, int $line) use ($image, $pose, $toPx, $mx, $mz): void {
            $pts = $this->localRectPoints($pose, $toPx, $mx + $ox, $mz + $oz, $hw, $hd);
            imagefilledpolygon($image, $pts, $fill);
            imagepolygon($image, $pts, $line);
        };

        switch ($category) {
            case 'sink':
                $rectFill($halfW, $halfD, $fixtureLight, $fixtureLine);
                $ellipse(min($halfW, $halfD) * 0.6, min($halfW, $halfD) * 0.6, $white, $fixtureLine);
                return true;
            case 'toilet':
                $rectFill($halfW, $halfD, $fixtureLight, $fixtureLine);
                $ellipse($halfW * 0.65, $halfD * 0.55, $white, $fixtureLine);
                return true;
            case 'bathtub':
                $rectFill($halfW, $halfD, $white, $fixtureLine);
                $rectFill(max($halfW - 0.05, $halfW * 0.85), max($halfD - 0.05, $halfD * 0.85), $fixtureLight, $fixtureLine);
                return true;
            case 'stove':
            case 'oven':
                $rectFill($halfW, $halfD, $fixtureFill, $fixtureLine);
                $rectFillAt(-$halfW * 0.5, -$halfD * 0.5, $halfW * 0.28, $halfD * 0.28, $fixtureLight, $fixtureLine);
                $rectFillAt($halfW * 0.5, -$halfD * 0.5, $halfW * 0.28, $halfD * 0.28, $fixtureLight, $fixtureLine);
                $rectFillAt(-$halfW * 0.5, $halfD * 0.5, $halfW * 0.28, $halfD * 0.28, $fixtureLight, $fixtureLine);
                $rectFillAt($halfW * 0.5, $halfD * 0.5, $halfW * 0.28, $halfD * 0.28, $fixtureLight, $fixtureLine);
                return true;
            case 'refrigerator':
            case 'dishwasher':
            case 'storage':
                $rectFill($halfW, $halfD, $fixtureFill, $fixtureLine);
                $rectFillAt(0, 0, $halfW * 0.85, $halfD * 0.15, $fixtureLine, $fixtureLine);
                return true;
            case 'washerdryer':
            case 'washer_dryer':
                $rectFill($halfW, $halfD, $fixtureFill, $fixtureLine);
                $ellipse(min($halfW, $halfD) * 0.55, min($halfW, $halfD) * 0.55, $fixtureLight, $fixtureLine);
                return true;
            case 'bed':
                $bedFill = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BED_FRAME_FILL));
                $rectFill($halfW, $halfD, $bedFill, $fixtureLine);
                $rectFillAt(0, $halfD * 0.60, $halfW * 0.95, $halfD * 0.38, $white, $fixtureLine);
                return true;
            case 'sofa':
                $rectFill($halfW, $halfD, $fixtureLight, $fixtureLine);
                $rectFillAt(0, -$halfD + $halfD * 0.15, $halfW * 0.95, $halfD * 0.22, $fixtureFill, $fixtureLine);
                return true;
            case 'chair':
                $rectFill($halfW, $halfD, $white, $fixtureLine);
                $rectFillAt(0, -$halfD + $halfD * 0.12, $halfW * 0.95, $halfD * 0.18, $fixtureFill, $fixtureLine);
                return true;
            case 'table':
                $rectFill($halfW, $halfD, $white, $fixtureLine);
                $ellipse(min($halfW, $halfD) * 0.30, min($halfW, $halfD) * 0.30, $fixtureLight, $fixtureLine);
                return true;
            case 'television':
                $rectFill($halfW, $halfD, $hearth, $fixtureLine);
                $rectFillAt(0, 0, $halfW * 0.85, max($halfD * 0.40, 0.02), $white, $fixtureLine);
                return true;
            case 'fireplace':
                $rectFill($halfW, $halfD, $hearth, $fixtureLine);
                $rectFillAt(0, $halfD * 0.5, $halfW * 0.7, $halfD * 0.25, $fixtureFill, $fixtureLine);
                return true;
            case 'stairs':
                $rectFill($halfW, $halfD, $white, $wallColor);
                $steps = 6;
                for ($s = 1; $s < $steps; $s++) {
                    $lz = -$halfD + ($s / $steps) * (2 * $halfD);
                    [$ax, $az] = RoomFusionSolver::transformPoint($pose, $mx - $halfW, $mz + $lz);
                    [$bx, $bz] = RoomFusionSolver::transformPoint($pose, $mx + $halfW, $mz + $lz);
                    [$apx, $apy] = $toPx($ax, $az);
                    [$bpx, $bpy] = $toPx($bx, $bz);
                    imageline($image, $apx, $apy, $bpx, $bpy, $wallColor);
                }
                return true;
            default:
                return false;
        }
    }

    private function drawObjects($image, array $room, array $pose, callable $toPx, int $color, int $textColor, array &$labelDraws): void
    {
        if ($this->planStyle->furnitureCategories === []) {
            return;
        }
        foreach ($room['objects'] ?? [] as $object) {
            if (!empty($object['excluded'])) {
                continue;
            }
            if (!$this->planStyle->shouldDrawFurniture((string) ($object['category'] ?? ''))) {
                continue;
            }
            [$mx, $mz, $halfWidth, $halfDepth, $frameRad] = ObjectFootprint::fit($room, $object, FloorPlanPalette::wallThicknessM($this->planStyle->isFunda, false) / 2);
            $objectPose = ObjectFootprint::objectPose($pose, $mx, $mz, $frameRad);
            $category = strtolower((string) $object['category']);
            if ($this->drawObjectIcon($image, $objectPose, $toPx, $category, $mx, $mz, $halfWidth, $halfDepth)) {
                continue;
            }
            $pts = $this->localRectPoints($objectPose, $toPx, $mx, $mz, $halfWidth, $halfDepth);
            imagepolygon($image, $pts, $color);
            $labelText = isset($object['custom_name']) && is_string($object['custom_name']) && $object['custom_name'] !== ''
                ? $object['custom_name']
                : ExportLanguage::objectName((string) $object['category']);
            $categoryLabel = $this->printable($labelText);
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
            [$cx, $cy] = $toPx($wx, $wz);
            $labelDraws[] = fn () => $this->drawText($image, self::FONT_SMALL, $cx - (int) round($halfWidth * self::PIXELS_PER_METER) + 2, $cy - (int) round($halfDepth * self::PIXELS_PER_METER) - 10, $categoryLabel, $textColor);
        }
    }

    private function drawDashedSegment($image, int $x1, int $y1, int $x2, int $y2, int $color): void
    {
        $dashLength = 6.0;
        $gapLength = 5.0;
        $dx = $x2 - $x1;
        $dy = $y2 - $y1;
        $distance = sqrt($dx * $dx + $dy * $dy);
        if ($distance < 0.5) {
            return;
        }
        $step = $dashLength + $gapLength;
        $steps = (int) ceil($distance / $step);
        for ($i = 0; $i < $steps; $i++) {
            $startT = ($i * $step) / $distance;
            $endT = min(1.0, ($i * $step + $dashLength) / $distance);
            imageline(
                $image,
                (int) round($x1 + $dx * $startT),
                (int) round($y1 + $dy * $startT),
                (int) round($x1 + $dx * $endT),
                (int) round($y1 + $dy * $endT),
                $color
            );
        }
    }

    private function nearestWallOrientation(array $outlineM, float $x, float $z, float $centroidX, float $centroidZ): array
    {
        $n = count($outlineM);
        $bestDist = INF;
        $wallDx = 1.0;
        $wallDz = 0.0;
        $bestEdgeIndex = 0;
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $edgeDx = $bx - $ax;
            $edgeDz = $bz - $az;
            $lengthSq = $edgeDx ** 2 + $edgeDz ** 2;
            if ($lengthSq < 1e-9) {
                continue;
            }
            $t = max(0.0, min(1.0, (($x - $ax) * $edgeDx + ($z - $az) * $edgeDz) / $lengthSq));
            $projX = $ax + $t * $edgeDx;
            $projZ = $az + $t * $edgeDz;
            $dist = sqrt(($x - $projX) ** 2 + ($z - $projZ) ** 2);
            if ($dist < $bestDist) {
                $bestDist = $dist;
                $edgeLength = sqrt($lengthSq);
                $wallDx = $edgeDx / $edgeLength;
                $wallDz = $edgeDz / $edgeLength;
                $bestEdgeIndex = $i;
            }
        }
        $normalDx = -$wallDz;
        $normalDz = $wallDx;
        $towardCentroidX = $centroidX - $x;
        $towardCentroidZ = $centroidZ - $z;
        if ($normalDx * $towardCentroidX + $normalDz * $towardCentroidZ < 0) {
            $normalDx = -$normalDx;
            $normalDz = -$normalDz;
        }
        return [$wallDx, $wallDz, $normalDx, $normalDz, $bestEdgeIndex, $bestDist];
    }

    private function insetTowardCentroid(float $x, float $z, float $centroidX, float $centroidZ, float $insetM): array
    {
        $dx = $centroidX - $x;
        $dz = $centroidZ - $z;
        $dist = sqrt($dx ** 2 + $dz ** 2);
        if ($dist < 0.001) {
            return [$x, $z];
        }
        return [$x + ($dx / $dist) * $insetM, $z + ($dz / $dist) * $insetM];
    }

    private function dimensionChainBreakpoints(array $rooms, array $poses, int $axis): array
    {
        $values = [];
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            $min = INF;
            $max = -INF;
            foreach ($room['outline_m'] as [$mx, $mz]) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
                $v = $axis === 0 ? $wx : $wz;
                $min = min($min, $v);
                $max = max($max, $v);
            }
            $values[] = $min;
            $values[] = $max;
        }
        sort($values);
        $breakpoints = [];
        foreach ($values as $v) {
            if ($breakpoints === [] || $v - end($breakpoints) > self::WALL_GAP_MERGE_M) {
                $breakpoints[] = $v;
            }
        }
        return $breakpoints;
    }

    private function drawHorizontalDimensionChain($image, array $breakpoints, int $y, callable $toPx, string $unit, int $color): void
    {
        for ($i = 0; $i < count($breakpoints) - 1; $i++) {
            $spanM = $breakpoints[$i + 1] - $breakpoints[$i];
            if ($spanM < 0.1) {
                continue;
            }
            [$x1] = $toPx($breakpoints[$i], 0.0);
            [$x2] = $toPx($breakpoints[$i + 1], 0.0);
            $this->drawDimensionSegment($image, $x1, $y, $x2, $y, $color);
            $label = UnitFormatter::length($spanM, $unit);
            $this->drawText($image, 1, (int) (($x1 + $x2) / 2) - 12, $y - 12, $label, $color);
        }
    }

    private function drawVerticalDimensionChain($image, array $breakpoints, int $x, callable $toPx, string $unit, int $color): void
    {
        for ($i = 0; $i < count($breakpoints) - 1; $i++) {
            $spanM = $breakpoints[$i + 1] - $breakpoints[$i];
            if ($spanM < 0.1) {
                continue;
            }
            [, $y1] = $toPx(0.0, $breakpoints[$i]);
            [, $y2] = $toPx(0.0, $breakpoints[$i + 1]);
            $this->drawDimensionSegment($image, $x, $y1, $x, $y2, $color);
            $label = UnitFormatter::length($spanM, $unit);
            $this->drawTextUp($image, 1, $x - 14, (int) (($y1 + $y2) / 2) + 20, $label, $color);
        }
    }

    private function drawWallLengths($image, array $outlineM, array $pose, callable $toPx, int $color, string $unit, array $roomEdgeTiers): void
    {
        $n = count($outlineM);
        if ($n === 0) {
            return;
        }
        $centroidX = array_sum(array_column($outlineM, 0)) / $n;
        $centroidZ = array_sum(array_column($outlineM, 1)) / $n;
        for ($i = 0; $i < $n; $i++) {
            if (isset($roomEdgeTiers[$i])) {
                continue;
            }
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $lengthM = sqrt(($bx - $ax) ** 2 + ($bz - $az) ** 2);
            if ($lengthM < 0.3) {
                continue;
            }
            $midX = ($ax + $bx) / 2;
            $midZ = ($az + $bz) / 2;
            [$midX, $midZ] = $this->insetTowardCentroid($midX, $midZ, $centroidX, $centroidZ, -self::WALL_LABEL_INSET_M);
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $midX, $midZ);
            [$px, $py] = $toPx($wx, $wz);
            $this->drawText($image, 1, $px - 10, $py - 5, UnitFormatter::length($lengthM, $unit), $color);
        }
    }

    private function tileGeometry(array $room, string $orientation = 'as_captured'): array
    {
        if ($orientation === 'longest_horizontal' && count($room['outline_m']) >= 2) {
            $rotation = TileOrientation::angleFor($room['outline_m']);
            $cosR = cos($rotation);
            $sinR = sin($rotation);
            $xs = [];
            $zs = [];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                $xs[] = $mx * $cosR - $mz * $sinR;
                $zs[] = $mx * $sinR + $mz * $cosR;
            }
            $width = max($xs) - min($xs);
            $height = max($zs) - min($zs);
        } else {
            $width = $room['bounding_dimensions_m']['width_m'];
            $height = $room['bounding_dimensions_m']['length_m'];
        }
        $w = (int) round($width * self::PIXELS_PER_METER) + self::TILE_PADDING * 2;
        $h = (int) round($height * self::PIXELS_PER_METER) + self::TILE_PADDING * 2 + self::LABEL_HEIGHT;
        return ['width' => max($w, 120), 'height' => max($h, 120)];
    }

    private function drawTileDimensionChains($image, array $room, array $tile, int $originX, int $originY, float $rotation, string $unit, int $color): void
    {
        $cosR = cos($rotation);
        $sinR = sin($rotation);
        $rotated = [];
        foreach ($room['outline_m'] as [$mx, $mz]) {
            $rotated[] = [$mx * $cosR - $mz * $sinR, $mx * $sinR + $mz * $cosR];
        }
        $xs = array_column($rotated, 0);
        $zs = array_column($rotated, 1);
        if ($xs === [] || $zs === []) return;
        $minLocalX = min($xs);
        $minLocalZ = min($zs);
        $xBreak = $this->dedupValues($xs);
        $zBreak = $this->dedupValues($zs);
        if (count($xBreak) < 2 || count($zBreak) < 2) return;

        $toPx = fn (float $rx, float $rz): array => [
            $originX + self::TILE_PADDING + (int) round(($rx - $minLocalX) * self::PIXELS_PER_METER),
            $originY + self::TILE_PADDING + (int) round(($rz - $minLocalZ) * self::PIXELS_PER_METER),
        ];
        $chainOffset = 14;
        $topY = $originY + self::TILE_PADDING - $chainOffset;
        $bottomY = $originY + $tile['height'] - self::LABEL_HEIGHT - self::TILE_PADDING + $chainOffset;
        $leftX = $originX + self::TILE_PADDING - $chainOffset;
        $rightX = $originX + $tile['width'] - self::TILE_PADDING + $chainOffset;

        $prev = null;
        foreach ($xBreak as $xv) {
            [$px] = $toPx($xv, $zBreak[0]);
            if ($prev !== null) {
                $this->drawDimensionSegment($image, $prev[0], $topY, $px, $topY, $color);
                $label = UnitFormatter::length($xv - $prev[1], $unit);
                $w = $this->textWidth(1, $label);
                $this->drawText($image, 1, intval(($prev[0] + $px) / 2) - intval($w / 2), $topY - 14, $label, $color);
            }
            $prev = [$px, $xv];
        }

        $prev = null;
        foreach ($xBreak as $xv) {
            [$px] = $toPx($xv, $zBreak[0]);
            if ($prev !== null) {
                $this->drawDimensionSegment($image, $prev[0], $bottomY, $px, $bottomY, $color);
                $label = UnitFormatter::length($xv - $prev[1], $unit);
                $w = $this->textWidth(1, $label);
                $this->drawText($image, 1, intval(($prev[0] + $px) / 2) - intval($w / 2), $bottomY + 4, $label, $color);
            }
            $prev = [$px, $xv];
        }

        $prev = null;
        foreach ($zBreak as $zv) {
            [, $py] = $toPx($xBreak[0], $zv);
            if ($prev !== null) {
                $this->drawDimensionSegment($image, $leftX, $prev[0], $leftX, $py, $color);
                $label = UnitFormatter::length($zv - $prev[1], $unit);
                $this->drawTextUp($image, 1, $leftX - 13, intval(($prev[0] + $py) / 2) + 12, $label, $color);
            }
            $prev = [$py, $zv];
        }

        $prev = null;
        foreach ($zBreak as $zv) {
            [, $py] = $toPx($xBreak[0], $zv);
            if ($prev !== null) {
                $this->drawDimensionSegment($image, $rightX, $prev[0], $rightX, $py, $color);
                $label = UnitFormatter::length($zv - $prev[1], $unit);
                $this->drawTextUp($image, 1, $rightX + 3, intval(($prev[0] + $py) / 2) + 12, $label, $color);
            }
            $prev = [$py, $zv];
        }
    }

    private function dedupValues(array $vals): array
    {
        sort($vals);
        $out = [];
        foreach ($vals as $v) {
            if ($out === [] || abs($v - end($out)) > self::TILE_BREAKPOINT_MERGE_M) {
                $out[] = $v;
            }
        }
        return $out;
    }

    private function drawRoomTile($image, array $room, int $originX, int $originY, int $fill, int $wallColor, int $text, int $subtext, int $doorColor, int $windowColor, int $otherOpeningColor, int $walkPathColor, int $objectColor, string $unit = UnitFormatter::METRIC): void
    {
        $rotation = 0.0;
        if ($this->planStyle->orientation === 'longest_horizontal' && count($room['outline_m']) >= 2) {
            $rotation = TileOrientation::angleFor($room['outline_m']);
        }
        $cosR = cos($rotation);
        $sinR = sin($rotation);
        $xs = [];
        $zs = [];
        foreach ($room['outline_m'] as [$mx, $mz]) {
            $xs[] = $mx * $cosR - $mz * $sinR;
            $zs[] = $mx * $sinR + $mz * $cosR;
        }
        $minLocalX = $xs === [] ? 0.0 : min($xs);
        $minLocalZ = $zs === [] ? 0.0 : min($zs);

        $points = [];
        foreach ($room['outline_m'] as [$mx, $mz]) {
            $rx = $mx * $cosR - $mz * $sinR - $minLocalX;
            $rz = $mx * $sinR + $mz * $cosR - $minLocalZ;
            $points[] = $originX + self::TILE_PADDING + (int) round($rx * self::PIXELS_PER_METER);
            $points[] = $originY + self::TILE_PADDING + (int) round($rz * self::PIXELS_PER_METER);
        }

        imagefilledpolygon($image, $points, $fill);
        $tileToPx = function (float $mx, float $mz) use ($cosR, $sinR, $minLocalX, $minLocalZ, $originX, $originY): array {
            $rx = $mx * $cosR - $mz * $sinR - $minLocalX;
            $rz = $mx * $sinR + $mz * $cosR - $minLocalZ;
            return [
                $originX + self::TILE_PADDING + (int) round($rx * self::PIXELS_PER_METER),
                $originY + self::TILE_PADDING + (int) round($rz * self::PIXELS_PER_METER),
            ];
        };
        $identityPose = ['originX' => 0.0, 'originZ' => 0.0, 'rotationRad' => 0.0];
        $labelDraws = [];
        $this->drawObjects($image, $room, $identityPose, $tileToPx, $objectColor, $text, $labelDraws);
        $this->drawRoomWallShadow($image, $room['outline_m'], $identityPose, $tileToPx, FloorPlanPalette::withOpenEdges([], $room));
        $this->drawRoomWalls($image, $room['outline_m'], $identityPose, $tileToPx, FloorPlanPalette::withOpenEdges([], $room), $wallColor);
        $this->drawWalkPath($image, $room, $identityPose, $tileToPx, $walkPathColor);
        $this->drawOpenings($image, $room, $identityPose, $tileToPx, $doorColor, $windowColor, $otherOpeningColor, []);
        if ($this->planStyle->isFunda) {
            $tile = $this->tileGeometry($room, $this->planStyle->orientation);
            $this->drawTileDimensionChains($image, $room, $tile, $originX, $originY, $rotation, $unit, $text);
        } else {
            $this->drawWallLengths($image, $room['outline_m'], $identityPose, $tileToPx, $subtext, $unit, FloorPlanPalette::withOpenEdges([], $room));
        }
        foreach ($labelDraws as $draw) {
            $draw();
        }

        if ($this->planStyle->isFunda) {
            [$cx, $cz] = $this->areaCentroidM($room['outline_m']);
            [$labelX, $labelY] = $tileToPx($cx, $cz);
            $this->drawFundaRoomLabel($image, $labelX, $labelY, $room, $unit, $text, $subtext);
            return;
        }
        $drawnHeightM = $zs === [] ? $room['bounding_dimensions_m']['length_m'] : max($zs) - min($zs);
        $labelY = $originY + self::TILE_PADDING + (int) round($drawnHeightM * self::PIXELS_PER_METER)
            + (int) round(self::WALL_LABEL_INSET_M * self::PIXELS_PER_METER) + 14;
        $this->drawText($image, 4, $originX + self::TILE_PADDING, $labelY, $this->printable($this->displayLabel($room)), $text);
        if (!$this->planStyle->showMetrics) {
            return;
        }
        $metrics = ExportLanguage::t('%s - %s perimeter - %s confidence', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit), ExportLanguage::t((string) $room['confidence']));
        $this->drawText($image, 2, $originX + self::TILE_PADDING, $labelY + 18, $metrics, $subtext);
        $lineY = $labelY + 32;
        if (($room['height_m'] ?? null) !== null) {
            $this->drawText($image, 2, $originX + self::TILE_PADDING, $lineY, ExportLanguage::t('%s height', UnitFormatter::length($room['height_m'], $unit)), $subtext);
            $lineY += 12;
        }
        if (($room['volume_m3_indicative'] ?? null) !== null) {
            $this->drawText($image, 2, $originX + self::TILE_PADDING, $lineY, ExportLanguage::t('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit)), $subtext);
        }
    }
}