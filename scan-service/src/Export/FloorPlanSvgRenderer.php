<?php

declare(strict_types=1);

namespace VuuroScan\Export;

use VuuroScan\RoomType;

final class FloorPlanSvgRenderer
{
    private const PX_PER_M = 60.0;
    private const MAX_CANVAS_DIMENSION_PX = 4000;
    private const DOOR_LEAF_M = 0.8;
    private const WINDOW_WIDTH_M = 1.0;
    private const OPENING_WIDTH_M = 0.7;

    private const TILE_PADDING = 24;
    private const LABEL_HEIGHT = 60;
    private const TILE_GAP = 32;
    private const MARGIN = 24;
    private const HEADER_HEIGHT = 84;
    private const NOTE_LINE_HEIGHT = 15;
    private const GRID_STEP = 60.0;

    private const CANVAS = '#f1f0ec';
    private const GRID_LINE = '#e2e1da';
    private const WALL = '#141414';
    private const OPENING_FILL = '#ffffff';
    private const WINDOW_LINE = '#7a7a7a';
    private const TEXT = '#1a1a1a';
    private const SUBTEXT = '#6b6b6b';
    private const DOOR_COLOR = '#141414';
    private const WALK_PATH = '#9656be';
    private const OBJECT = '#5c5c5c';
    private const WARN_FILL = '#f8d3d3';
    private const WARN_BORDER = '#a4231f';
    private const FONT = 'Arial, Helvetica, sans-serif';
    private const FOOTER_TEXT = 'Indicative measurements — NEN2580-inspired, not certified. No rights can be derived from this plan.';

    private const FALLBACK_FILLS = ['#d7e7f4', '#dff0d8', '#fae9cd', '#ede0f0', '#d8f0ee'];

    private static function roomHeadingDeg(array $room): ?float
    {
        $heading = $room['heading_deg'] ?? null;
        if (!is_int($heading) && !is_float($heading)) {
            return null;
        }
        $heading = (float) $heading;
        return is_finite($heading) ? $heading : null;
    }

    private static function roomTypeValue(array $room): ?string
    {
        $roomType = $room['room_type'] ?? null;
        if ($roomType === null) {
            return null;
        }
        return $roomType['confirmed'] ?? $roomType['guess'] ?? null;
    }

    private function roomFill(array $room, int $fallbackIndex): string
    {
        $fill = FloorPlanPalette::roomFillFor(self::roomTypeValue($room));
        return $fill ?? self::FALLBACK_FILLS[$fallbackIndex % count(self::FALLBACK_FILLS)];
    }

    private function displayLabel(array $room): string
    {
        $roomType = self::roomTypeValue($room);
        $typeName = $roomType !== null ? RoomType::labelFor($roomType) : null;
        return $typeName !== null ? sprintf('%s (%s)', $room['label'], $typeName) : $room['label'];
    }

    private function esc(string $s): string
    {
        return htmlspecialchars($s, ENT_QUOTES | ENT_XML1, 'UTF-8');
    }

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

