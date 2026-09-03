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
    // Defense-in-depth: RoomPlanSimulatorAdapter already bounds coordinate
    // magnitude before this ever runs, but this renderer shouldn't rely
    // solely on an upstream caller getting that right.
    private const MAX_CANVAS_DIMENSION_PX = 4000;

    /** @param array $floorPlan Decoded FloorPlan contract (see contracts/floorplan.schema.json) */
    public function render(array $floorPlan): string
    {
        $rooms = $floorPlan['rooms'];
        if ($rooms === []) {
            throw new \InvalidArgumentException('Cannot render a floor plan sheet with zero rooms.');
        }

        $isFused = count($rooms) > 1 && array_reduce(
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
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $white);

        // GD's built-in bitmap fonts are Latin-1 only — stay ASCII to avoid
        // a raw UTF-8 em dash rendering as mojibake.
        imagestring($image, 5, self::MARGIN, 8, 'Vuuro Scan - indicative per-room floor plan sheet', $text);
        imagestring($image, 2, self::MARGIN, 26, 'Room shapes accurate individually; rooms are not laid out relative to each other (see ADR 0002).', $subtext);

        $x = self::MARGIN;
        $y = self::MARGIN + self::LABEL_HEIGHT;
        foreach ($rooms as $i => $room) {
            $tile = $tiles[$i];
            $this->drawRoomTile($image, $room, $x, $y, $roomFill, $roomBorder, $text, $subtext);
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

        $canvasWidth = self::MARGIN * 2 + (int) round(($maxX - $minX) * self::PIXELS_PER_METER);
        $canvasHeight = self::MARGIN * 2 + self::LABEL_HEIGHT + (int) round(($maxZ - $minZ) * self::PIXELS_PER_METER);
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
        $roomFill = imagecolorallocate($image, 214, 231, 245);
        $roomBorder = imagecolorallocate($image, 30, 64, 110);
        $text = imagecolorallocate($image, 20, 20, 20);
        $subtext = imagecolorallocate($image, 90, 90, 90);
        $doorColor = imagecolorallocate($image, 210, 105, 30);
        $windowColor = imagecolorallocate($image, 70, 130, 180);
        imagefilledrectangle($image, 0, 0, imagesx($image), imagesy($image), $white);

        imagestring($image, 5, self::MARGIN, 8, 'Vuuro Scan - fused floor plan (rooms captured together in one visit)', $text);
        imagestring($image, 2, self::MARGIN, 26, 'Room positions relative to each other, not independently verified beyond this capture (see docs/proposals/multi-room-fusion.md).', $subtext);

        $toPx = function (float $worldX, float $worldZ) use ($minX, $minZ): array {
            return [
                self::MARGIN + (int) round(($worldX - $minX) * self::PIXELS_PER_METER),
                self::MARGIN + self::LABEL_HEIGHT + (int) round(($worldZ - $minZ) * self::PIXELS_PER_METER),
            ];
        };

        foreach ($rooms as $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $points = [];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
                $points[] = $px;
                $points[] = $py;
            }
            imagefilledpolygon($image, $points, $roomFill);
            imagepolygon($image, $points, $roomBorder);

            [$labelX, $labelY] = $toPx($originX, $originZ);
            imagestring($image, 3, $labelX + 4, $labelY + 4, $room['label'], $text);
            // Mark's ask: labels, wall lengths, m2 on the same fused drawing,
            // not just the room name.
            $metrics = sprintf('%.2f sqm - %.2f m perimeter', $room['floor_area_m2'], $room['perimeter_m']);
            imagestring($image, 2, $labelX + 4, $labelY + 20, $metrics, $subtext);
            if (($room['height_m'] ?? null) !== null) {
                imagestring($image, 2, $labelX + 4, $labelY + 32, sprintf('%.2f m height', $room['height_m']), $subtext);
            }
        }

        // Doors/windows mark where one room's captured space actually meets
        // the next — this is what the tiled sheet above can never show
        // (ADR-0002). Only a position is known (LIDAR-10's opening centroid,
        // now translated into this shared frame), not a real wall-gap width
        // or swing direction, so this draws an honest marker at that point,
        // not a fabricated doorway shape.
        foreach ($rooms as $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            foreach ($room['openings'] ?? [] as $opening) {
                [$mx, $mz] = $opening['position_m'];
                [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
                $isDoor = $opening['category'] === 'door';
                $color = $isDoor ? $doorColor : $windowColor;
                imagefilledellipse($image, $px, $py, 10, 10, $color);
                imagestring($image, 1, $px + 6, $py - 6, $isDoor ? 'door' : $opening['category'], $color);
            }
        }

        ob_start();
        imagepng($image);
        $bytes = ob_get_clean();
        imagedestroy($image);

        return (string) $bytes;
    }

    /** @return array{width: int, height: int} */
    private function tileGeometry(array $room): array
    {
        $width = (int) round($room['bounding_dimensions_m']['width_m'] * self::PIXELS_PER_METER) + self::TILE_PADDING * 2;
        $height = (int) round($room['bounding_dimensions_m']['length_m'] * self::PIXELS_PER_METER) + self::TILE_PADDING * 2 + self::LABEL_HEIGHT;
        return ['width' => max($width, 120), 'height' => max($height, 120)];
    }

    private function drawRoomTile($image, array $room, int $originX, int $originY, int $fill, int $border, int $text, int $subtext): void
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

        $labelY = $originY + self::TILE_PADDING + (int) round($room['bounding_dimensions_m']['length_m'] * self::PIXELS_PER_METER) + 8;
        imagestring($image, 4, $originX + self::TILE_PADDING, $labelY, $room['label'], $text);
        // ASCII only — GD's built-in bitmap fonts are Latin-1, so raw UTF-8
        // (m-superscript-2, middot) renders as mojibake.
        $metrics = sprintf('%.2f sqm - %.2f m perimeter - %s confidence', $room['floor_area_m2'], $room['perimeter_m'], $room['confidence']);
        imagestring($image, 2, $originX + self::TILE_PADDING, $labelY + 18, $metrics, $subtext);
        if (($room['height_m'] ?? null) !== null) {
            imagestring($image, 2, $originX + self::TILE_PADDING, $labelY + 32, sprintf('%.2f m height', $room['height_m']), $subtext);
        }
    }
}
