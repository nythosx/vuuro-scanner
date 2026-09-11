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
    // Funda-style semantic room coloring (Mark's 2026-09-03 visual bar) —
    // only used when a room carries a room_type guess; unknown/no-guess
    // rooms keep cycling through ROOM_PALETTE by index, same as before.
    private const ROOM_TYPE_PALETTE = [
        'kitchen' => [199, 236, 239, 28, 59, 63],
        'living_room' => [251, 215, 174, 92, 61, 24],
        'bedroom' => [199, 194, 224, 44, 38, 80],
        'bathroom' => [214, 224, 194, 61, 80, 38],
        'dining_room' => [246, 221, 142, 90, 74, 16],
    ];
    private const WALL_THICKNESS_PX = 3;
    private const DEFAULT_LINE_THICKNESS_PX = 1;
    private const FONT_SMALL = 1;
    private const NOTE_LINE_HEIGHT = 13;
    private const DOOR_SWING_RADIUS_M = 0.8;
    private const WINDOW_TICK_LENGTH_M = 0.5;
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
        $defaultBorder = imagecolorallocate($image, 30, 64, 110);
        $text = imagecolorallocate($image, 20, 20, 20);
        $subtext = imagecolorallocate($image, 90, 90, 90);
        $doorColor = imagecolorallocate($image, 210, 105, 30);
        $windowColor = imagecolorallocate($image, 70, 130, 180);
        $otherOpeningColor = imagecolorallocate($image, 120, 120, 120);
        $walkPathColor = imagecolorallocate($image, 150, 60, 190);
        $objectColor = imagecolorallocate($image, 96, 96, 96);
        $typePalette = [];
        foreach (self::ROOM_TYPE_PALETTE as $type => $c) {
            $typePalette[$type] = [
                imagecolorallocate($image, $c[0], $c[1], $c[2]),
                imagecolorallocate($image, $c[3], $c[4], $c[5]),
            ];
        }
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
            $roomTypeValue = self::roomTypeValue($room);
            [$roomFill, $roomBorder] = $typePalette[$roomTypeValue] ?? [$defaultFill, $defaultBorder];
            $this->drawRoomTile($image, $room, $x, $y, $roomFill, $roomBorder, $text, $subtext, $doorColor, $windowColor, $otherOpeningColor, $walkPathColor, $objectColor, $unit);
            $x += $tile['width'] + self::TILE_GAP;
        }

        $tilesBottomY = self::MARGIN + self::LABEL_HEIGHT + (int) max(array_column($tiles, 'height'));
        $this->drawNotes($image, $notesLines, $tilesBottomY + 10, $text);
        $this->drawRoomTypeLegend($image, $rooms, $typePalette, imagesy($image) - 28, $text);
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
        foreach ($rooms as $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                $worldX = $mx + $originX;
                $worldZ = $mz + $originZ;
                $minX = min($minX, $worldX);
                $minZ = min($minZ, $worldZ);
                $maxX = max($maxX, $worldX);
                $maxZ = max($maxZ, $worldZ);
            }
        }
        $overlapping = FusionOverlapDetector::detect($rooms);
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
        $palette = array_map(
            fn (array $c) => [
                imagecolorallocate($image, $c[0], $c[1], $c[2]),
                imagecolorallocate($image, $c[3], $c[4], $c[5]),
            ],
            self::ROOM_PALETTE
        );
        $typePalette = [];
        foreach (self::ROOM_TYPE_PALETTE as $type => $c) {
            $typePalette[$type] = [
                imagecolorallocate($image, $c[0], $c[1], $c[2]),
                imagecolorallocate($image, $c[3], $c[4], $c[5]),
            ];
        }
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

        $this->drawDimensionLine(
            $image,
            $originPxX,
            $dimensionLineY,
            $originPxX + (int) round(($maxX - $minX) * self::PIXELS_PER_METER),
            $dimensionLineY,
            UnitFormatter::length($maxX - $minX, $unit),
            $dimColor,
            true
        );
        $this->drawDimensionLine(
            $image,
            self::MARGIN,
            $originPxY,
            self::MARGIN,
            $originPxY + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER),
            UnitFormatter::length($maxZ - $minZ, $unit),
            $dimColor,
            false
        );

        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $outline = $room['outline_m'];
            $points = [];
            foreach ($outline as [$mx, $mz]) {
                [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
                $points[] = $px;
                $points[] = $py;
            }
            if (in_array($i, $overlapping, true)) {
                [$roomFill, $roomBorder] = [$warnFill, $warnBorder];
            } else {
                $roomTypeValue = self::roomTypeValue($room);
                [$roomFill, $roomBorder] = $typePalette[$roomTypeValue] ?? $palette[$i % count($palette)];
            }
            imagefilledpolygon($image, $points, $roomFill);
            imagesetthickness($image, self::WALL_THICKNESS_PX);
            imagepolygon($image, $points, $roomBorder);
            imagesetthickness($image, self::DEFAULT_LINE_THICKNESS_PX);
            $this->drawWallLengths($image, $outline, $originX, $originZ, $toPx, $subtext, $unit);

            [$labelX, $labelY] = $toPx($originX, $originZ);
            imagestring($image, 3, $labelX + 4, $labelY + 4, $this->displayLabel($room), $text);
            $metrics = sprintf('%s - %s perimeter', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit));
            imagestring($image, 2, $labelX + 4, $labelY + 20, $metrics, $subtext);
            $lineY = $labelY + 32;
            if (($room['height_m'] ?? null) !== null) {
                imagestring($image, 2, $labelX + 4, $lineY, sprintf('%s height', UnitFormatter::length($room['height_m'], $unit)), $subtext);
                $lineY += 12;
            }
            if (($room['volume_m3_indicative'] ?? null) !== null) {
                imagestring($image, 2, $labelX + 4, $lineY, sprintf('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit)), $subtext);
            }
        }

        foreach ($rooms as $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $this->drawWalkPath($image, $room, $originX, $originZ, $toPx, $walkPathColor);
        }
        foreach ($rooms as $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $this->drawOpenings($image, $room, $originX, $originZ, $toPx, $doorColor, $windowColor, $otherOpeningColor, $text);
            $this->drawObjects($image, $room, $originX, $originZ, $toPx, $objectColor, $text);
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

        $this->drawRoomTypeLegend($image, $rooms, $typePalette, $legendY - 14, $text);
        $this->drawFooter($image, $subtext);

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    private function drawRoomTypeLegend($image, array $rooms, array $typePalette, int $y, int $textColor): void
    {
        $typesPresent = [];
        foreach ($rooms as $room) {
            $type = self::roomTypeValue($room);
            if ($type !== null && isset($typePalette[$type]) && !in_array($type, $typesPresent, true)) {
                $typesPresent[] = $type;
            }
        }
        if ($typesPresent === []) {
            return;
        }
        $x = self::MARGIN;
        foreach ($typesPresent as $type) {
            [$fill, ] = $typePalette[$type];
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
    private function drawOpenings($image, array $room, float $originX, float $originZ, callable $toPx, int $doorColor, int $windowColor, int $otherOpeningColor, int $textColor): void
    {
        $outline = $room['outline_m'] ?? [];
        $n = count($outline);
        $centroidX = $n > 0 ? array_sum(array_column($outline, 0)) / $n : 0.0;
        $centroidZ = $n > 0 ? array_sum(array_column($outline, 1)) / $n : 0.0;

        foreach ($room['openings'] ?? [] as $opening) {
            [$mx, $mz] = $opening['position_m'];
            [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
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
            [$wallDx, $wallDz, $normalDx, $normalDz] = $this->nearestWallOrientation($outline, $mx, $mz, $centroidX, $centroidZ);
            if ($category === 'door') {
                $radius = self::DOOR_SWING_RADIUS_M * self::PIXELS_PER_METER;
                $steps = 8;
                $prevX = $px + $wallDx * $radius;
                $prevY = $py + $wallDz * $radius;
                imageline($image, $px, $py, (int) round($prevX), (int) round($prevY), $color);
                for ($step = 1; $step <= $steps; $step++) {
                    $t = (M_PI / 2) * ($step / $steps);
                    $curX = $px + $radius * (cos($t) * $wallDx + sin($t) * $normalDx);
                    $curY = $py + $radius * (cos($t) * $wallDz + sin($t) * $normalDz);
                    imageline($image, (int) round($prevX), (int) round($prevY), (int) round($curX), (int) round($curY), $color);
                    $prevX = $curX;
                    $prevY = $curY;
                }
                imageline($image, $px, $py, (int) round($prevX), (int) round($prevY), $color);
            } elseif ($category === 'window') {
                $half = self::WINDOW_TICK_LENGTH_M * self::PIXELS_PER_METER / 2;
                imagesetthickness($image, self::WALL_THICKNESS_PX);
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
            }

            // Same problem the wall-length labels had: a fixed 6px nudge
            // used to land the category text right on top of the (now
            // thick, dark) wall line. Nudged toward the room's centroid
            // instead, onto the room's own fill color, using the same
            // dark/readable text color the rest of the labels use rather
            // than the opening's own marker color.
            [$labelMx, $labelMz] = $this->insetTowardCentroid($mx, $mz, $centroidX, $centroidZ, self::OPENING_LABEL_INSET_M);
            [$labelX, $labelY] = $toPx($labelMx + $originX, $labelMz + $originZ);
            imagestring($image, self::FONT_SMALL, $labelX + 4, $labelY - 6, $category, $textColor);
        }
    }

    private function drawWalkPath($image, array $room, float $originX, float $originZ, callable $toPx, int $color): void
    {
        $points = $room['walk_path_m'] ?? [];
        if (count($points) < 2) {
            return;
        }
        for ($i = 0; $i < count($points) - 1; $i++) {
            [$ax, $az] = $points[$i];
            [$bx, $bz] = $points[$i + 1];
            [$apx, $apy] = $toPx($ax + $originX, $az + $originZ);
            [$bpx, $bpy] = $toPx($bx + $originX, $bz + $originZ);
            $this->drawDashedSegment($image, $apx, $apy, $bpx, $bpy, $color);
        }
    }

    private function drawObjects($image, array $room, float $originX, float $originZ, callable $toPx, int $color, int $textColor): void
    {
        foreach ($room['objects'] ?? [] as $object) {
            [$mx, $mz] = $object['position_m'];
            $dims = $object['dimensions_m'] ?? [0.5, 0.0, 0.5];
            $halfWidth = ((float) ($dims[0] ?? 0.5)) / 2;
            $halfDepth = ((float) ($dims[2] ?? 0.5)) / 2;
            [$x1, $y1] = $toPx($mx - $halfWidth + $originX, $mz - $halfDepth + $originZ);
            [$x2, $y2] = $toPx($mx + $halfWidth + $originX, $mz + $halfDepth + $originZ);
            imagerectangle($image, $x1, $y1, $x2, $y2, $color);
            imagestring($image, self::FONT_SMALL, min($x1, $x2) + 2, min($y1, $y2) - 10, $this->asciiSafe($object['category']), $textColor);
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
        return [$wallDx, $wallDz, $normalDx, $normalDz];
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

    private function drawDimensionLine($image, int $x1, int $y1, int $x2, int $y2, string $label, int $color, bool $horizontal): void
    {
        imageline($image, $x1, $y1, $x2, $y2, $color);
        if ($horizontal) {
            imageline($image, $x1, $y1 - 4, $x1, $y1 + 4, $color);
            imageline($image, $x2, $y2 - 4, $x2, $y2 + 4, $color);
            imagestring($image, 1, (int) (($x1 + $x2) / 2) - 12, $y1 - 12, $label, $color);
        } else {
            imageline($image, $x1 - 4, $y1, $x1 + 4, $y1, $color);
            imageline($image, $x2 - 4, $y2, $x2 + 4, $y2, $color);
            imagestringup($image, 1, $x1 - 14, (int) (($y1 + $y2) / 2) + 20, $label, $color);
        }
    }

    // Each polygon edge labeled with its own real-world length, at its
    // midpoint — nudged inward toward the room's centroid by
    // WALL_LABEL_INSET_M so the text lands on the room's own fill color
    // instead of sitting directly on top of the (now much thicker,
    // dark-colored) wall line it would otherwise be unreadable against.
    private function drawWallLengths($image, array $outlineM, float $originX, float $originZ, callable $toPx, int $color, string $unit = UnitFormatter::METRIC): void
    {
        $n = count($outlineM);
        if ($n === 0) {
            return;
        }
        $centroidX = array_sum(array_column($outlineM, 0)) / $n;
        $centroidZ = array_sum(array_column($outlineM, 1)) / $n;
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $lengthM = sqrt(($bx - $ax) ** 2 + ($bz - $az) ** 2);
            if ($lengthM < 0.3) {
                continue; // too short to label without the text overlapping itself
            }
            $midX = ($ax + $bx) / 2;
            $midZ = ($az + $bz) / 2;
            [$midX, $midZ] = $this->insetTowardCentroid($midX, $midZ, $centroidX, $centroidZ, self::WALL_LABEL_INSET_M);
            [$px, $py] = $toPx($midX + $originX, $midZ + $originZ);
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

    private function drawRoomTile($image, array $room, int $originX, int $originY, int $fill, int $border, int $text, int $subtext, int $doorColor, int $windowColor, int $otherOpeningColor, int $walkPathColor, int $objectColor, string $unit = UnitFormatter::METRIC): void
    {
        $points = [];
        foreach ($room['outline_m'] as [$mx, $mz]) {
            $points[] = $originX + self::TILE_PADDING + (int) round($mx * self::PIXELS_PER_METER);
            $points[] = $originY + self::TILE_PADDING + (int) round($mz * self::PIXELS_PER_METER);
        }

        // PHP 8.1+ infers point count from $points and deprecates passing
        // it explicitly, so the old $num_points argument is dropped here.
        imagefilledpolygon($image, $points, $fill);
        imagesetthickness($image, self::WALL_THICKNESS_PX);
        imagepolygon($image, $points, $border);
        imagesetthickness($image, self::DEFAULT_LINE_THICKNESS_PX);
        $tileToPx = fn (float $mx, float $mz): array => [
            $originX + self::TILE_PADDING + (int) round($mx * self::PIXELS_PER_METER),
            $originY + self::TILE_PADDING + (int) round($mz * self::PIXELS_PER_METER),
        ];
        $this->drawWallLengths($image, $room['outline_m'], 0.0, 0.0, $tileToPx, $subtext, $unit);
        $this->drawWalkPath($image, $room, 0.0, 0.0, $tileToPx, $walkPathColor);
        $this->drawOpenings($image, $room, 0.0, 0.0, $tileToPx, $doorColor, $windowColor, $otherOpeningColor, $text);
        $this->drawObjects($image, $room, 0.0, 0.0, $tileToPx, $objectColor, $text);

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