        return $isFused
            ? $this->renderFused($rooms, $unit, $label, $notes)
            : $this->renderTiles($rooms, $unit, $label, $notes);
    }

    private function defs(): string
    {
        return <<<SVG
<defs>
  <pattern id="grid" width="{$this->num(self::GRID_STEP)}" height="{$this->num(self::GRID_STEP)}" patternUnits="userSpaceOnUse">
    <path d="M {$this->num(self::GRID_STEP)} 0 L 0 0 0 {$this->num(self::GRID_STEP)}" fill="none" stroke="{$this->esc(self::GRID_LINE)}" stroke-width="1"/>
  </pattern>
  <marker id="ar-s" markerWidth="7" markerHeight="7" refX="0.5" refY="3.5" orient="auto">
    <path d="M 7 0.6 L 0.5 3.5 L 7 6.4 Z" fill="{$this->esc(self::TEXT)}"/>
  </marker>
  <marker id="ar-e" markerWidth="7" markerHeight="7" refX="6.5" refY="3.5" orient="auto">
    <path d="M 0 0.6 L 6.5 3.5 L 0 6.4 Z" fill="{$this->esc(self::TEXT)}"/>
  </marker>
  <filter id="wall-shadow" x="-30%" y="-30%" width="160%" height="160%">
    <feDropShadow dx="0.8" dy="1.2" stdDeviation="1" flood-color="#000000" flood-opacity="0.35"/>
  </filter>
</defs>
SVG;
    }

    private function num(float $n): string
    {
        return rtrim(rtrim(sprintf('%.2f', $n), '0'), '.') ?: '0';
    }

    private function wrapSvg(int $width, int $height, string $body): string
    {
        return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' . $width . ' ' . $height . '" '
            . 'preserveAspectRatio="xMidYMid meet" width="100%" height="100%" font-family="' . self::FONT . '">'
            . '<rect x="0" y="0" width="' . $width . '" height="' . $height . '" fill="' . self::CANVAS . '"/>'
            . $this->defs()
            . $body
            . '</svg>';
    }

    private function headerSvg(string $title, array $subLines, int $width): string
    {
        $out = '<g id="header" fill="' . self::TEXT . '">';
        $out .= '<text x="' . self::MARGIN . '" y="22" font-size="16" font-weight="600">' . $this->esc($title) . '</text>';
        $y = 40;
        $out .= '<g fill="' . self::SUBTEXT . '" font-size="11">';
        foreach ($subLines as $line) {
            $out .= '<text x="' . self::MARGIN . '" y="' . $y . '">' . $this->esc($line) . '</text>';
            $y += 15;
        }
        $out .= '</g></g>';
        return $out;
    }

    private function footerSvg(int $width, int $y): string
    {
        return '<text x="' . (int) ($width / 2) . '" y="' . $y . '" font-size="9" fill="' . self::SUBTEXT . '" text-anchor="middle">'
            . $this->esc(self::FOOTER_TEXT) . '</text>';
    }

    private function notesSvg(array $lines, int $x, int $y): string
    {
        if ($lines === []) {
            return '';
        }
        $out = '<g id="notes" fill="' . self::TEXT . '" font-size="11">';
        foreach ($lines as $line) {
            $out .= '<text x="' . $x . '" y="' . $y . '" xml:space="preserve">' . $this->esc($line) . '</text>';
            $y += self::NOTE_LINE_HEIGHT;
        }
        $out .= '</g>';
        return $out;
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

        $lines = ['Notes:'];
        foreach ($rooms as $room) {
            foreach ($byRoom[$room['room_id']] ?? [] as $note) {
                foreach ($this->wrapTextLines($note['text'], 100) as $i => $wrapped) {
                    $lines[] = $i === 0 ? "  [{$room['label']}] {$wrapped}" : '        ' . $wrapped;
                }
            }
        }
        foreach ($unitNotes as $note) {
            foreach ($this->wrapTextLines($note['text'], 100) as $i => $wrapped) {
                $lines[] = $i === 0 ? "  [Whole unit] {$wrapped}" : '        ' . $wrapped;
            }
        }
        return count($lines) > 1 ? $lines : [];
    }

    private function wrapTextLines(string $text, int $maxChars): array
    {
        $wrapped = wordwrap($text, $maxChars, "\n", true);
        return $wrapped === '' ? [''] : explode("\n", $wrapped);
    }

    private function roomTypeLegendSvg(array $rooms, int $x, int $y): string
    {
        $typesPresent = [];
        foreach ($rooms as $room) {
            $type = self::roomTypeValue($room);
            if ($type !== null && !in_array($type, $typesPresent, true)) {
                $typesPresent[] = $type;
            }
        }
        if ($typesPresent === []) {
            return '';
        }
        $out = '<g id="legend" font-size="10">';
        foreach ($typesPresent as $type) {
            $fill = FloorPlanPalette::roomFillFor($type) ?? self::FALLBACK_FILLS[0];
            $labelText = RoomType::labelFor($type);
            $out .= '<rect x="' . $x . '" y="' . ($y - 9) . '" width="12" height="12" fill="' . $fill . '" stroke="' . self::WALL . '" stroke-width="0.75"/>';
            $out .= '<text x="' . ($x + 17) . '" y="' . $y . '" fill="' . self::TEXT . '">' . $this->esc($labelText) . '</text>';
            $x += 22 + (int) (strlen($labelText) * 6) + 14;
        }
        $out .= '</g>';
        return $out;
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
        return [$wallDx, $wallDz, $normalDx, $normalDz, $bestEdgeIndex];
    }

    private function edgeThicknessM(array $roomEdgeTiers, int $edgeIndex): float
    {
        return isset($roomEdgeTiers[$edgeIndex])
            ? FloorPlanPalette::INTERIOR_WALL_THICKNESS_M
            : FloorPlanPalette::EXTERIOR_WALL_THICKNESS_M;
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

    private function polygonPointsSvg(array $outlineM, array $pose, callable $toPx): string
    {
        $pts = [];
        foreach ($outlineM as [$mx, $mz]) {
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
            [$px, $py] = $toPx($wx, $wz);
            $pts[] = $this->num($px) . ',' . $this->num($py);
        }
        return implode(' ', $pts);
    }

    private function roomFillSvg(array $outlineM, array $pose, callable $toPx, string $fill): string
    {
        $points = $this->polygonPointsSvg($outlineM, $pose, $toPx);
        return '<polygon points="' . $points . '" fill="' . $fill . '"/>';
    }

    private function roomWallsSvg(array $outlineM, array $pose, callable $toPx, array $roomEdgeTiers): string
    {
        $n = count($outlineM);
        $out = '';
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
            $pts = [];
            foreach ($corners as [$cx, $cz]) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $cx, $cz);
                [$px, $py] = $toPx($wx, $wz);
                $pts[] = $this->num($px) . ',' . $this->num($py);
            }
            $out .= '<polygon points="' . implode(' ', $pts) . '" fill="' . self::WALL . '"/>';
        }
        return $out === '' ? '' : '<g filter="url(#wall-shadow)">' . $out . '</g>';
    }

    private function wallLengthLabelsSvg(array $outlineM, array $pose, callable $toPx, string $unit, array $roomEdgeTiers): string
    {
        $n = count($outlineM);
        if ($n === 0) {
            return '';
        }
        $centroidX = array_sum(array_column($outlineM, 0)) / $n;
        $centroidZ = array_sum(array_column($outlineM, 1)) / $n;
        $out = '<g font-size="9" fill="' . self::SUBTEXT . '" text-anchor="middle">';
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
            [$midX, $midZ] = $this->insetTowardCentroid($midX, $midZ, $centroidX, $centroidZ, 0.22);
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $midX, $midZ);
            [$px, $py] = $toPx($wx, $wz);
            $out .= '<text x="' . $this->num($px) . '" y="' . $this->num($py) . '">' . $this->esc(UnitFormatter::length($lengthM, $unit)) . '</text>';
        }
        $out .= '</g>';
        return $out;
    }

    private function jambSquaresSvg(array $pose, callable $toPx, float $mx, float $mz, float $wallDx, float $wallDz, float $half): string
    {
        $jamb = 3;
        $out = '';
        foreach ([-1, 1] as $side) {
            $jx = $mx + $wallDx * $side * $half;
            $jz = $mz + $wallDz * $side * $half;
            [$jwx, $jwz] = RoomFusionSolver::transformPoint($pose, $jx, $jz);
            [$jpx, $jpy] = $toPx($jwx, $jwz);
            $out .= '<rect x="' . $this->num($jpx - $jamb / 2) . '" y="' . $this->num($jpy - $jamb / 2) . '" width="' . $jamb . '" height="' . $jamb . '" fill="' . self::WALL . '"/>';
        }
        return $out;
    }

    private function openingsSvg(array $room, array $pose, callable $toPx, string $unit, array $roomEdgeTiers, string &$labels): string
    {
        $outline = $room['outline_m'] ?? [];
        $n = count($outline);
        $centroidX = $n > 0 ? array_sum(array_column($outline, 0)) / $n : 0.0;
        $centroidZ = $n > 0 ? array_sum(array_column($outline, 1)) / $n : 0.0;

        $out = '<g id="openings">';
        foreach ($room['openings'] ?? [] as $opening) {
            [$mx, $mz] = $opening['position_m'];
            $category = $opening['category'];
            [$wallDx, $wallDz, $normalDx, $normalDz, $edgeIndex] = $this->nearestWallOrientation($outline, $mx, $mz, $centroidX, $centroidZ);
            $wallHalfM = $this->edgeThicknessM($roomEdgeTiers, $edgeIndex) / 2;

            $widthM = match ($category) {
                'door' => self::DOOR_LEAF_M,
                'window' => self::WINDOW_WIDTH_M,
                default => self::OPENING_WIDTH_M,
            };
            $half = $widthM / 2;
            $corner = static fn (float $alongSign, float $acrossSign): array => [
                $mx + $wallDx * $alongSign * $half + $normalDx * $acrossSign * $wallHalfM,
                $mz + $wallDz * $alongSign * $half + $normalDz * $acrossSign * $wallHalfM,
            ];
            $corners = [$corner(-1, -1), $corner(1, -1), $corner(1, 1), $corner(-1, 1)];
            $pts = [];
            foreach ($corners as [$cx, $cz]) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $cx, $cz);
                [$px, $py] = $toPx($wx, $wz);
                $pts[] = $this->num($px) . ',' . $this->num($py);
            }
            $out .= '<polygon points="' . implode(' ', $pts) . '" fill="' . self::OPENING_FILL . '"/>';

            if ($category === 'door') {
                $hingeX = $mx - $wallDx * $half;
                $hingeZ = $mz - $wallDz * $half;
                $tipX = $hingeX + $wallDx * $widthM;
                $tipZ = $hingeZ + $wallDz * $widthM;
                $swingX = $hingeX + $normalDx * $widthM;
                $swingZ = $hingeZ + $normalDz * $widthM;
                [$hingeWx, $hingeWz] = RoomFusionSolver::transformPoint($pose, $hingeX, $hingeZ);
                [$hingePx, $hingePy] = $toPx($hingeWx, $hingeWz);
                [$tipWx, $tipWz] = RoomFusionSolver::transformPoint($pose, $tipX, $tipZ);
                [$tipPx, $tipPy] = $toPx($tipWx, $tipWz);
                [$swingWx, $swingWz] = RoomFusionSolver::transformPoint($pose, $swingX, $swingZ);
                [$swingPx, $swingPy] = $toPx($swingWx, $swingWz);
                $radiusPx = $widthM * self::PX_PER_M;
                $cross = ($tipX - $hingeX) * ($swingZ - $hingeZ) - ($tipZ - $hingeZ) * ($swingX - $hingeX);
                $sweep = $cross > 0 ? 1 : 0;
                $out .= '<g fill="none" stroke="' . self::DOOR_COLOR . '" stroke-width="1.2">'
                    . '<line x1="' . $this->num($hingePx) . '" y1="' . $this->num($hingePy) . '" x2="' . $this->num($swingPx) . '" y2="' . $this->num($swingPy) . '"/>'
                    . '<path d="M ' . $this->num($tipPx) . ' ' . $this->num($tipPy) . ' A ' . $this->num($radiusPx) . ' ' . $this->num($radiusPx) . ' 0 0 ' . $sweep . ' ' . $this->num($swingPx) . ' ' . $this->num($swingPy) . '"/>'
                    . '</g>';
                $out .= $this->jambSquaresSvg($pose, $toPx, $mx, $mz, $wallDx, $wallDz, $half);
            } elseif ($category === 'window') {
                $endAX = $mx - $wallDx * $half;
                $endAZ = $mz - $wallDz * $half;
                $endBX = $mx + $wallDx * $half;
                $endBZ = $mz + $wallDz * $half;
                [$aWx, $aWz] = RoomFusionSolver::transformPoint($pose, $endAX, $endAZ);
                [$aPx, $aPy] = $toPx($aWx, $aWz);
                [$bWx, $bWz] = RoomFusionSolver::transformPoint($pose, $endBX, $endBZ);
                [$bPx, $bPy] = $toPx($bWx, $bWz);
                $tickLenPx = $wallHalfM * self::PX_PER_M;
                $out .= '<g stroke="' . self::WINDOW_LINE . '" stroke-width="1">'
                    . '<line x1="' . $this->num($aPx) . '" y1="' . $this->num($aPy) . '" x2="' . $this->num($bPx) . '" y2="' . $this->num($bPy) . '"/>';
                foreach ([[$aPx, $aPy], [$bPx, $bPy]] as [$ex, $ey]) {
                    $out .= '<line x1="' . $this->num($ex - $normalDx * $tickLenPx) . '" y1="' . $this->num($ey - $normalDz * $tickLenPx) . '" x2="' . $this->num($ex + $normalDx * $tickLenPx) . '" y2="' . $this->num($ey + $normalDz * $tickLenPx) . '"/>';
                }
                $out .= '</g>';
            } else {
                $out .= $this->jambSquaresSvg($pose, $toPx, $mx, $mz, $wallDx, $wallDz, $half);
            }

            [$labelMx, $labelMz] = $this->insetTowardCentroid($mx, $mz, $centroidX, $centroidZ, 0.3);
            [$labelWx, $labelWz] = RoomFusionSolver::transformPoint($pose, $labelMx, $labelMz);
            [$labelX, $labelY] = $toPx($labelWx, $labelWz);
            $labels .= '<text x="' . $this->num($labelX) . '" y="' . $this->num($labelY) . '" font-size="8" fill="' . self::SUBTEXT . '">' . $this->esc($category) . '</text>';
        }
        $out .= '</g>';
        return $out;
    }

    private function walkPathSvg(array $room, array $pose, callable $toPx): string
    {
        $points = $room['walk_path_m'] ?? [];
        if (count($points) < 2) {
            return '';
        }
        $pts = [];
        foreach ($points as [$mx, $mz]) {
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
            [$px, $py] = $toPx($wx, $wz);
            $pts[] = $this->num($px) . ',' . $this->num($py);
        }
        return '<polyline points="' . implode(' ', $pts) . '" fill="none" stroke="' . self::WALK_PATH . '" stroke-width="1.5" stroke-dasharray="6,5"/>';
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

    private function horizontalDimensionChainSvg(array $breakpoints, float $y, callable $toPx, string $unit): string
    {
        $out = '<g stroke="' . self::TEXT . '" stroke-width="0.9" fill="none">';
        $text = '';
        for ($i = 0; $i < count($breakpoints) - 1; $i++) {
            $spanM = $breakpoints[$i + 1] - $breakpoints[$i];
            if ($spanM < 0.1) {
                continue;
            }
            [$x1] = $toPx($breakpoints[$i], 0.0);
            [$x2] = $toPx($breakpoints[$i + 1], 0.0);
            $out .= '<line x1="' . $this->num($x1) . '" y1="' . $this->num($y) . '" x2="' . $this->num($x2) . '" y2="' . $this->num($y) . '" marker-start="url(#ar-s)" marker-end="url(#ar-e)"/>'
                . '<line x1="' . $this->num($x1) . '" y1="' . $this->num($y - 5) . '" x2="' . $this->num($x1) . '" y2="' . $this->num($y + 5) . '"/>'
                . '<line x1="' . $this->num($x2) . '" y1="' . $this->num($y - 5) . '" x2="' . $this->num($x2) . '" y2="' . $this->num($y + 5) . '"/>';
            $text .= '<text x="' . $this->num(($x1 + $x2) / 2) . '" y="' . $this->num($y - 6) . '" font-size="10" fill="' . self::TEXT . '" text-anchor="middle">' . $this->esc(UnitFormatter::length($spanM, $unit)) . '</text>';
        }
        $out .= '</g>' . $text;
        return $out;
    }

    private function verticalDimensionChainSvg(array $breakpoints, float $x, callable $toPx, string $unit): string
    {
        $out = '<g stroke="' . self::TEXT . '" stroke-width="0.9" fill="none">';
        $text = '';
        for ($i = 0; $i < count($breakpoints) - 1; $i++) {
            $spanM = $breakpoints[$i + 1] - $breakpoints[$i];
            if ($spanM < 0.1) {
                continue;
            }
            [, $y1] = $toPx(0.0, $breakpoints[$i]);
            [, $y2] = $toPx(0.0, $breakpoints[$i + 1]);
            $out .= '<line x1="' . $this->num($x) . '" y1="' . $this->num($y1) . '" x2="' . $this->num($x) . '" y2="' . $this->num($y2) . '" marker-start="url(#ar-s)" marker-end="url(#ar-e)"/>'
                . '<line x1="' . $this->num($x - 5) . '" y1="' . $this->num($y1) . '" x2="' . $this->num($x + 5) . '" y2="' . $this->num($y1) . '"/>'
                . '<line x1="' . $this->num($x - 5) . '" y1="' . $this->num($y2) . '" x2="' . $this->num($x + 5) . '" y2="' . $this->num($y2) . '"/>';
            $midY = ($y1 + $y2) / 2;
            $text .= '<text x="' . $this->num($x - 6) . '" y="' . $this->num($midY) . '" font-size="10" fill="' . self::TEXT . '" text-anchor="middle" transform="rotate(-90 ' . $this->num($x - 6) . ' ' . $this->num($midY) . ')">' . $this->esc(UnitFormatter::length($spanM, $unit)) . '</text>';
        }
        $out .= '</g>' . $text;
        return $out;
    }

    private function compassArrowSvg(float $headingDeg, float $cx, float $cy): string
    {
        $rotation = fmod(540.0 - $headingDeg, 360.0);
        return '<g transform="translate(' . $this->num($cx) . ' ' . $this->num($cy) . ') rotate(' . $this->num($rotation) . ')">'
            . '<polygon points="0,-16 -5,4 5,4" fill="' . self::TEXT . '"/>'
            . '<line x1="0" y1="4" x2="0" y2="14" stroke="' . self::TEXT . '" stroke-width="1.5"/>'
            . '<text x="0" y="-20" font-size="10" font-weight="600" fill="' . self::TEXT . '" text-anchor="middle">N</text>'
            . '</g>';
    }

    private function localRectPolygon(array $pose, callable $toPx, float $cx, float $cz, float $halfW, float $halfD): string
    {
        $corners = [[$cx - $halfW, $cz - $halfD], [$cx + $halfW, $cz - $halfD], [$cx + $halfW, $cz + $halfD], [$cx - $halfW, $cz + $halfD]];
        $pts = [];
        foreach ($corners as [$lx, $lz]) {
            [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $lx, $lz);
            [$px, $py] = $toPx($wx, $wz);
            $pts[] = $this->num($px) . ',' . $this->num($py);
        }
        return implode(' ', $pts);
    }

    private function objectIconSvg(array $pose, callable $toPx, string $category, float $mx, float $mz, float $halfW, float $halfD): ?string
    {
        $rotationDeg = rad2deg($pose['rotationRad']);
        [$cwx, $cwz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
        [$cx, $cy] = $toPx($cwx, $cwz);
        $bodyRect = fn (float $hw, float $hd, string $fill, string $stroke) => '<polygon points="' . $this->localRectPolygon($pose, $toPx, $mx, $mz, $hw, $hd) . '" fill="' . $fill . '" stroke="' . $stroke . '" stroke-width="0.9"/>';
        $ellipse = fn (float $rw, float $rd, string $fill, string $stroke) => '<ellipse cx="' . $this->num($cx) . '" cy="' . $this->num($cy) . '" rx="' . $this->num($rw * self::PX_PER_M) . '" ry="' . $this->num($rd * self::PX_PER_M) . '" fill="' . $fill . '" stroke="' . $stroke . '" stroke-width="0.9" transform="rotate(' . $this->num($rotationDeg) . ' ' . $this->num($cx) . ' ' . $this->num($cy) . ')"/>';

        return match ($category) {
            'sink' => $bodyRect($halfW, $halfD, FloorPlanPalette::FIXTURE_LIGHT, FloorPlanPalette::FIXTURE_LINE)
                . $ellipse(min($halfW, $halfD) * 0.6, min($halfW, $halfD) * 0.6, self::OPENING_FILL, FloorPlanPalette::FIXTURE_LINE),
            'toilet' => $bodyRect($halfW, $halfD, FloorPlanPalette::FIXTURE_LIGHT, FloorPlanPalette::FIXTURE_LINE)
                . $ellipse($halfW * 0.65, $halfD * 0.55, self::OPENING_FILL, FloorPlanPalette::FIXTURE_LINE),
            'bathtub' => $bodyRect($halfW, $halfD, self::OPENING_FILL, FloorPlanPalette::FIXTURE_LINE),
            'stove', 'oven' => $bodyRect($halfW, $halfD, FloorPlanPalette::FIXTURE_FILL, FloorPlanPalette::FIXTURE_LINE)
                . $ellipse($halfW * 0.3, $halfD * 0.3, FloorPlanPalette::FIXTURE_LIGHT, 'none'),
            'refrigerator', 'dishwasher', 'storage' => $bodyRect($halfW, $halfD, FloorPlanPalette::FIXTURE_FILL, FloorPlanPalette::FIXTURE_LINE),
            'washerdryer', 'washer_dryer' => $bodyRect($halfW, $halfD, FloorPlanPalette::FIXTURE_FILL, FloorPlanPalette::FIXTURE_LINE)
                . $ellipse(min($halfW, $halfD) * 0.55, min($halfW, $halfD) * 0.55, FloorPlanPalette::FIXTURE_LIGHT, FloorPlanPalette::FIXTURE_LINE),
            'bed' => $bodyRect($halfW, $halfD, FloorPlanPalette::BED_FRAME_FILL, FloorPlanPalette::FIXTURE_LINE)
                . $bodyRect($halfW, $halfD * 0.22, self::OPENING_FILL, FloorPlanPalette::FIXTURE_LINE),
            'sofa' => $bodyRect($halfW, $halfD, FloorPlanPalette::FIXTURE_LIGHT, FloorPlanPalette::FIXTURE_LINE),
            'table' => $bodyRect($halfW, $halfD, self::OPENING_FILL, FloorPlanPalette::FIXTURE_LINE),
            'fireplace' => $bodyRect($halfW, $halfD, FloorPlanPalette::HEARTH_FILL, FloorPlanPalette::FIXTURE_LINE),
            'stairs' => $this->stairsIconSvg($pose, $toPx, $mx, $mz, $halfW, $halfD),
            default => null,
        };
    }

    private function stairsIconSvg(array $pose, callable $toPx, float $mx, float $mz, float $halfW, float $halfD): string
    {
        $out = '<polygon points="' . $this->localRectPolygon($pose, $toPx, $mx, $mz, $halfW, $halfD) . '" fill="' . self::OPENING_FILL . '" stroke="' . self::WALL . '" stroke-width="0.9"/>';
        $steps = 6;
        for ($s = 1; $s < $steps; $s++) {
            $lz = -$halfD + ($s / $steps) * (2 * $halfD);
            [$ax, $az] = RoomFusionSolver::transformPoint($pose, $mx - $halfW, $mz + $lz);
            [$bx, $bz] = RoomFusionSolver::transformPoint($pose, $mx + $halfW, $mz + $lz);
            [$apx, $apy] = $toPx($ax, $az);
            [$bpx, $bpy] = $toPx($bx, $bz);
            $out .= '<line x1="' . $this->num($apx) . '" y1="' . $this->num($apy) . '" x2="' . $this->num($bpx) . '" y2="' . $this->num($bpy) . '" stroke="' . self::WALL . '" stroke-width="0.9"/>';
        }
        return $out;
    }

    private function objectsSvg(array $room, array $pose, callable $toPx, string &$labels): string
    {
        $out = '<g id="objects" stroke="' . self::OBJECT . '" fill="none" font-size="8">';
        foreach ($room['objects'] ?? [] as $object) {
            [$mx, $mz] = $object['position_m'];
            $dims = $object['dimensions_m'] ?? [0.5, 0.0, 0.5];
            $halfWidth = ((float) ($dims[0] ?? 0.5)) / 2;
            $halfDepth = ((float) ($dims[2] ?? 0.5)) / 2;
            $category = strtolower((string) $object['category']);
            $icon = $this->objectIconSvg($pose, $toPx, $category, $mx, $mz, $halfWidth, $halfDepth);
            if ($icon !== null) {
                $out .= $icon;
                continue;
            }
            [$w1x, $w1z] = RoomFusionSolver::transformPoint($pose, $mx - $halfWidth, $mz - $halfDepth);
            [$x1, $y1] = $toPx($w1x, $w1z);
            [$w2x, $w2z] = RoomFusionSolver::transformPoint($pose, $mx + $halfWidth, $mz + $halfDepth);
            [$x2, $y2] = $toPx($w2x, $w2z);
            $out .= '<rect x="' . $this->num(min($x1, $x2)) . '" y="' . $this->num(min($y1, $y2)) . '" width="' . $this->num(abs($x2 - $x1)) . '" height="' . $this->num(abs($y2 - $y1)) . '"/>';
            $labels .= '<text x="' . $this->num(min($x1, $x2) + 2) . '" y="' . $this->num(min($y1, $y2) - 3) . '" fill="' . self::SUBTEXT . '" stroke="none">' . $this->esc($object['category']) . '</text>';
        }
        $out .= '</g>';
        return $out;
    }

    private function tileGeometry(array $room): array
    {
        $width = (int) round($room['bounding_dimensions_m']['width_m'] * self::PX_PER_M) + self::TILE_PADDING * 2;
        $height = (int) round($room['bounding_dimensions_m']['length_m'] * self::PX_PER_M) + self::TILE_PADDING * 2 + self::LABEL_HEIGHT;
        return ['width' => max($width, 160), 'height' => max($height, 160)];
    }

    private function renderTiles(array $rooms, string $unit, ?string $label, array $notes): string
    {
        $tiles = array_map([$this, 'tileGeometry'], $rooms);
        $notesLines = $this->buildNotesLines($rooms, $notes);

        $tilesWidth = self::MARGIN * 2 + array_sum(array_column($tiles, 'width')) + self::TILE_GAP * (count($tiles) - 1);
        $canvasWidth = max($tilesWidth, 560);
        $tilesHeight = (int) max(array_column($tiles, 'height'));

        $totalAreaM2 = array_sum(array_column($rooms, 'floor_area_m2'));
        $subLines = ['Room shapes accurate individually; rooms are not laid out relative to each other.'];
        if ($label !== null && $label !== '') {
            $subLines[] = $label;
        }
        $subLines[] = sprintf('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms));

        $headerHeight = self::HEADER_HEIGHT + (count($subLines) - 1) * 15;
        $y = $headerHeight;
        $canvasHeight = $y + $tilesHeight + 20 + count($notesLines) * self::NOTE_LINE_HEIGHT + 40;

        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Floor plan sheet would be %dx%d px, exceeding the %d px sanity bound — refusing to render it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $body = $this->headerSvg('Vuuro Scan — indicative per-room floor plan sheet', $subLines, $canvasWidth);

        $x = self::MARGIN;
        foreach ($rooms as $i => $room) {
            $tile = $tiles[$i];
            $body .= '<g transform="translate(' . $x . ',' . $y . ')">' . $this->roomTileSvg($room, $tile, $unit, $i) . '</g>';
            $x += $tile['width'] + self::TILE_GAP;
        }

        $notesY = $y + $tilesHeight + 24;
        $body .= $this->notesSvg($notesLines, self::MARGIN, $notesY);
        $body .= $this->footerSvg($canvasWidth, $canvasHeight - 14);

        return $this->wrapSvg($canvasWidth, $canvasHeight, $body);
    }

    private function roomTileSvg(array $room, array $tile, string $unit, int $fallbackIndex): string
    {
        $toPx = fn (float $mx, float $mz): array => [
            self::TILE_PADDING + $mx * self::PX_PER_M,
            self::TILE_PADDING + $mz * self::PX_PER_M,
        ];
        $fill = $this->roomFill($room, $fallbackIndex);
        $identityPose = ['originX' => 0.0, 'originZ' => 0.0, 'rotationRad' => 0.0];

        $labels = '';
        $out = '<rect x="0" y="0" width="' . $tile['width'] . '" height="' . ($tile['height'] - self::LABEL_HEIGHT) . '" fill="url(#grid)"/>';
        $out .= $this->roomFillSvg($room['outline_m'], $identityPose, $toPx, $fill);
        $out .= $this->roomWallsSvg($room['outline_m'], $identityPose, $toPx, []);
        $out .= $this->walkPathSvg($room, $identityPose, $toPx);
        $out .= $this->openingsSvg($room, $identityPose, $toPx, $unit, [], $labels);
        $out .= $this->objectsSvg($room, $identityPose, $toPx, $labels);
        $headingDeg = self::roomHeadingDeg($room);
        if ($headingDeg !== null) {
            $out .= $this->compassArrowSvg($headingDeg, $tile['width'] - 26, 26);
        }

        $out .= $this->wallLengthLabelsSvg($room['outline_m'], $identityPose, $toPx, $unit, []);
        $out .= $labels;

        $labelY = $tile['height'] - self::LABEL_HEIGHT + 20;
        $out .= '<text x="0" y="' . $labelY . '" font-size="13" font-weight="600" fill="' . self::TEXT . '">' . $this->esc($this->displayLabel($room)) . '</text>';
        $metrics = sprintf('%s — %s perimeter — %s confidence', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit), $room['confidence']);
        $out .= '<text x="0" y="' . ($labelY + 16) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc($metrics) . '</text>';
        $lineY = $labelY + 32;
        if (($room['height_m'] ?? null) !== null) {
            $out .= '<text x="0" y="' . $lineY . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc(sprintf('%s height', UnitFormatter::length($room['height_m'], $unit))) . '</text>';
            $lineY += 13;
        }
        if (($room['volume_m3_indicative'] ?? null) !== null) {
            $out .= '<text x="0" y="' . $lineY . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc(sprintf('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit))) . '</text>';
        }
        return $out;
    }

    private function renderFused(array $rooms, string $unit, ?string $label, array $notes): string
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
                [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
                $minX = min($minX, $wx);
                $minZ = min($minZ, $wz);
                $maxX = max($maxX, $wx);
                $maxZ = max($maxZ, $wz);
            }
        }
        $notesLines = $this->buildNotesLines($rooms, $notes);

        $subLines = ['Room positions relative to each other, not independently verified beyond this capture.'];
        if ($overlapping !== []) {
            $subLines[] = 'WARNING: rooms below overlap in captured position — verify against the real layout before use.';
        }
        if ($label !== null && $label !== '') {
            $subLines[] = $label;
        }
        $totalAreaM2 = array_sum(array_column($rooms, 'floor_area_m2'));
        $subLines[] = sprintf('Total indicative area: %s across %d room(s)', UnitFormatter::area($totalAreaM2, $unit), count($rooms));

        $headerHeight = self::HEADER_HEIGHT + (count($subLines) - 1) * 15;
        $dimGutter = 34;
        $topGutter = $headerHeight + $dimGutter;
        $drawingWidth = (int) round(($maxX - $minX) * self::PX_PER_M);
        $drawingHeight = (int) round(($maxZ - $minZ) * self::PX_PER_M);
        $canvasWidth = max(self::MARGIN * 2 + $dimGutter + $drawingWidth, 560);
        $canvasHeight = $topGutter + $drawingHeight + 40 + count($notesLines) * self::NOTE_LINE_HEIGHT + 30;

        if ($canvasWidth > self::MAX_CANVAS_DIMENSION_PX || $canvasHeight > self::MAX_CANVAS_DIMENSION_PX) {
            throw new \InvalidArgumentException(sprintf(
                'Fused floor plan would be %dx%d px, exceeding the %d px sanity bound — refusing to render it.',
                $canvasWidth,
                $canvasHeight,
                self::MAX_CANVAS_DIMENSION_PX
            ));
        }

        $originPxX = self::MARGIN + $dimGutter;
        $originPxY = $topGutter;
        $toPx = fn (float $worldX, float $worldZ): array => [
            $originPxX + ($worldX - $minX) * self::PX_PER_M,
            $originPxY + ($worldZ - $minZ) * self::PX_PER_M,
        ];

        $body = $this->headerSvg('Vuuro Scan — fused floor plan (rooms captured together)', $subLines, $canvasWidth);
        $body .= '<rect x="' . $originPxX . '" y="' . $originPxY . '" width="' . $drawingWidth . '" height="' . $drawingHeight . '" fill="url(#grid)"/>';

        $dimY = $headerHeight + 14;
        $xBreakpoints = $this->dimensionChainBreakpoints($rooms, $poses, 0);
        $body .= $this->horizontalDimensionChainSvg($xBreakpoints, $dimY, $toPx, $unit);

        $dimX = self::MARGIN + 14;
        $zBreakpoints = $this->dimensionChainBreakpoints($rooms, $poses, 1);
        $body .= $this->verticalDimensionChainSvg($zBreakpoints, $dimX, $toPx, $unit);

        $edgeTiers = $fusion['edgeTiers'];

        $body .= '<g id="room-fills">';
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            $fill = in_array($i, $overlapping, true) ? self::WARN_FILL : $this->roomFill($room, $i);
            $body .= $this->roomFillSvg($room['outline_m'], $pose, $toPx, $fill);
        }
        $body .= '</g>';

        $body .= '<g id="walls">';
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            if (in_array($i, $overlapping, true)) {
                $points = $this->polygonPointsSvg($room['outline_m'], $pose, $toPx);
                $strokePx = FloorPlanPalette::EXTERIOR_WALL_THICKNESS_M * self::PX_PER_M;
                $body .= '<polygon points="' . $points . '" fill="none" stroke="' . self::WARN_BORDER . '" stroke-width="' . $this->num($strokePx) . '"/>';
            } else {
                $body .= $this->roomWallsSvg($room['outline_m'], $pose, $toPx, $edgeTiers[$i] ?? []);
            }
        }
        $body .= '</g>';

        $labels = '';

        foreach ($rooms as $i => $room) {
            $body .= $this->walkPathSvg($room, $poses[$i], $toPx);
        }
        foreach ($rooms as $i => $room) {
            $body .= $this->openingsSvg($room, $poses[$i], $toPx, $unit, $edgeTiers[$i] ?? [], $labels);
            $body .= $this->objectsSvg($room, $poses[$i], $toPx, $labels);
        }

        foreach ($rooms as $i => $room) {
            $pose = $poses[$i];
            [$labelX, $labelY] = $toPx($pose['originX'], $pose['originZ']);
            $labels .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($labelY + 16) . '" font-size="12" font-weight="600" fill="' . self::TEXT . '">' . $this->esc($this->displayLabel($room)) . '</text>';
            $metrics = sprintf('%s — %s perimeter', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit));
            $labels .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($labelY + 30) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc($metrics) . '</text>';
            $lineY = $labelY + 44;
            if (($room['height_m'] ?? null) !== null) {
                $labels .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($lineY) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc(sprintf('%s height', UnitFormatter::length($room['height_m'], $unit))) . '</text>';
                $lineY += 13;
            }
            if (($room['volume_m3_indicative'] ?? null) !== null) {
                $labels .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($lineY) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc(sprintf('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit))) . '</text>';
            }
        }

        $body .= $labels;

        $fusedHeadingDeg = null;
        foreach ($rooms as $room) {
            $fusedHeadingDeg = self::roomHeadingDeg($room);
            if ($fusedHeadingDeg !== null) {
                break;
            }
        }
        if ($fusedHeadingDeg !== null) {
            $body .= $this->compassArrowSvg($fusedHeadingDeg, $originPxX + $drawingWidth - 26, $originPxY + 26);
        }

        $drawingBottomY = $originPxY + $drawingHeight;
        $notesY = $drawingBottomY + 20;
        $body .= $this->notesSvg($notesLines, self::MARGIN, $notesY);

        $legendY = $canvasHeight - 30;
        $body .= '<g font-size="9" fill="' . self::TEXT . '">'
            . '<circle cx="' . (self::MARGIN + 4) . '" cy="' . $legendY . '" r="4" fill="' . self::DOOR_COLOR . '"/><text x="' . (self::MARGIN + 12) . '" y="' . ($legendY + 3) . '">door</text>'
            . '<rect x="' . (self::MARGIN + 60) . '" y="' . ($legendY - 4) . '" width="10" height="6" fill="' . self::OPENING_FILL . '" stroke="' . self::WINDOW_LINE . '"/><text x="' . (self::MARGIN + 74) . '" y="' . ($legendY + 3) . '">window</text>'
            . '<line x1="' . (self::MARGIN + 130) . '" y1="' . $legendY . '" x2="' . (self::MARGIN + 146) . '" y2="' . $legendY . '" stroke="' . self::WALK_PATH . '" stroke-width="1.5" stroke-dasharray="6,5"/><text x="' . (self::MARGIN + 150) . '" y="' . ($legendY + 3) . '">walk path</text>'
            . '<rect x="' . (self::MARGIN + 220) . '" y="' . ($legendY - 5) . '" width="8" height="8" fill="none" stroke="' . self::OBJECT . '"/><text x="' . (self::MARGIN + 232) . '" y="' . ($legendY + 3) . '">detected object</text>'
            . '</g>';
        $body .= $this->roomTypeLegendSvg($rooms, self::MARGIN, $legendY - 16);
        $body .= $this->footerSvg($canvasWidth, $canvasHeight - 12);

        return $this->wrapSvg($canvasWidth, $canvasHeight, $body);
    }
}
