<?php

declare(strict_types=1);

namespace VuuroScan\Export;

use VuuroScan\RoomType;

final class FloorPlanSvgRenderer
{
    private const PX_PER_M = 60.0;
    private const MAX_CANVAS_DIMENSION_PX = 4000;
    private const WALL_THICKNESS_M = 0.12;
    private const DOOR_LEAF_M = 0.8;
    private const WINDOW_WIDTH_M = 1.0;
    private const OPENING_WIDTH_M = 0.7;
    private const SEAM_MIN_GAP_M = 0.01;
    private const SEAM_MAX_GAP_M = 0.5;
    private const SEAM_MIN_OVERLAP_M = 0.2;
    private const SEAM_PARALLEL_TOLERANCE = 0.05;
    private const SEAM_OFFSET_CONSISTENCY_M = 0.05;

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

    private const ROOM_TYPE_FILL = [
        'kitchen' => '#d3e3f1',
        'bathroom' => '#d3e3f1',
        'laundry_room' => '#d3e3f1',
        'bedroom' => '#ecc98d',
        'guest_room' => '#ecc98d',
        'living_room' => '#f3dab3',
        'dining_room' => '#f3dab3',
        'office' => '#f3dab3',
        'hallway' => '#fbc97a',
        'garage' => '#cfcfcf',
        'storage_room' => '#cfcfcf',
        'basement' => '#cfcfcf',
        'attic' => '#cfcfcf',
        'walk_in_closet' => '#ffffff',
        'balcony' => '#ffffff',
    ];
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
        $type = self::roomTypeValue($room);
        if ($type !== null) {
            $normalized = strtolower(str_replace([' ', '-'], '_', $type));
            if (isset(self::ROOM_TYPE_FILL[$normalized])) {
                return self::ROOM_TYPE_FILL[$normalized];
            }
        }
        return self::FALLBACK_FILLS[$fallbackIndex % count(self::FALLBACK_FILLS)];
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
            $normalized = strtolower(str_replace([' ', '-'], '_', $type));
            $fill = self::ROOM_TYPE_FILL[$normalized] ?? self::FALLBACK_FILLS[0];
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

    private function polygonPointsSvg(array $outlineM, float $originX, float $originZ, callable $toPx): string
    {
        $pts = [];
        foreach ($outlineM as [$mx, $mz]) {
            [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
            $pts[] = $this->num($px) . ',' . $this->num($py);
        }
        return implode(' ', $pts);
    }

    private function roomBoundarySvg(array $outlineM, float $originX, float $originZ, callable $toPx, string $fill): string
    {
        $points = $this->polygonPointsSvg($outlineM, $originX, $originZ, $toPx);
        $strokePx = self::WALL_THICKNESS_M * self::PX_PER_M;
        return '<polygon points="' . $points . '" fill="' . $fill . '"/>'
            . '<polygon points="' . $points . '" fill="none" stroke="' . self::WALL . '" stroke-width="' . $this->num($strokePx) . '" stroke-linejoin="miter"/>';
    }

    private function findSeamConstraints(array $rooms, array $overlapping): array
    {
        $outlines = [];
        foreach ($rooms as $i => $room) {
            if (in_array($i, $overlapping, true)) {
                continue;
            }
            [$originX, $originZ] = $room['structure_origin_m'];
            $outline = [];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                $outline[] = [$mx + $originX, $mz + $originZ];
            }
            $outlines[$i] = $outline;
        }

        $edges = [];
        foreach ($outlines as $roomIndex => $outline) {
            $n = count($outline);
            for ($k = 0; $k < $n; $k++) {
                [$ax, $az] = $outline[$k];
                [$bx, $bz] = $outline[($k + 1) % $n];
                $edges[] = [$roomIndex, $ax, $az, $bx, $bz];
            }
        }

        $constraints = [];
        $count = count($edges);
        for ($i = 0; $i < $count; $i++) {
            [$roomA, $a1x, $a1z, $a2x, $a2z] = $edges[$i];
            $dax = $a2x - $a1x;
            $daz = $a2z - $a1z;
            $lenA = sqrt($dax ** 2 + $daz ** 2);
            if ($lenA < 1e-6) {
                continue;
            }
            $ux = $dax / $lenA;
            $uz = $daz / $lenA;
            $nx = -$uz;
            $nz = $ux;

            for ($j = $i + 1; $j < $count; $j++) {
                [$roomB, $b1x, $b1z, $b2x, $b2z] = $edges[$j];
                if ($roomB === $roomA) {
                    continue;
                }
                $dbx = $b2x - $b1x;
                $dbz = $b2z - $b1z;
                $lenB = sqrt($dbx ** 2 + $dbz ** 2);
                if ($lenB < 1e-6) {
                    continue;
                }
                $vx = $dbx / $lenB;
                $vz = $dbz / $lenB;
                $cross = $ux * $vz - $uz * $vx;
                if (abs($cross) > self::SEAM_PARALLEL_TOLERANCE) {
                    continue;
                }

                $distB1 = ($b1x - $a1x) * $nx + ($b1z - $a1z) * $nz;
                $distB2 = ($b2x - $a1x) * $nx + ($b2z - $a1z) * $nz;
                if (abs($distB1 - $distB2) > self::SEAM_OFFSET_CONSISTENCY_M) {
                    continue;
                }
                $gap = ($distB1 + $distB2) / 2;
                if (abs($gap) < self::SEAM_MIN_GAP_M || abs($gap) > self::SEAM_MAX_GAP_M) {
                    continue;
                }

                $tB1 = ($b1x - $a1x) * $ux + ($b1z - $a1z) * $uz;
                $tB2 = ($b2x - $a1x) * $ux + ($b2z - $a1z) * $uz;
                $tLo = max(0.0, min($tB1, $tB2));
                $tHi = min($lenA, max($tB1, $tB2));
                if ($tHi - $tLo < self::SEAM_MIN_OVERLAP_M) {
                    continue;
                }

                $constraints[] = [$roomA, $roomB, $nx, $nz, $gap];
            }
        }
        return $constraints;
    }

