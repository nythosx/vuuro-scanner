<?php

declare(strict_types=1);

namespace VuuroScan\Export;

use VuuroScan\RoomType;

/**
 * Renders a FloorPlan contract array to a PNG "floor plan sheet": each
 * room's own outline drawn to scale, tiled left-to-right with its label,
 * area, and confidence. Deliberately NOT a single fused building layout —
 * see docs/adr/0002-export-coordinate-frame.md for why that would be
 * dishonest given how multi-room sessions are captured today.
 *
 * Pure GD, no external library/font file — GD's built-in bitmap fonts
 * (imagestring) are enough for labels and keep this dependency-free.
 */
final class FloorPlanImageRenderer
{
    private const PIXELS_PER_METER = 60;
    private const TILE_PADDING = 24;
    private const LABEL_HEIGHT = 56;
    private const TILE_GAP = 32;
    private const MARGIN = 24;
    private const DIMENSION_GUTTER = 28;
    // Defense-in-depth: RoomPlanSimulatorAdapter already bounds coordinate
    // magnitude before this ever runs, but this renderer shouldn't rely
    // solely on an upstream caller getting that right.
    private const MAX_CANVAS_DIMENSION_PX = 4000;
    private const ROOM_PALETTE = [
        [214, 231, 245, 30, 64, 110],
        [223, 240, 216, 45, 106, 79],
        [250, 233, 205, 178, 108, 41],
        [237, 220, 240, 111, 66, 120],
        [216, 240, 238, 40, 110, 105],
    ];
    private const WALL_COLOR = [20, 20, 20];
    private const DEFAULT_LINE_THICKNESS_PX = 1;
    private const FONT_SMALL = 1;
    private const NOTE_LINE_HEIGHT = 13;
    private const WINDOW_TICK_LENGTH_M = 0.5;
    private const DOOR_LEAF_M = 0.8;
    private const WINDOW_WIDTH_M = 1.0;
    private const OPENING_WIDTH_M = 0.7;
    private const FOOTER_TEXT = 'Indicative measurements - NEN2580-inspired, not certified. No rights can be derived from this plan.';
    private const WALL_LABEL_INSET_M = 0.35;
    private const OPENING_LABEL_INSET_M = 0.35;

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
        return isset($roomEdgeTiers[$edgeIndex])
            ? FloorPlanPalette::INTERIOR_WALL_THICKNESS_M
            : FloorPlanPalette::EXTERIOR_WALL_THICKNESS_M;
    }

    private function roomWallPointSets(array $outlineM, array $pose, callable $toPx, array $roomEdgeTiers): array
    {
        $n = count($outlineM);
        $sets = [];
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $dx = $bx - $ax;
            $dz = $bz - $az;
            $len = sqrt($dx ** 2 + $dz ** 2);
            if ($len < 1e-6) {
                continue;
            }
            $ux = $dx / $len;
            $uz = $dz / $len;
            $nx = -$uz;
            $nz = $ux;
            $half = $this->edgeThicknessM($roomEdgeTiers, $i) / 2;

            $eax = $ax - $ux * $half;
            $eaz = $az - $uz * $half;
            $ebx = $bx + $ux * $half;
            $ebz = $bz + $uz * $half;
            $corners = [
                [$eax - $nx * $half, $eaz - $nz * $half],
                [$ebx - $nx * $half, $ebz - $nz * $half],
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
        $pad = 4;
        $minX = PHP_INT_MAX;
        $minY = PHP_INT_MAX;
        $maxX = PHP_INT_MIN;
        $maxY = PHP_INT_MIN;
        foreach ($pointSets as $points) {
            for ($k = 0; $k < count($points); $k += 2) {
                $minX = min($minX, $points[$k]);
                $maxX = max($maxX, $points[$k]);
                $minY = min($minY, $points[$k + 1]);
                $maxY = max($maxY, $points[$k + 1]);
            }
        }
        $cropX = max(0, (int) floor($minX) - $pad);
        $cropY = max(0, (int) floor($minY) - $pad);
        $cropW = min(imagesx($image) - $cropX, (int) ceil($maxX - $minX) + $pad * 2 + $shadowDx);
        $cropH = min(imagesy($image) - $cropY, (int) ceil($maxY - $minY) + $pad * 2 + $shadowDy);
        if ($cropW <= 0 || $cropH <= 0) {
            return;
        }

        $layer = imagecreatetruecolor($cropW, $cropH);
        imagecopy($layer, $image, 0, 0, $cropX, $cropY, $cropW, $cropH);
        imagealphablending($layer, true);
        $shadowColor = imagecolorallocatealpha($layer, 0, 0, 0, 70);
        foreach ($pointSets as $points) {
            $shifted = [];
            for ($k = 0; $k < count($points); $k += 2) {
                $shifted[] = $points[$k] - $cropX + $shadowDx;
                $shifted[] = $points[$k + 1] - $cropY + $shadowDy;
            }
            imagefilledpolygon($layer, $shifted, $shadowColor);
        }
        imagefilter($layer, IMG_FILTER_GAUSSIAN_BLUR);
        imagefilter($layer, IMG_FILTER_GAUSSIAN_BLUR);

        imagecopy($image, $layer, $cropX, $cropY, 0, 0, $cropW, $cropH);
        imagedestroy($layer);
    }

    private function roomTypeFillColor($image, array $room)
    {
        $hex = FloorPlanPalette::roomFillFor(self::roomTypeValue($room));
        return $hex !== null ? imagecolorallocate($image, ...FloorPlanPalette::hexToRgb($hex)) : null;
    }

    /** @param array $floorPlan Decoded FloorPlan contract (see contracts/floorplan.schema.json) */
    public function render(array $floorPlan, string $layout = 'auto', ?string $roomId = null, string $unit = UnitFormatter::METRIC, ?string $label = null): string
    {
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

        $isFused = $layout !== 'tiles' && $roomId === null && count($rooms) > 1 && array_reduce(
            $rooms,
            fn (bool $carry, array $room) => $carry && isset($room['structure_origin_m']),
            true
        );
        if ($isFused) {
            return $this->renderFused($rooms, $unit, $label, $notes);
        }

        $tiles = array_map([$this, 'tileGeometry'], $rooms);
        $notesLines = $this->buildNotesLines($rooms, $notes);

        $tilesWidth = self::MARGIN * 2 + array_sum(array_column($tiles, 'width'))
            + self::TILE_GAP * (count($tiles) - 1);
        $headerTextWidth = self::MARGIN * 2 + imagefontwidth(2) * strlen('Room shapes accurate individually; rooms are not laid out relative to each other.');
        if ($label !== null && $label !== '') {
            $headerTextWidth = max($headerTextWidth, self::MARGIN * 2 + imagefontwidth(2) * strlen($this->asciiSafe($label)));
        }
        $canvasWidth = max($tilesWidth, $headerTextWidth);
        $canvasHeight = self::MARGIN * 2 + self::LABEL_HEIGHT + (int) max(array_column($tiles, 'height'))
            + count($notesLines) * self::NOTE_LINE_HEIGHT;

        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Floor plan sheet would be %dx%d px, exceeding the %d px sanity bound — refusing to allocate it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $image = imagecreatetruecolor(max($canvasWidth, 400), $canvasHeight + 72);
        $white = imagecolorallocate($image, 255, 255, 255);
        $defaultFill = imagecolorallocate($image, 214, 231, 245);
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        $text = imagecolorallocate($image, 20, 20, 20);
        $subtext = imagecolorallocate($image, 90, 90, 90);
        $doorColor = imagecolorallocate($image, 210, 105, 30);
        $windowColor = imagecolorallocate($image, 70, 130, 180);
        $otherOpeningColor = imagecolorallocate($image, 120, 120, 120);
        $walkPathColor = imagecolorallocate($image, 150, 60, 190);
        $objectColor = imagecolorallocate($image, 96, 96, 96);
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $white);

        // GD's built-in bitmap fonts are Latin-1 only — stay ASCII to avoid
        // a raw UTF-8 em dash rendering as mojibake.
        imagestring($image, 5, self::MARGIN, 8, 'Vuuro Scan - indicative per-room floor plan sheet', $text);
        imagestring($image, 2, self::MARGIN, 26, 'Room shapes accurate individually; rooms are not laid out relative to each other.', $subtext);
        if ($label !== null && $label !== '') {
            imagestring($image, 2, self::MARGIN, 40, $this->asciiSafe($label), $subtext);
        }

        $totalAreaM2 = array_sum(array_column($rooms, 'floor_area_m2'));
        imagestring($image, 2, self::MARGIN, 54, sprintf('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms)), $subtext);

        $x = self::MARGIN;
        $y = self::MARGIN + self::LABEL_HEIGHT;
        foreach ($rooms as $i => $room) {
            $tile = $tiles[$i];
            $roomFill = $this->roomTypeFillColor($image, $room) ?? $defaultFill;
            $this->drawRoomTile($image, $room, $x, $y, $roomFill, $wallColor, $text, $subtext, $doorColor, $windowColor, $otherOpeningColor, $walkPathColor, $objectColor, $unit);
            $x += $tile['width'] + self::TILE_GAP;
        }

        $tilesBottomY = self::MARGIN + self::LABEL_HEIGHT + (int) max(array_column($tiles, 'height'));
        $this->drawNotes($image, $notesLines, $tilesBottomY + 10, $text);
        $this->drawRoomTypeLegend($image, $rooms, imagesy($image) - 28, $text);
        $this->drawFooter($image, $subtext);

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    /** @param array<int, array{room_id: ?string, text: string}> $notes */
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

        $lines = ['Notes:'];
        foreach ($rooms as $room) {
            foreach ($byRoom[$room['room_id']] ?? [] as $note) {
                foreach ($this->wrapTextLines($this->asciiSafe($note['text']), 95) as $i => $wrapped) {
                    $lines[] = $i === 0 ? "  [{$room['label']}] {$wrapped}" : '        ' . $wrapped;
                }
            }
        }
        foreach ($unitNotes as $note) {
            foreach ($this->wrapTextLines($this->asciiSafe($note['text']), 95) as $i => $wrapped) {
                $lines[] = $i === 0 ? "  [Whole unit] {$wrapped}" : '        ' . $wrapped;
            }
        }
        return count($lines) > 1 ? $lines : [];
    }

    /** @return string[] */
    private function wrapTextLines(string $text, int $maxChars): array
    {
        $wrapped = wordwrap($text, $maxChars, "\n", true);
        return $wrapped === '' ? [''] : explode("\n", $wrapped);
    }

    /** @param string[] $lines */
    private function drawNotes($image, array $lines, int $y, int $color): void
    {
        foreach ($lines as $line) {
            imagestring($image, self::FONT_SMALL, self::MARGIN, $y, $line, $color);
            $y += self::NOTE_LINE_HEIGHT;
        }
    }

    private function asciiSafe(string $s): string
    {
        return preg_replace('/[^\x20-\x7E]/', '-', $s) ?? $s;
    }

    private function drawFooter($image, int $color): void
    {
        $footerWidth = imagefontwidth(self::FONT_SMALL) * strlen(self::FOOTER_TEXT);
        imagestring($image, self::FONT_SMALL, (int) ((imagesx($image) - $footerWidth) / 2), imagesy($image) - 14, self::FOOTER_TEXT, $color);
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
        $notesLines = $this->buildNotesLines($rooms, $notes);

        $extraHeaderLines = ($overlapping !== [] ? 1 : 0) + (($label !== null && $label !== '') ? 1 : 0) + 1;
        $headerHeight = self::LABEL_HEIGHT + $extraHeaderLines * 16;
        $dimensionLineY = self::MARGIN + $headerHeight;
        $topGutter = $headerHeight + self::DIMENSION_GUTTER;
        $canvasWidth = self::MARGIN * 2 + self::DIMENSION_GUTTER + (int) round(($maxX - $minX) * self::PIXELS_PER_METER);
        $canvasHeight = self::MARGIN * 2 + $topGutter + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER)
            + count($notesLines) * self::NOTE_LINE_HEIGHT;
        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Fused floor plan would be %dx%d px, exceeding the %d px sanity bound — refusing to allocate it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $image = imagecreatetruecolor(max($canvasWidth, 400), $canvasHeight + 72);
        $white = imagecolorallocate($image, 255, 255, 255);
        $text = imagecolorallocate($image, 20, 20, 20);
        $subtext = imagecolorallocate($image, 90, 90, 90);
        $dimColor = imagecolorallocate($image, 130, 130, 130);
        $doorColor = imagecolorallocate($image, 210, 105, 30);
        $windowColor = imagecolorallocate($image, 70, 130, 180);
        $otherOpeningColor = imagecolorallocate($image, 120, 120, 120);
        $walkPathColor = imagecolorallocate($image, 150, 60, 190);
        $objectColor = imagecolorallocate($image, 96, 96, 96);
        $warnFill = imagecolorallocate($image, 250, 205, 205);
        $warnBorder = imagecolorallocate($image, 178, 30, 30);
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        $fallbackFills = array_map(
            fn (array $c) => imagecolorallocate($image, $c[0], $c[1], $c[2]),
            self::ROOM_PALETTE
        );
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $white);

        imagestring($image, 5, self::MARGIN, 8, 'Vuuro Scan - fused floor plan (rooms captured together in one visit)', $text);
        imagestring($image, 2, self::MARGIN, 26, 'Room positions relative to each other, not independently verified beyond this capture (see docs/proposals/multi-room-fusion.md).', $subtext);
        $headerLineY = 42;
        if ($overlapping !== []) {
            imagestring($image, 3, self::MARGIN, $headerLineY, 'WARNING: rooms below overlap in captured position - verify against the real layout before use.', $warnBorder);
            $headerLineY += 16;
        }
        if ($label !== null && $label !== '') {
            imagestring($image, 2, self::MARGIN, $headerLineY, $this->asciiSafe($label), $subtext);
            $headerLineY += 16;
        }
        $totalAreaM2 = array_sum(array_column($rooms, 'floor_area_m2'));
        imagestring($image, 2, self::MARGIN, $headerLineY, sprintf('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms)), $subtext);

        $originPxX = self::MARGIN + self::DIMENSION_GUTTER;
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
        $this->drawVerticalDimensionChain($image, $zBreakpoints, self::MARGIN + 14, $toPx, $unit, $dimColor);

        $edgeTiers = $fusion['edgeTiers'];

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
                $this->drawRoomWallShadow($image, $room['outline_m'], $pose, $toPx, $edgeTiers[$i] ?? []);
            }
        }
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            if (!in_array($i, $overlapping, true)) {
                $this->drawRoomWalls($image, $room['outline_m'], $pose, $toPx, $edgeTiers[$i] ?? [], $wallColor);
            }
        }

        $labelDraws = [];

        foreach ($rooms as $i => $room) {
            $this->drawWalkPath($image, $room, $poses[$i], $toPx, $walkPathColor);
        }
        foreach ($rooms as $i => $room) {
            $this->drawOpenings($image, $room, $poses[$i], $toPx, $doorColor, $windowColor, $otherOpeningColor, $text, $edgeTiers[$i] ?? [], $labelDraws);
            $this->drawObjects($image, $room, $poses[$i], $toPx, $objectColor, $text, $labelDraws);
        }

        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            [$labelX, $labelY] = $toPx($pose['originX'], $pose['originZ']);
            $labelDraws[] = fn () => imagestring($image, 3, $labelX + 4, $labelY + 4, $this->displayLabel($room), $text);
            $metrics = sprintf('%s - %s perimeter', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit));
            $labelDraws[] = fn () => imagestring($image, 2, $labelX + 4, $labelY + 20, $metrics, $subtext);
            $lineY = $labelY + 32;
            if (($room['height_m'] ?? null) !== null) {
                $heightText = sprintf('%s height', UnitFormatter::length($room['height_m'], $unit));
                $labelDraws[] = fn () => imagestring($image, 2, $labelX + 4, $lineY, $heightText, $subtext);
                $lineY += 12;
            }
            if (($room['volume_m3_indicative'] ?? null) !== null) {
                $volumeText = sprintf('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit));
                $labelDraws[] = fn () => imagestring($image, 2, $labelX + 4, $lineY, $volumeText, $subtext);
            }
        }

        foreach ($labelDraws as $draw) {
            $draw();
        }

        $drawingBottomY = $originPxY + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER);
        $this->drawNotes($image, $notesLines, $drawingBottomY + 10, $text);

        $legendY = imagesy($image) - 30;
        imagefilledellipse($image, self::MARGIN + 4, $legendY, 8, 8, $doorColor);
        imagestring($image, 1, self::MARGIN + 12, $legendY - 6, 'door', $text);
        imagefilledellipse($image, self::MARGIN + 60, $legendY, 8, 8, $windowColor);
        imagestring($image, 1, self::MARGIN + 68, $legendY - 6, 'window', $text);
        imagefilledellipse($image, self::MARGIN + 130, $legendY, 8, 8, $otherOpeningColor);
        imagestring($image, 1, self::MARGIN + 138, $legendY - 6, 'other opening', $text);
        imageline($image, self::MARGIN + 200, $legendY, self::MARGIN + 216, $legendY, $walkPathColor);
        imagestring($image, 1, self::MARGIN + 220, $legendY - 6, 'walk path', $text);
        imagerectangle($image, self::MARGIN + 270, $legendY - 4, self::MARGIN + 278, $legendY + 4, $objectColor);
        imagestring($image, 1, self::MARGIN + 284, $legendY - 6, 'detected object', $text);

        $this->drawRoomTypeLegend($image, $rooms, $legendY - 14, $text);
        $this->drawFooter($image, $subtext);

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    private function drawRoomTypeLegend($image, array $rooms, int $y, int $textColor): void
    {
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
            imagestring($image, self::FONT_SMALL, $x + 12, $y - 6, $label, $textColor);
            $x += 12 + imagefontwidth(self::FONT_SMALL) * strlen($label) + 16;
        }
    }

    private function displayLabel(array $room): string
    {
        $roomType = self::roomTypeValue($room);
        $typeName = $roomType !== null ? RoomType::labelFor($roomType) : null;
        return $typeName !== null ? sprintf('%s (%s)', $room['label'], $typeName) : $room['label'];
    }

    // Only a position is known (LIDAR-10's opening centroid) — no captured
    // swing direction or wall-gap width, so a door draws a fixed-size quarter-
    // arc "swing" and a window draws a fixed-size wall tick, both centered on
    // that position — stylized to Mark's Funda visual bar, not a fabricated
    // physical measurement.
    private function drawOpenings($image, array $room, array $pose, callable $toPx, int $doorColor, int $windowColor, int $otherOpeningColor, int $textColor, array $roomEdgeTiers, array &$labelDraws): void
    {
        $outline = $room['outline_m'] ?? [];
        $n = count($outline);
        $centroidX = $n > 0 ? array_sum(array_column($outline, 0)) / $n : 0.0;
        $centroidZ = $n > 0 ? array_sum(array_column($outline, 1)) / $n : 0.0;
        $wallColor = imagecolorallocate($image, ...self::WALL_COLOR);
        $white = imagecolorallocate($image, 255, 255, 255);

        foreach ($room['openings'] ?? [] as $opening) {
            [$mx, $mz] = $opening['position_m'];
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
            [$px, $py] = $toPx($wx, $wz);
            $category = $opening['category'];
            $color = match ($category) {
                'door' => $doorColor,
                'window' => $windowColor,
                default => $otherOpeningColor,
            };
            // The opening's position_m is a real captured point, but nothing
            // in the contract says which wall it sits on or which way it
            // faces — so the marker itself is aligned to the nearest edge of
            // this room's own outline_m, not drawn at a fixed orientation.
            // A fixed orientation looked right by accident on the fixtures
            // used so far (both openings happened to sit on a horizontal
            // wall) and was visibly wrong once tested on a vertical one.
            [$wallDx, $wallDz, $normalDx, $normalDz, $edgeIndex] = $this->nearestWallOrientation($outline, $mx, $mz, $centroidX, $centroidZ);
            $wallHalfM = $this->edgeThicknessM($roomEdgeTiers, $edgeIndex) / 2;
            $widthM = match ($category) {
                'door' => self::DOOR_LEAF_M,
                'window' => self::WINDOW_WIDTH_M,
                default => self::OPENING_WIDTH_M,
            };
            $half = $widthM / 2;
            $poseCos = cos($pose['rotationRad']);
            $poseSin = sin($pose['rotationRad']);
            [$wallDx, $wallDz] = [$wallDx * $poseCos - $wallDz * $poseSin, $wallDx * $poseSin + $wallDz * $poseCos];
            [$normalDx, $normalDz] = [$normalDx * $poseCos - $normalDz * $poseSin, $normalDx * $poseSin + $normalDz * $poseCos];

            $punchCorner = fn (float $alongSign, float $acrossSign): array => [
                $px + $wallDx * $alongSign * $half * self::PIXELS_PER_METER + $normalDx * $acrossSign * $wallHalfM * self::PIXELS_PER_METER,
                $py + $wallDz * $alongSign * $half * self::PIXELS_PER_METER + $normalDz * $acrossSign * $wallHalfM * self::PIXELS_PER_METER,
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
            } elseif ($category === 'window') {
                $half = self::WINDOW_TICK_LENGTH_M * self::PIXELS_PER_METER / 2;
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

            // Same problem the wall-length labels had: a fixed 6px nudge
            // used to land the category text right on top of the (now
            // thick, dark) wall line. Nudged toward the room's centroid
            // instead, onto the room's own fill color, using the same
            // dark/readable text color the rest of the labels use rather
            // than the opening's own marker color.
            [$labelMx, $labelMz] = $this->insetTowardCentroid($mx, $mz, $centroidX, $centroidZ, self::OPENING_LABEL_INSET_M);
            [$labelWx, $labelWz] = RoomFusionSolver::transformPoint($pose, $labelMx, $labelMz);
            [$labelX, $labelY] = $toPx($labelWx, $labelWz);
            $labelDraws[] = fn () => imagestring($image, self::FONT_SMALL, $labelX + 4, $labelY - 6, $category, $textColor);
        }
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
                return true;
            case 'stove':
            case 'oven':
                $rectFill($halfW, $halfD, $fixtureFill, $fixtureLine);
                $ellipse($halfW * 0.3, $halfD * 0.3, $fixtureLight, null);
                return true;
            case 'refrigerator':
            case 'dishwasher':
            case 'storage':
                $rectFill($halfW, $halfD, $fixtureFill, $fixtureLine);
                return true;
            case 'washerdryer':
            case 'washer_dryer':
                $rectFill($halfW, $halfD, $fixtureFill, $fixtureLine);
                $ellipse(min($halfW, $halfD) * 0.55, min($halfW, $halfD) * 0.55, $fixtureLight, $fixtureLine);
                return true;
            case 'bed':
                $bedFill = imagecolorallocate($image, ...FloorPlanPalette::hexToRgb(FloorPlanPalette::BED_FRAME_FILL));
                $rectFill($halfW, $halfD, $bedFill, $fixtureLine);
                $rectFill($halfW, $halfD * 0.22, $white, $fixtureLine);
                return true;
            case 'sofa':
                $rectFill($halfW, $halfD, $fixtureLight, $fixtureLine);
                return true;
            case 'table':
                $rectFill($halfW, $halfD, $white, $fixtureLine);
                return true;
            case 'fireplace':
                $rectFill($halfW, $halfD, $hearth, $fixtureLine);
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
        foreach ($room['objects'] ?? [] as $object) {
            [$mx, $mz] = $object['position_m'];
            $dims = $object['dimensions_m'] ?? [0.5, 0.0, 0.5];
            $halfWidth = ((float) ($dims[0] ?? 0.5)) / 2;
            $halfDepth = ((float) ($dims[2] ?? 0.5)) / 2;
            $category = strtolower((string) $object['category']);
            if ($this->drawObjectIcon($image, $pose, $toPx, $category, $mx, $mz, $halfWidth, $halfDepth)) {
                continue;
            }
            [$w1x, $w1z] = RoomFusionSolver::transformPoint($pose, $mx - $halfWidth, $mz - $halfDepth);
            [$x1, $y1] = $toPx($w1x, $w1z);
            [$w2x, $w2z] = RoomFusionSolver::transformPoint($pose, $mx + $halfWidth, $mz + $halfDepth);
            [$x2, $y2] = $toPx($w2x, $w2z);
            imagerectangle($image, $x1, $y1, $x2, $y2, $color);
            $categoryLabel = $this->asciiSafe($object['category']);
            $labelDraws[] = fn () => imagestring($image, self::FONT_SMALL, min($x1, $x2) + 2, min($y1, $y2) - 10, $categoryLabel, $textColor);
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

    /**
     * Finds the outline edge closest to (x, z) and returns its unit
     * direction vector plus the unit normal perpendicular to it, flipped to
     * point toward the room's centroid (i.e. inward, into the room).
     *
     * @return array{0: float, 1: float, 2: float, 3: float}
     */
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
        return [$wallDx, $wallDz, $normalDx, $normalDz, $bestEdgeIndex];
    }

    /** @return array{0: float, 1: float} */
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
            if ($breakpoints === [] || $v - end($breakpoints) > 0.05) {
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
            imageline($image, $x1, $y, $x2, $y, $color);
            imageline($image, $x1, $y - 4, $x1, $y + 4, $color);
            imageline($image, $x2, $y - 4, $x2, $y + 4, $color);
            $label = UnitFormatter::length($spanM, $unit);
            imagestring($image, 1, (int) (($x1 + $x2) / 2) - 12, $y - 12, $label, $color);
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
            imageline($image, $x, $y1, $x, $y2, $color);
            imageline($image, $x - 4, $y1, $x + 4, $y1, $color);
            imageline($image, $x - 4, $y2, $x + 4, $y2, $color);
            $label = UnitFormatter::length($spanM, $unit);
            imagestringup($image, 1, $x - 14, (int) (($y1 + $y2) / 2) + 20, $label, $color);
        }
    }

    // Each polygon edge labeled with its own real-world length, at its
    // midpoint — nudged inward toward the room's centroid by
    // WALL_LABEL_INSET_M so the text lands on the room's own fill color
    // instead of sitting directly on top of the (now much thicker,
    // dark-colored) wall line it would otherwise be unreadable against.
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
                continue; // too short to label without the text overlapping itself
            }
            $midX = ($ax + $bx) / 2;
            $midZ = ($az + $bz) / 2;
            [$midX, $midZ] = $this->insetTowardCentroid($midX, $midZ, $centroidX, $centroidZ, self::WALL_LABEL_INSET_M);
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $midX, $midZ);
            [$px, $py] = $toPx($wx, $wz);
            imagestring($image, 1, $px - 10, $py - 5, UnitFormatter::length($lengthM, $unit), $color);
        }
    }

    /** @return array{width: int, height: int} */
    private function tileGeometry(array $room): array
    {
        $width = (int) round($room['bounding_dimensions_m']['width_m'] * self::PIXELS_PER_METER) + self::TILE_PADDING * 2;
        $height = (int) round($room['bounding_dimensions_m']['length_m'] * self::PIXELS_PER_METER) + self::TILE_PADDING * 2 + self::LABEL_HEIGHT;
        return ['width' => max($width, 120), 'height' => max($height, 120)];
    }

    private function drawRoomTile($image, array $room, int $originX, int $originY, int $fill, int $wallColor, int $text, int $subtext, int $doorColor, int $windowColor, int $otherOpeningColor, int $walkPathColor, int $objectColor, string $unit = UnitFormatter::METRIC): void
    {
        $points = [];
        foreach ($room['outline_m'] as [$mx, $mz]) {
            $points[] = $originX + self::TILE_PADDING + (int) round($mx * self::PIXELS_PER_METER);
            $points[] = $originY + self::TILE_PADDING + (int) round($mz * self::PIXELS_PER_METER);
        }

        // PHP 8.1+ infers point count from $points and deprecates passing
        // it explicitly, so the old $num_points argument is dropped here.
        imagefilledpolygon($image, $points, $fill);
        $tileToPx = fn (float $mx, float $mz): array => [
            $originX + self::TILE_PADDING + (int) round($mx * self::PIXELS_PER_METER),
            $originY + self::TILE_PADDING + (int) round($mz * self::PIXELS_PER_METER),
        ];
        $identityPose = ['originX' => 0.0, 'originZ' => 0.0, 'rotationRad' => 0.0];
        $labelDraws = [];
        $this->drawRoomWallShadow($image, $room['outline_m'], $identityPose, $tileToPx, []);
        $this->drawRoomWalls($image, $room['outline_m'], $identityPose, $tileToPx, [], $wallColor);
        $this->drawWalkPath($image, $room, $identityPose, $tileToPx, $walkPathColor);
        $this->drawOpenings($image, $room, $identityPose, $tileToPx, $doorColor, $windowColor, $otherOpeningColor, $text, [], $labelDraws);
        $this->drawObjects($image, $room, $identityPose, $tileToPx, $objectColor, $text, $labelDraws);
        $this->drawWallLengths($image, $room['outline_m'], $identityPose, $tileToPx, $subtext, $unit, []);
        foreach ($labelDraws as $draw) {
            $draw();
        }

        $labelY = $originY + self::TILE_PADDING + (int) round($room['bounding_dimensions_m']['length_m'] * self::PIXELS_PER_METER) + 8;
        imagestring($image, 4, $originX + self::TILE_PADDING, $labelY, $this->displayLabel($room), $text);
        // ASCII only — GD's built-in bitmap fonts are Latin-1, so raw UTF-8
        // (m-superscript-2, middot) renders as mojibake.
        $metrics = sprintf('%s - %s perimeter - %s confidence', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit), $room['confidence']);
        imagestring($image, 2, $originX + self::TILE_PADDING, $labelY + 18, $metrics, $subtext);
        $lineY = $labelY + 32;
        if (($room['height_m'] ?? null) !== null) {
            imagestring($image, 2, $originX + self::TILE_PADDING, $lineY, sprintf('%s height', UnitFormatter::length($room['height_m'], $unit)), $subtext);
            $lineY += 12;
        }
        if (($room['volume_m3_indicative'] ?? null) !== null) {
            imagestring($image, 2, $originX + self::TILE_PADDING, $lineY, sprintf('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit)), $subtext);
        }
    }
}
