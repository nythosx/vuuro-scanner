<?php

declare(strict_types=1);

namespace VuuroScan\Export;

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

    /** @param array $floorPlan Decoded FloorPlan contract (see contracts/floorplan.schema.json) */
    public function render(array $floorPlan, string $layout = 'auto', ?string $roomId = null): string
    {
        $rooms = $floorPlan['rooms'];
        if ($roomId !== null) {
            $rooms = array_values(array_filter($rooms, static fn (array $room) => $room['room_id'] === $roomId));
            if ($rooms === []) {
                throw new \InvalidArgumentException("No room with room_id '{$roomId}' in this floor plan.");
            }
        }
        if ($rooms === []) {
            throw new \InvalidArgumentException('Cannot render a floor plan sheet with zero rooms.');
        }

        $isFused = $layout !== 'tiles' && $roomId === null && count($rooms) > 1 && array_reduce(
            $rooms,
            fn (bool $carry, array $room) => $carry && isset($room['structure_origin_m']),
            true
        );
        if ($isFused) {
            return $this->renderFused($rooms);
        }

        $tiles = array_map([$this, 'tileGeometry'], $rooms);

        $canvasWidth = self::MARGIN * 2 + array_sum(array_column($tiles, 'width'))
            + self::TILE_GAP * (count($tiles) - 1);
        $canvasHeight = self::MARGIN * 2 + self::LABEL_HEIGHT + (int) max(array_column($tiles, 'height'));

        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Floor plan sheet would be %dx%d px, exceeding the %d px sanity bound — refusing to allocate it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $image = imagecreatetruecolor(max($canvasWidth, 400), $canvasHeight + 40);
        $white = imagecolorallocate($image, 255, 255, 255);
        $roomFill = imagecolorallocate($image, 214, 231, 245);
        $roomBorder = imagecolorallocate($image, 30, 64, 110);
        $text = imagecolorallocate($image, 20, 20, 20);
        $subtext = imagecolorallocate($image, 90, 90, 90);
        $doorColor = imagecolorallocate($image, 210, 105, 30);
        $windowColor = imagecolorallocate($image, 70, 130, 180);
        $otherOpeningColor = imagecolorallocate($image, 120, 120, 120);
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $white);

        // GD's built-in bitmap fonts are Latin-1 only — stay ASCII to avoid
        // a raw UTF-8 em dash rendering as mojibake.
        imagestring($image, 5, self::MARGIN, 8, 'Vuuro Scan - indicative per-room floor plan sheet', $text);
        imagestring($image, 2, self::MARGIN, 26, 'Room shapes accurate individually; rooms are not laid out relative to each other (see ADR 0002).', $subtext);

        $x = self::MARGIN;
        $y = self::MARGIN + self::LABEL_HEIGHT;
        foreach ($rooms as $i => $room) {
            $tile = $tiles[$i];
            $this->drawRoomTile($image, $room, $x, $y, $roomFill, $roomBorder, $text, $subtext, $doorColor, $windowColor, $otherOpeningColor);
            $x += $tile['width'] + self::TILE_GAP;
        }

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    private function renderFused(array $rooms): string
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

        $topGutter = self::LABEL_HEIGHT + self::DIMENSION_GUTTER + ($overlapping !== [] ? 16 : 0);
        $canvasWidth = self::MARGIN * 2 + self::DIMENSION_GUTTER + (int) round(($maxX - $minX) * self::PIXELS_PER_METER);
        $canvasHeight = self::MARGIN * 2 + $topGutter + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER);
        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Fused floor plan would be %dx%d px, exceeding the %d px sanity bound — refusing to allocate it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $image = imagecreatetruecolor(max($canvasWidth, 400), $canvasHeight + 40);
        $white = imagecolorallocate($image, 255, 255, 255);
        $text = imagecolorallocate($image, 20, 20, 20);
        $subtext = imagecolorallocate($image, 90, 90, 90);
        $dimColor = imagecolorallocate($image, 130, 130, 130);
        $doorColor = imagecolorallocate($image, 210, 105, 30);
        $windowColor = imagecolorallocate($image, 70, 130, 180);
        $otherOpeningColor = imagecolorallocate($image, 120, 120, 120);
        $warnFill = imagecolorallocate($image, 250, 205, 205);
        $warnBorder = imagecolorallocate($image, 178, 30, 30);
        $palette = array_map(
            fn (array $c) => [
                imagecolorallocate($image, $c[0], $c[1], $c[2]),
                imagecolorallocate($image, $c[3], $c[4], $c[5]),
            ],
            self::ROOM_PALETTE
        );
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $white);

        imagestring($image, 5, self::MARGIN, 8, 'Vuuro Scan - fused floor plan (rooms captured together in one visit)', $text);
        imagestring($image, 2, self::MARGIN, 26, 'Room positions relative to each other, not independently verified beyond this capture (see docs/proposals/multi-room-fusion.md).', $subtext);
        if ($overlapping !== []) {
            imagestring($image, 3, self::MARGIN, 42, 'WARNING: rooms below overlap in captured position - verify against the real layout before use.', $warnBorder);
        }

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
            self::MARGIN + self::LABEL_HEIGHT,
            $originPxX + (int) round(($maxX - $minX) * self::PIXELS_PER_METER),
            self::MARGIN + self::LABEL_HEIGHT,
            sprintf('%.2f m', $maxX - $minX),
            $dimColor,
            true
        );
        $this->drawDimensionLine(
            $image,
            self::MARGIN,
            $originPxY,
            self::MARGIN,
            $originPxY + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER),
            sprintf('%.2f m', $maxZ - $minZ),
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
                [$roomFill, $roomBorder] = $palette[$i % count($palette)];
            }
            imagefilledpolygon($image, $points, $roomFill);
            imagepolygon($image, $points, $roomBorder);
            $this->drawWallLengths($image, $outline, $originX, $originZ, $toPx, $subtext);

            [$labelX, $labelY] = $toPx($originX, $originZ);
            imagestring($image, 3, $labelX + 4, $labelY + 4, $room['label'], $text);
            $metrics = sprintf('%.2f sqm - %.2f m perimeter', $room['floor_area_m2'], $room['perimeter_m']);
            imagestring($image, 2, $labelX + 4, $labelY + 20, $metrics, $subtext);
            $lineY = $labelY + 32;
            if (($room['height_m'] ?? null) !== null) {
                imagestring($image, 2, $labelX + 4, $lineY, sprintf('%.2f m height', $room['height_m']), $subtext);
                $lineY += 12;
            }
            if (($room['volume_m3_indicative'] ?? null) !== null) {
                imagestring($image, 2, $labelX + 4, $lineY, sprintf('%.2f m3 indicative', $room['volume_m3_indicative']), $subtext);
            }
        }

        foreach ($rooms as $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $this->drawOpenings($image, $room, $originX, $originZ, $toPx, $doorColor, $windowColor, $otherOpeningColor);
        }

        $legendY = imagesy($image) - 16;
        imagefilledellipse($image, self::MARGIN + 4, $legendY, 8, 8, $doorColor);
        imagestring($image, 1, self::MARGIN + 12, $legendY - 6, 'door', $text);
        imagefilledellipse($image, self::MARGIN + 60, $legendY, 8, 8, $windowColor);
        imagestring($image, 1, self::MARGIN + 68, $legendY - 6, 'window', $text);
        imagefilledellipse($image, self::MARGIN + 130, $legendY, 8, 8, $otherOpeningColor);
        imagestring($image, 1, self::MARGIN + 138, $legendY - 6, 'other opening', $text);

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    // Only a position is known (LIDAR-10's opening centroid) — no fabricated wall-gap width or swing.
    private function drawOpenings($image, array $room, float $originX, float $originZ, callable $toPx, int $doorColor, int $windowColor, int $otherOpeningColor): void
    {
        foreach ($room['openings'] ?? [] as $opening) {
            [$mx, $mz] = $opening['position_m'];
            [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
            $color = match ($opening['category']) {
                'door' => $doorColor,
                'window' => $windowColor,
                default => $otherOpeningColor,
            };
            imagefilledellipse($image, $px, $py, 10, 10, $color);
            imagestring($image, 1, $px + 6, $py - 6, $opening['category'], $color);
        }
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

    // Each polygon edge labeled with its own real-world length, at its midpoint.
    private function drawWallLengths($image, array $outlineM, float $originX, float $originZ, callable $toPx, int $color): void
    {
        $n = count($outlineM);
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $lengthM = sqrt(($bx - $ax) ** 2 + ($bz - $az) ** 2);
            if ($lengthM < 0.3) {
                continue; // too short to label without the text overlapping itself
            }
            $midX = ($ax + $bx) / 2 + $originX;
            $midZ = ($az + $bz) / 2 + $originZ;
            [$px, $py] = $toPx($midX, $midZ);
            imagestring($image, 1, $px - 10, $py - 5, sprintf('%.2fm', $lengthM), $color);
        }
    }

    /** @return array{width: int, height: int} */
    private function tileGeometry(array $room): array
    {
        $width = (int) round($room['bounding_dimensions_m']['width_m'] * self::PIXELS_PER_METER) + self::TILE_PADDING * 2;
        $height = (int) round($room['bounding_dimensions_m']['length_m'] * self::PIXELS_PER_METER) + self::TILE_PADDING * 2 + self::LABEL_HEIGHT;
        return ['width' => max($width, 120), 'height' => max($height, 120)];
    }

    private function drawRoomTile($image, array $room, int $originX, int $originY, int $fill, int $border, int $text, int $subtext, int $doorColor, int $windowColor, int $otherOpeningColor): void
    {
        $points = [];
        foreach ($room['outline_m'] as [$mx, $mz]) {
            $points[] = $originX + self::TILE_PADDING + (int) round($mx * self::PIXELS_PER_METER);
            $points[] = $originY + self::TILE_PADDING + (int) round($mz * self::PIXELS_PER_METER);
        }

        // PHP 8.1+ infers point count from $points and deprecates passing
        // it explicitly, so the old $num_points argument is dropped here.
        imagefilledpolygon($image, $points, $fill);
        imagepolygon($image, $points, $border);
        $tileToPx = fn (float $mx, float $mz): array => [
            $originX + self::TILE_PADDING + (int) round($mx * self::PIXELS_PER_METER),
            $originY + self::TILE_PADDING + (int) round($mz * self::PIXELS_PER_METER),
        ];
        $this->drawWallLengths($image, $room['outline_m'], 0.0, 0.0, $tileToPx, $subtext);
        $this->drawOpenings($image, $room, 0.0, 0.0, $tileToPx, $doorColor, $windowColor, $otherOpeningColor);

        $labelY = $originY + self::TILE_PADDING + (int) round($room['bounding_dimensions_m']['length_m'] * self::PIXELS_PER_METER) + 8;
        imagestring($image, 4, $originX + self::TILE_PADDING, $labelY, $room['label'], $text);
        // ASCII only — GD's built-in bitmap fonts are Latin-1, so raw UTF-8
        // (m-superscript-2, middot) renders as mojibake.
        $metrics = sprintf('%.2f sqm - %.2f m perimeter - %s confidence', $room['floor_area_m2'], $room['perimeter_m'], $room['confidence']);
        imagestring($image, 2, $originX + self::TILE_PADDING, $labelY + 18, $metrics, $subtext);
        $lineY = $labelY + 32;
        if (($room['height_m'] ?? null) !== null) {
            imagestring($image, 2, $originX + self::TILE_PADDING, $lineY, sprintf('%.2f m height', $room['height_m']), $subtext);
            $lineY += 12;
        }
        if (($room['volume_m3_indicative'] ?? null) !== null) {
            imagestring($image, 2, $originX + self::TILE_PADDING, $lineY, sprintf('%.2f m3 indicative', $room['volume_m3_indicative']), $subtext);
        }
    }
}