    private function resolveFusionOffsets(array $rooms, array $overlapping): array
    {
        $offsets = [];
        foreach ($rooms as $i => $room) {
            $offsets[$i] = [0.0, 0.0];
        }

        $constraints = $this->findSeamConstraints($rooms, $overlapping);
        for ($pass = 0; $pass < 24; $pass++) {
            foreach ($constraints as [$roomA, $roomB, $nx, $nz, $baseGap]) {
                $currentGap = $baseGap
                    + (($offsets[$roomB][0] - $offsets[$roomA][0]) * $nx + ($offsets[$roomB][1] - $offsets[$roomA][1]) * $nz);
                $correction = $currentGap / 2;
                $offsets[$roomA][0] += $nx * $correction;
                $offsets[$roomA][1] += $nz * $correction;
                $offsets[$roomB][0] -= $nx * $correction;
                $offsets[$roomB][1] -= $nz * $correction;
            }
        }
        return $offsets;
    }

    private function fusedRoomOrigin(array $room, int $roomIndex, array $seamOffsets): array
    {
        [$originX, $originZ] = $room['structure_origin_m'];
        [$dx, $dz] = $seamOffsets[$roomIndex] ?? [0.0, 0.0];
        return [$originX + $dx, $originZ + $dz];
    }

    private function wallLengthLabelsSvg(array $outlineM, float $originX, float $originZ, callable $toPx, string $unit): string
    {
        $n = count($outlineM);
        if ($n === 0) {
            return '';
        }
        $centroidX = array_sum(array_column($outlineM, 0)) / $n;
        $centroidZ = array_sum(array_column($outlineM, 1)) / $n;
        $out = '<g font-size="9" fill="' . self::SUBTEXT . '" text-anchor="middle">';
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $lengthM = sqrt(($bx - $ax) ** 2 + ($bz - $az) ** 2);
            if ($lengthM < 0.3) {
                continue;
            }
            $midX = ($ax + $bx) / 2;
            $midZ = ($az + $bz) / 2;
            [$midX, $midZ] = $this->insetTowardCentroid($midX, $midZ, $centroidX, $centroidZ, 0.22);
            [$px, $py] = $toPx($midX + $originX, $midZ + $originZ);
            $out .= '<text x="' . $this->num($px) . '" y="' . $this->num($py) . '">' . $this->esc(UnitFormatter::length($lengthM, $unit)) . '</text>';
        }
        $out .= '</g>';
        return $out;
    }

    private function openingsSvg(array $room, float $originX, float $originZ, callable $toPx, string $unit): string
    {
        $outline = $room['outline_m'] ?? [];
        $n = count($outline);
        $centroidX = $n > 0 ? array_sum(array_column($outline, 0)) / $n : 0.0;
        $centroidZ = $n > 0 ? array_sum(array_column($outline, 1)) / $n : 0.0;
        $wallHalfM = self::WALL_THICKNESS_M / 2;

        $out = '<g id="openings">';
        foreach ($room['openings'] ?? [] as $opening) {
            [$mx, $mz] = $opening['position_m'];
            $category = $opening['category'];
            [$wallDx, $wallDz, $normalDx, $normalDz] = $this->nearestWallOrientation($outline, $mx, $mz, $centroidX, $centroidZ);

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
                [$px, $py] = $toPx($cx + $originX, $cz + $originZ);
                $pts[] = $this->num($px) . ',' . $this->num($py);
            }
            $out .= '<polygon points="' . implode(' ', $pts) . '" fill="' . self::OPENING_FILL . '"/>';

            [$pivotPx, $pivotPy] = $toPx($mx + $originX, $mz + $originZ);

            if ($category === 'door') {
                $tipX = $mx + $wallDx * $widthM;
                $tipZ = $mz + $wallDz * $widthM;
                $swingX = $mx + $normalDx * $widthM;
                $swingZ = $mz + $normalDz * $widthM;
                [$tipPx, $tipPy] = $toPx($tipX + $originX, $tipZ + $originZ);
                [$swingPx, $swingPy] = $toPx($swingX + $originX, $swingZ + $originZ);
                $radiusPx = $widthM * self::PX_PER_M;
                $cross = ($tipX - $mx) * ($swingZ - $mz) - ($tipZ - $mz) * ($swingX - $mx);
                $sweep = $cross > 0 ? 1 : 0;
                $out .= '<g fill="none" stroke="' . self::DOOR_COLOR . '" stroke-width="1.2">'
                    . '<line x1="' . $this->num($pivotPx) . '" y1="' . $this->num($pivotPy) . '" x2="' . $this->num($swingPx) . '" y2="' . $this->num($swingPy) . '"/>'
                    . '<path d="M ' . $this->num($tipPx) . ' ' . $this->num($tipPy) . ' A ' . $this->num($radiusPx) . ' ' . $this->num($radiusPx) . ' 0 0 ' . $sweep . ' ' . $this->num($swingPx) . ' ' . $this->num($swingPy) . '"/>'
                    . '</g>';
            } elseif ($category === 'window') {
                $endAX = $mx - $wallDx * $half;
                $endAZ = $mz - $wallDz * $half;
                $endBX = $mx + $wallDx * $half;
                $endBZ = $mz + $wallDz * $half;
                [$aPx, $aPy] = $toPx($endAX + $originX, $endAZ + $originZ);
                [$bPx, $bPy] = $toPx($endBX + $originX, $endBZ + $originZ);
                $tickLenPx = $wallHalfM * self::PX_PER_M;
                $out .= '<g stroke="' . self::WINDOW_LINE . '" stroke-width="1">'
                    . '<line x1="' . $this->num($aPx) . '" y1="' . $this->num($aPy) . '" x2="' . $this->num($bPx) . '" y2="' . $this->num($bPy) . '"/>';
                foreach ([[$aPx, $aPy], [$bPx, $bPy]] as [$ex, $ey]) {
                    $out .= '<line x1="' . $this->num($ex - $normalDx * $tickLenPx) . '" y1="' . $this->num($ey - $normalDz * $tickLenPx) . '" x2="' . $this->num($ex + $normalDx * $tickLenPx) . '" y2="' . $this->num($ey + $normalDz * $tickLenPx) . '"/>';
                }
                $out .= '</g>';
            } else {
                $jamb = 3;
                foreach ([-1, 1] as $side) {
                    $jx = $mx + $wallDx * $side * $half;
                    $jz = $mz + $wallDz * $side * $half;
                    [$jpx, $jpy] = $toPx($jx + $originX, $jz + $originZ);
                    $out .= '<rect x="' . $this->num($jpx - $jamb / 2) . '" y="' . $this->num($jpy - $jamb / 2) . '" width="' . $jamb . '" height="' . $jamb . '" fill="' . self::WALL . '"/>';
                }
            }

            [$labelMx, $labelMz] = $this->insetTowardCentroid($mx, $mz, $centroidX, $centroidZ, 0.3);
            [$labelX, $labelY] = $toPx($labelMx + $originX, $labelMz + $originZ);
            $out .= '<text x="' . $this->num($labelX) . '" y="' . $this->num($labelY) . '" font-size="8" fill="' . self::SUBTEXT . '">' . $this->esc($category) . '</text>';
        }
        $out .= '</g>';
        return $out;
    }

    private function walkPathSvg(array $room, float $originX, float $originZ, callable $toPx): string
    {
        $points = $room['walk_path_m'] ?? [];
        if (count($points) < 2) {
            return '';
        }
        $pts = [];
        foreach ($points as [$mx, $mz]) {
            [$px, $py] = $toPx($mx + $originX, $mz + $originZ);
            $pts[] = $this->num($px) . ',' . $this->num($py);
        }
        return '<polyline points="' . implode(' ', $pts) . '" fill="none" stroke="' . self::WALK_PATH . '" stroke-width="1.5" stroke-dasharray="6,5"/>';
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

    private function objectsSvg(array $room, float $originX, float $originZ, callable $toPx): string
    {
        $out = '<g id="objects" stroke="' . self::OBJECT . '" fill="none" font-size="8">';
        foreach ($room['objects'] ?? [] as $object) {
            [$mx, $mz] = $object['position_m'];
            $dims = $object['dimensions_m'] ?? [0.5, 0.0, 0.5];
            $halfWidth = ((float) ($dims[0] ?? 0.5)) / 2;
            $halfDepth = ((float) ($dims[2] ?? 0.5)) / 2;
            [$x1, $y1] = $toPx($mx - $halfWidth + $originX, $mz - $halfDepth + $originZ);
            [$x2, $y2] = $toPx($mx + $halfWidth + $originX, $mz + $halfDepth + $originZ);
            $out .= '<rect x="' . $this->num(min($x1, $x2)) . '" y="' . $this->num(min($y1, $y2)) . '" width="' . $this->num(abs($x2 - $x1)) . '" height="' . $this->num(abs($y2 - $y1)) . '"/>';
            $out .= '<text x="' . $this->num(min($x1, $x2) + 2) . '" y="' . $this->num(min($y1, $y2) - 3) . '" fill="' . self::SUBTEXT . '" stroke="none">' . $this->esc($object['category']) . '</text>';
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

        $out = '<rect x="0" y="0" width="' . $tile['width'] . '" height="' . ($tile['height'] - self::LABEL_HEIGHT) . '" fill="url(#grid)"/>';
        $out .= $this->roomBoundarySvg($room['outline_m'], 0.0, 0.0, $toPx, $fill);
        $out .= $this->wallLengthLabelsSvg($room['outline_m'], 0.0, 0.0, $toPx, $unit);
        $out .= $this->walkPathSvg($room, 0.0, 0.0, $toPx);
        $out .= $this->openingsSvg($room, 0.0, 0.0, $toPx, $unit);
        $out .= $this->objectsSvg($room, 0.0, 0.0, $toPx);
        $headingDeg = self::roomHeadingDeg($room);
        if ($headingDeg !== null) {
            $out .= $this->compassArrowSvg($headingDeg, $tile['width'] - 26, 26);
        }

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
        $overlapping = FusionOverlapDetector::detect($rooms);
        $seamOffsets = $this->resolveFusionOffsets($rooms, $overlapping);
        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $this->fusedRoomOrigin($room, $i, $seamOffsets);
            foreach ($room['outline_m'] as [$mx, $mz]) {
                $minX = min($minX, $mx + $originX);
                $minZ = min($minZ, $mz + $originZ);
                $maxX = max($maxX, $mx + $originX);
                $maxZ = max($maxZ, $mz + $originZ);
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
        $body .= '<g stroke="' . self::TEXT . '" stroke-width="0.9" fill="none">'
            . '<line x1="' . $originPxX . '" y1="' . $dimY . '" x2="' . ($originPxX + $drawingWidth) . '" y2="' . $dimY . '" marker-start="url(#ar-s)" marker-end="url(#ar-e)"/>'
            . '</g>';
        $body .= '<text x="' . (int) ($originPxX + $drawingWidth / 2) . '" y="' . ($dimY - 6) . '" font-size="10" fill="' . self::TEXT . '" text-anchor="middle">' . $this->esc(UnitFormatter::length($maxX - $minX, $unit)) . '</text>';

        $dimX = self::MARGIN + 14;
        $body .= '<g stroke="' . self::TEXT . '" stroke-width="0.9" fill="none">'
            . '<line x1="' . $dimX . '" y1="' . $originPxY . '" x2="' . $dimX . '" y2="' . ($originPxY + $drawingHeight) . '" marker-start="url(#ar-s)" marker-end="url(#ar-e)"/>'
            . '</g>';
        $body .= '<text x="' . ($dimX - 6) . '" y="' . (int) ($originPxY + $drawingHeight / 2) . '" font-size="10" fill="' . self::TEXT . '" text-anchor="middle" transform="rotate(-90 ' . ($dimX - 6) . ' ' . (int) ($originPxY + $drawingHeight / 2) . ')">' . $this->esc(UnitFormatter::length($maxZ - $minZ, $unit)) . '</text>';

        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $this->fusedRoomOrigin($room, $i, $seamOffsets);
            $fill = in_array($i, $overlapping, true) ? self::WARN_FILL : $this->roomFill($room, $i);
            $strokeOverride = in_array($i, $overlapping, true) ? self::WARN_BORDER : null;

            if ($strokeOverride !== null) {
                $points = $this->polygonPointsSvg($room['outline_m'], $originX, $originZ, $toPx);
                $strokePx = self::WALL_THICKNESS_M * self::PX_PER_M;
                $body .= '<polygon points="' . $points . '" fill="' . $fill . '"/>'
                    . '<polygon points="' . $points . '" fill="none" stroke="' . $strokeOverride . '" stroke-width="' . $this->num($strokePx) . '"/>';
            } else {
                $body .= $this->roomBoundarySvg($room['outline_m'], $originX, $originZ, $toPx, $fill);
            }
            $body .= $this->wallLengthLabelsSvg($room['outline_m'], $originX, $originZ, $toPx, $unit);

            [$labelX, $labelY] = $toPx($originX, $originZ);
            $body .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($labelY + 16) . '" font-size="12" font-weight="600" fill="' . self::TEXT . '">' . $this->esc($this->displayLabel($room)) . '</text>';
            $metrics = sprintf('%s — %s perimeter', UnitFormatter::area($room['floor_area_m2'], $unit), UnitFormatter::length($room['perimeter_m'], $unit));
            $body .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($labelY + 30) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc($metrics) . '</text>';
            $lineY = $labelY + 44;
            if (($room['height_m'] ?? null) !== null) {
                $body .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($lineY) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc(sprintf('%s height', UnitFormatter::length($room['height_m'], $unit))) . '</text>';
                $lineY += 13;
            }
            if (($room['volume_m3_indicative'] ?? null) !== null) {
                $body .= '<text x="' . $this->num($labelX + 6) . '" y="' . $this->num($lineY) . '" font-size="10" fill="' . self::SUBTEXT . '">' . $this->esc(sprintf('%s indicative', UnitFormatter::volume($room['volume_m3_indicative'], $unit))) . '</text>';
            }
        }

        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $this->fusedRoomOrigin($room, $i, $seamOffsets);
            $body .= $this->walkPathSvg($room, $originX, $originZ, $toPx);
        }
        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $this->fusedRoomOrigin($room, $i, $seamOffsets);
            $body .= $this->openingsSvg($room, $originX, $originZ, $toPx, $unit);
            $body .= $this->objectsSvg($room, $originX, $originZ, $toPx);
        }

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
