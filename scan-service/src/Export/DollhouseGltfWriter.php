<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class DollhouseGltfWriter
{
    private const WALL_THICKNESS_M = 0.20;
    private const DEFAULT_HEIGHT_M = 2.4;
    private const FLOOR_COLOR = [0.90, 0.86, 0.78, 1.0];
    private const WALL_COLOR = [0.95, 0.94, 0.92, 1.0];
    private const MAX_OPENING_WALL_DISTANCE_M = 0.6;
    private const MAX_TRIANGLES = 150000;

    public function write(array $floorPlan): string
    {
        $rooms = $floorPlan['rooms'] ?? null;
        if (!is_array($rooms) || $rooms === []) {
            throw new \InvalidArgumentException('This session has no captured rooms to draw in 3D.');
        }
        $placements = self::placements($rooms);
        $positions = [];
        $normals = [];
        $colors = [];
        $indices = [];
        foreach ($rooms as $i => $room) {
            self::appendRoom($room, $placements[$i], $positions, $normals, $colors, $indices);
            if (intdiv(count($indices), 3) > self::MAX_TRIANGLES) {
                throw new \InvalidArgumentException(sprintf(
                    'This floor plan needs more than %d triangles to draw in 3D.',
                    self::MAX_TRIANGLES
                ));
            }
        }
        if ($positions === []) {
            throw new \InvalidArgumentException('The captured rooms produced no usable 3D geometry.');
        }
        return self::packGlb($positions, $normals, $colors, $indices);
    }

    private static function placements(array $rooms): array
    {
        $allHaveOrigin = true;
        foreach ($rooms as $room) {
            if (!isset($room['structure_origin_m'])
                || !is_array($room['structure_origin_m'])
                || count($room['structure_origin_m']) < 2) {
                $allHaveOrigin = false;
                break;
            }
        }
        $placements = [];
        if ($allHaveOrigin) {
            foreach ($rooms as $i => $room) {
                $placements[$i] = [(float) $room['structure_origin_m'][0], (float) $room['structure_origin_m'][1]];
            }
            return $placements;
        }
        $cursorX = 0.0;
        foreach ($rooms as $i => $room) {
            $outline = $room['outline_m'] ?? [];
            if (!is_array($outline) || $outline === []) {
                $placements[$i] = [$cursorX, 0.0];
                continue;
            }
            $xs = array_map(static fn ($p) => (float) $p[0], $outline);
            $width = max($xs) - min($xs);
            $placements[$i] = [$cursorX, 0.0];
            $cursorX += $width + 0.4;
        }
        return $placements;
    }

    private static function appendRoom(array $room, array $placement, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $outline = $room['outline_m'] ?? null;
        if (!is_array($outline) || count($outline) < 3) {
            return;
        }
        $outline = array_map(static fn ($p) => [(float) $p[0], (float) $p[1]], $outline);
        [$ox, $oz] = $placement;
        $height = isset($room['height_m']) && is_numeric($room['height_m']) && (float) $room['height_m'] > 0
            ? (float) $room['height_m']
            : self::DEFAULT_HEIGHT_M;
        $openings = is_array($room['openings'] ?? null) ? $room['openings'] : [];
        self::appendFloor($outline, $ox, $oz, $positions, $normals, $colors, $indices);
        self::appendWalls($outline, $ox, $oz, $height, $openings, $positions, $normals, $colors, $indices);
    }

    private static function appendFloor(array $outline, float $ox, float $oz, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $triangles = self::triangulate($outline);
        if ($triangles === []) {
            return;
        }
        $base = intdiv(count($positions), 3);
        foreach ($outline as $p) {
            $positions[] = $p[0] + $ox;
            $positions[] = 0.0;
            $positions[] = $p[1] + $oz;
            $normals[] = 0.0;
            $normals[] = 1.0;
            $normals[] = 0.0;
            foreach (self::FLOOR_COLOR as $c) {
                $colors[] = $c;
            }
        }
        foreach ($triangles as $tri) {
            $indices[] = $base + $tri[0];
            $indices[] = $base + $tri[1];
            $indices[] = $base + $tri[2];
        }
    }

    private static function appendWalls(array $outline, float $ox, float $oz, float $height, array $openings, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $n = count($outline);
        $signed = self::signedArea($outline);
        $inward = $signed >= 0 ? 1.0 : -1.0;
        for ($i = 0; $i < $n; $i++) {
            $a = $outline[$i];
            $b = $outline[($i + 1) % $n];
            $dx = $b[0] - $a[0];
            $dz = $b[1] - $a[1];
            $len = sqrt($dx * $dx + $dz * $dz);
            if ($len < 1e-6) {
                continue;
            }
            $ux = $dx / $len;
            $uz = $dz / $len;
            $nx = -$uz * $inward;
            $nz = $ux * $inward;
            foreach (self::wallSegments($a, $len, $ux, $uz, $openings) as $seg) {
                $pa = [$a[0] + $ux * $seg[0], $a[1] + $uz * $seg[0]];
                $pb = [$a[0] + $ux * $seg[1], $a[1] + $uz * $seg[1]];
                self::appendWallBox($pa, $pb, $ux, $uz, $nx, $nz, $height, $ox, $oz, $positions, $normals, $colors, $indices);
            }
        }
    }

    private static function wallSegments(array $a, float $len, float $ux, float $uz, array $openings): array
    {
        $spans = [];
        foreach ($openings as $opening) {
            $pos = $opening['position_m'] ?? null;
            if (!is_array($pos) || count($pos) < 2) {
                continue;
            }
            $px = (float) $pos[0];
            $pz = (float) $pos[1];
            $t = ($px - $a[0]) * $ux + ($pz - $a[1]) * $uz;
            $perp = abs(($px - $a[0]) * $uz - ($pz - $a[1]) * $ux);
            if ($perp > self::MAX_OPENING_WALL_DISTANCE_M) {
                continue;
            }
            if ($t < -0.3 || $t > $len + 0.3) {
                continue;
            }
            $category = (string) ($opening['category'] ?? 'opening');
            $rawWidth = $opening['width_m'] ?? null;
            if (is_numeric($rawWidth) && (float) $rawWidth >= 0.2 && (float) $rawWidth <= 6.0) {
                $width = (float) $rawWidth;
            } else {
                $width = match ($category) {
                    'door' => 0.9,
                    'window' => 1.2,
                    default => 0.8,
                };
            }
            $spans[] = [max(0.0, $t - $width / 2), min($len, $t + $width / 2)];
        }
        if ($spans === []) {
            return [[0.0, $len]];
        }
        usort($spans, static fn (array $x, array $y) => $x[0] <=> $y[0]);
        $merged = [];
        foreach ($spans as $span) {
            if ($merged === [] || $span[0] > $merged[count($merged) - 1][1] + 1e-6) {
                $merged[] = $span;
            } else {
                $last = array_pop($merged);
                $merged[] = [$last[0], max($last[1], $span[1])];
            }
        }
        $result = [];
        $cursor = 0.0;
        foreach ($merged as $span) {
            if ($span[0] > $cursor + 1e-6) {
                $result[] = [$cursor, $span[0]];
            }
            $cursor = max($cursor, $span[1]);
        }
        if ($cursor < $len - 1e-6) {
            $result[] = [$cursor, $len];
        }
        return $result;
    }

    private static function appendWallBox(array $a, array $b, float $ux, float $uz, float $nx, float $nz, float $height, float $ox, float $oz, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $half = self::WALL_THICKNESS_M / 2;
        $iA0 = [$a[0] + $nx * $half + $ox, 0.0, $a[1] + $nz * $half + $oz];
        $iB0 = [$b[0] + $nx * $half + $ox, 0.0, $b[1] + $nz * $half + $oz];
        $iAh = [$a[0] + $nx * $half + $ox, $height, $a[1] + $nz * $half + $oz];
        $iBh = [$b[0] + $nx * $half + $ox, $height, $b[1] + $nz * $half + $oz];
        $oA0 = [$a[0] - $nx * $half + $ox, 0.0, $a[1] - $nz * $half + $oz];
        $oB0 = [$b[0] - $nx * $half + $ox, 0.0, $b[1] - $nz * $half + $oz];
        $oAh = [$a[0] - $nx * $half + $ox, $height, $a[1] - $nz * $half + $oz];
        $oBh = [$b[0] - $nx * $half + $ox, $height, $b[1] - $nz * $half + $oz];
        self::appendQuad($iA0, $iB0, $iBh, $iAh, [$nx, 0.0, $nz], $positions, $normals, $colors, $indices);
        self::appendQuad($oA0, $oB0, $oBh, $oAh, [-$nx, 0.0, -$nz], $positions, $normals, $colors, $indices);
        self::appendQuad($iA0, $oA0, $oB0, $iB0, [0.0, -1.0, 0.0], $positions, $normals, $colors, $indices);
        self::appendQuad($iAh, $oAh, $oBh, $iBh, [0.0, 1.0, 0.0], $positions, $normals, $colors, $indices);
        self::appendQuad($iA0, $oA0, $oAh, $iAh, [-$ux, 0.0, -$uz], $positions, $normals, $colors, $indices);
        self::appendQuad($iB0, $oB0, $oBh, $iBh, [$ux, 0.0, $uz], $positions, $normals, $colors, $indices);
    }

    private static function appendQuad(array $p0, array $p1, array $p2, array $p3, array $normal, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $base = intdiv(count($positions), 3);
        foreach ([$p0, $p1, $p2, $p3] as $p) {
            $positions[] = $p[0];
            $positions[] = $p[1];
            $positions[] = $p[2];
            $normals[] = $normal[0];
            $normals[] = $normal[1];
            $normals[] = $normal[2];
            foreach (self::WALL_COLOR as $c) {
                $colors[] = $c;
            }
        }
        $indices[] = $base;
        $indices[] = $base + 1;
        $indices[] = $base + 2;
        $indices[] = $base;
        $indices[] = $base + 2;
        $indices[] = $base + 3;
    }

    private static function triangulate(array $polygon): array
    {
        if (count($polygon) < 3) {
            return [];
        }
        if (self::signedArea($polygon) < 0) {
            $polygon = array_reverse($polygon);
        }
        $indices = range(0, count($polygon) - 1);
        $triangles = [];
        $guard = 0;
        while (count($indices) > 3 && $guard < 10000) {
            $guard++;
            $found = false;
            $m = count($indices);
            for ($i = 0; $i < $m; $i++) {
                $iPrev = $indices[($i - 1 + $m) % $m];
                $iCurr = $indices[$i];
                $iNext = $indices[($i + 1) % $m];
                $a = $polygon[$iPrev];
                $b = $polygon[$iCurr];
                $c = $polygon[$iNext];
                $cross = ($b[0] - $a[0]) * ($c[1] - $a[1]) - ($b[1] - $a[1]) * ($c[0] - $a[0]);
                if ($cross <= 1e-9) {
                    continue;
                }
                $isEar = true;
                foreach ($indices as $j) {
                    if ($j === $iPrev || $j === $iCurr || $j === $iNext) {
                        continue;
                    }
                    if (self::pointInTriangle($polygon[$j], $a, $b, $c)) {
                        $isEar = false;
                        break;
                    }
                }
                if ($isEar) {
                    $triangles[] = [$iPrev, $iCurr, $iNext];
                    array_splice($indices, $i, 1);
                    $found = true;
                    break;
                }
            }
            if (!$found) {
                break;
            }
        }
        if (count($indices) === 3) {
            $triangles[] = $indices;
        }
        return $triangles;
    }

    private static function signedArea(array $polygon): float
    {
        $sum = 0.0;
        $n = count($polygon);
        for ($i = 0; $i < $n; $i++) {
            $sum += $polygon[$i][0] * $polygon[($i + 1) % $n][1]
                - $polygon[($i + 1) % $n][0] * $polygon[$i][1];
        }
        return $sum / 2.0;
    }

    private static function pointInTriangle(array $p, array $a, array $b, array $c): bool
    {
        $d1 = ($b[0] - $a[0]) * ($p[1] - $a[1]) - ($b[1] - $a[1]) * ($p[0] - $a[0]);
        $d2 = ($c[0] - $b[0]) * ($p[1] - $b[1]) - ($c[1] - $b[1]) * ($p[0] - $b[0]);
        $d3 = ($a[0] - $c[0]) * ($p[1] - $c[1]) - ($a[1] - $c[1]) * ($p[0] - $c[0]);
        $hasNeg = $d1 < 0 || $d2 < 0 || $d3 < 0;
        $hasPos = $d1 > 0 || $d2 > 0 || $d3 > 0;
        return !($hasNeg && $hasPos);
    }

    private static function align4(int $n): int
    {
        return ($n + 3) & ~3;
    }

    private static function packGlb(array $positions, array $normals, array $colors, array $indices): string
    {
        $vertexCount = intdiv(count($positions), 3);
        $positionsData = pack('f*', ...$positions);
        $normalsData = pack('f*', ...$normals);
        $colorsData = pack('f*', ...$colors);
        $indicesData = pack('V*', ...$indices);

        $posLen = strlen($positionsData);
        $nrmLen = strlen($normalsData);
        $colLen = strlen($colorsData);
        $idxLen = strlen($indicesData);

        $posOffset = 0;
        $nrmOffset = self::align4($posOffset + $posLen);
        $colOffset = self::align4($nrmOffset + $nrmLen);
        $idxOffset = self::align4($colOffset + $colLen);
        $binLen = self::align4($idxOffset + $idxLen);

        $bin = str_pad($positionsData, $nrmOffset, "\0");
        $bin .= str_pad($normalsData, $colOffset - $nrmOffset, "\0");
        $bin .= str_pad($colorsData, $idxOffset - $colOffset, "\0");
        $bin .= str_pad($indicesData, $binLen - $idxOffset, "\0");

        $minPos = [INF, INF, INF];
        $maxPos = [-INF, -INF, -INF];
        for ($i = 0; $i < count($positions); $i += 3) {
            for ($k = 0; $k < 3; $k++) {
                $v = (float) $positions[$i + $k];
                if ($v < $minPos[$k]) $minPos[$k] = $v;
                if ($v > $maxPos[$k]) $maxPos[$k] = $v;
            }
        }

        $gltf = [
            'asset' => ['version' => '2.0', 'generator' => 'Vuuro Scan'],
            'scene' => 0,
            'scenes' => [['nodes' => [0]]],
            'nodes' => [['mesh' => 0]],
            'meshes' => [[
                'primitives' => [[
                    'attributes' => ['POSITION' => 0, 'NORMAL' => 1, 'COLOR_0' => 2],
                    'indices' => 3,
                    'mode' => 4,
                ]],
            ]],
            'accessors' => [
                ['bufferView' => 0, 'componentType' => 5126, 'count' => $vertexCount, 'type' => 'VEC3', 'min' => $minPos, 'max' => $maxPos],
                ['bufferView' => 1, 'componentType' => 5126, 'count' => $vertexCount, 'type' => 'VEC3'],
                ['bufferView' => 2, 'componentType' => 5126, 'count' => $vertexCount, 'type' => 'VEC4'],
                ['bufferView' => 3, 'componentType' => 5125, 'count' => count($indices), 'type' => 'SCALAR'],
            ],
            'bufferViews' => [
                ['buffer' => 0, 'byteOffset' => $posOffset, 'byteLength' => $posLen, 'target' => 34962],
                ['buffer' => 0, 'byteOffset' => $nrmOffset, 'byteLength' => $nrmLen, 'target' => 34962],
                ['buffer' => 0, 'byteOffset' => $colOffset, 'byteLength' => $colLen, 'target' => 34962],
                ['buffer' => 0, 'byteOffset' => $idxOffset, 'byteLength' => $idxLen, 'target' => 34963],
            ],
            'buffers' => [['byteLength' => $binLen]],
        ];

        $json = json_encode($gltf, JSON_UNESCAPED_SLASHES);
        $jsonPad = self::align4(strlen($json)) - strlen($json);
        $json .= str_repeat(' ', $jsonPad);
        $binPad = self::align4(strlen($bin)) - strlen($bin);
        $bin .= str_repeat("\0", $binPad);

        $jsonLen = strlen($json);
        $finalBinLen = strlen($bin);
        $totalLen = 12 + 8 + $jsonLen + 8 + $finalBinLen;

        $glb = pack('V3', 0x46546C67, 2, $totalLen);
        $glb .= pack('V2', $jsonLen, 0x4E4F534A) . $json;
        $glb .= pack('V2', $finalBinLen, 0x004E4942) . $bin;
        return $glb;
    }
}
