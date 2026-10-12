<?php

declare(strict_types=1);

namespace VuuroScan;

final class RoomSplitter
{
    public const MIN_PART_AREA_M2 = 0.5;
    private const EPS = 1e-9;

    public static function cut(array $outline, array $openEdges, array $a, array $b): array
    {
        $points = array_map(static fn (array $p) => [(float) $p[0], (float) $p[1]], array_values($outline));
        $n = count($points);
        if ($n < 3) {
            throw new \InvalidArgumentException('This room has no usable outline to cut.');
        }
        $open = array_fill(0, $n, false);
        foreach ($openEdges as $edge) {
            if (is_int($edge) && $edge >= 0 && $edge < $n) {
                $open[$edge] = true;
            }
        }
        [$ax, $az] = [(float) $a[0], (float) $a[1]];
        [$bx, $bz] = [(float) $b[0], (float) $b[1]];
        $rx = $bx - $ax;
        $rz = $bz - $az;
        if (sqrt($rx * $rx + $rz * $rz) < 0.05) {
            throw new \InvalidArgumentException('The cut line is too short. Drag both ends across the room.');
        }

        $hits = [];
        for ($i = 0; $i < $n; $i++) {
            [$px, $pz] = $points[$i];
            [$qx, $qz] = $points[($i + 1) % $n];
            $sx = $qx - $px;
            $sz = $qz - $pz;
            $denominator = $rx * $sz - $rz * $sx;
            if (abs($denominator) < self::EPS) {
                continue;
            }
            $s = (($px - $ax) * $sz - ($pz - $az) * $sx) / $denominator;
            $t = (($px - $ax) * $rz - ($pz - $az) * $rx) / $denominator;
            if ($s < -self::EPS || $s > 1 + self::EPS || $t < -self::EPS || $t >= 1 - 1e-7) {
                continue;
            }
            $point = [$px + $t * $sx, $pz + $t * $sz];
            foreach ($hits as $hit) {
                if (abs($hit['point'][0] - $point[0]) < 1e-6 && abs($hit['point'][1] - $point[1]) < 1e-6) {
                    continue 2;
                }
            }
            $hits[] = ['edge' => $i, 't' => max(0.0, $t), 's' => $s, 'point' => $point];
        }
        if (count($hits) !== 2) {
            throw new \InvalidArgumentException(count($hits) < 2
                ? 'The cut line has to cross the room from one wall to another. Drag both ends outside the room.'
                : 'The cut line crosses the room outline more than twice. Use a shorter line that cuts off one part only.');
        }
        usort($hits, static fn (array $x, array $y) => $x['s'] <=> $y['s']);
        $mid = [($hits[0]['point'][0] + $hits[1]['point'][0]) / 2, ($hits[0]['point'][1] + $hits[1]['point'][1]) / 2];
        if (!self::contains($points, $mid[0], $mid[1])) {
            throw new \InvalidArgumentException('The cut line runs outside the room. Draw it across the part you want to separate.');
        }

        $ring = [];
        $flags = [];
        $hitIndex = [];
        for ($i = 0; $i < $n; $i++) {
            $ring[] = $points[$i];
            $flags[] = $open[$i];
            $onEdge = array_values(array_filter(array_keys($hits), static fn (int $k) => $hits[$k]['edge'] === $i));
            usort($onEdge, static fn (int $x, int $y) => $hits[$x]['t'] <=> $hits[$y]['t']);
            foreach ($onEdge as $k) {
                $hitIndex[$k] = count($ring);
                $ring[] = $hits[$k]['point'];
                $flags[] = $open[$i];
            }
        }

        $m = count($ring);
        $parts = [];
        foreach ([[$hitIndex[0], $hitIndex[1]], [$hitIndex[1], $hitIndex[0]]] as [$from, $to]) {
            $partPoints = [];
            $partFlags = [];
            $k = $from;
            while (true) {
                $partPoints[] = $ring[$k];
                if ($k === $to) {
                    $partFlags[] = true;
                    break;
                }
                $partFlags[] = $flags[$k];
                $k = ($k + 1) % $m;
            }
            [$partPoints, $partFlags] = self::dropDuplicates($partPoints, $partFlags);
            if (count($partPoints) < 3) {
                throw new \InvalidArgumentException('The cut line runs along a wall. Draw it across the room instead.');
            }
            $area = self::area($partPoints);
            if ($area < self::MIN_PART_AREA_M2) {
                throw new \InvalidArgumentException(sprintf('One side of the cut would only be %.2f m2. Move the line so both parts are at least %.1f m2.', $area, self::MIN_PART_AREA_M2));
            }
            $parts[] = ['points' => $partPoints, 'open_edges' => array_keys(array_filter($partFlags)), 'area' => $area];
        }
        return $parts;
    }

    public static function apply(array $room, array $a, array $b, array $keepPoint, string $mode, string $newRoomId, string $newLabel, ?array $assignedOrigin = null, ?string $assignedGroupId = null): array
    {
        return self::applyWithDetails($room, $a, $b, $keepPoint, $mode, $newRoomId, $newLabel, $assignedOrigin, $assignedGroupId)['rooms'];
    }

    public static function applyWithDetails(array $room, array $a, array $b, array $keepPoint, string $mode, string $newRoomId, string $newLabel, ?array $assignedOrigin = null, ?string $assignedGroupId = null): array
    {
        if ($mode !== 'split' && $mode !== 'trim') {
            throw new \InvalidArgumentException("mode must be 'split' or 'trim'.");
        }
        $parts = self::cut($room['outline_m'] ?? [], $room['open_edges'] ?? [], $a, $b);
        $keepIndex = null;
        foreach ($parts as $index => $part) {
            if (self::contains($part['points'], (float) $keepPoint[0], (float) $keepPoint[1])) {
                $keepIndex = $index;
                break;
            }
        }
        if ($keepIndex === null) {
            throw new \InvalidArgumentException('Tap inside the part that should keep this room\'s name.');
        }
        $otherIndex = 1 - $keepIndex;

        $openingOwner = [];
        foreach ($room['openings'] ?? [] as $i => $opening) {
            $openingOwner[$i] = self::nearestPart($parts, (float) $opening['position_m'][0], (float) $opening['position_m'][1], true);
        }
        $objectOwner = [];
        foreach ($room['objects'] ?? [] as $i => $object) {
            $objectOwner[$i] = self::ownerOf($parts, (float) $object['position_m'][0], (float) $object['position_m'][1]);
        }

        $order = $mode === 'split' ? [$keepIndex, $otherIndex] : [$keepIndex];
        $result = [];
        $details = [];
        foreach ($order as $partIndex) {
            $part = $parts[$partIndex];
            $minX = min(array_column($part['points'], 0));
            $minZ = min(array_column($part['points'], 1));
            $shift = static fn (array $p) => [round((float) $p[0] - $minX, 3), round((float) $p[1] - $minZ, 3)];

            $out = $room;
            $out['outline_m'] = array_map($shift, $part['points']);
            $out['open_edges'] = $part['open_edges'];
            $out['floor_area_m2'] = round($part['area'], 2);
            $out['perimeter_m'] = round(self::perimeter($part['points']), 2);
            $out['bounding_dimensions_m'] = [
                'width_m' => round(max(array_column($part['points'], 0)) - $minX, 2),
                'length_m' => round(max(array_column($part['points'], 1)) - $minZ, 2),
            ];
            $height = $room['height_m'] ?? null;
            $out['volume_m3_indicative'] = is_int($height) || is_float($height) ? round($part['area'] * $height, 2) : null;

            $out['openings'] = [];
            foreach ($room['openings'] ?? [] as $i => $opening) {
                if ($openingOwner[$i] === $partIndex) {
                    $opening['position_m'] = $shift($opening['position_m']);
                    $out['openings'][] = $opening;
                }
            }
            $out['objects'] = [];
            foreach ($room['objects'] ?? [] as $i => $object) {
                if ($objectOwner[$i] === $partIndex) {
                    $object['position_m'] = $shift($object['position_m']);
                    $out['objects'][] = $object;
                }
            }
            $out['walk_path_m'] = [];
            foreach ($room['walk_path_m'] ?? [] as $point) {
                if (self::contains($part['points'], (float) $point[0], (float) $point[1])) {
                    $out['walk_path_m'][] = $shift($point);
                }
            }

            $origin = $room['structure_origin_m'] ?? $assignedOrigin;
            if (is_array($origin)) {
                $out['structure_origin_m'] = [round((float) $origin[0] + $minX, 4), round((float) $origin[1] + $minZ, 4)];
                if (!isset($room['structure_origin_m']) && $assignedGroupId !== null) {
                    $out['capture_group_id'] = $assignedGroupId;
                }
            }

            if ($partIndex !== $keepIndex) {
                $out['room_id'] = $newRoomId;
                $out['label'] = $newLabel;
                $out['room_type'] = null;
            }
            $result[] = $out;
            $details[] = [
                'room_id' => $out['room_id'],
                'offset_m' => [round($minX, 6), round($minZ, 6)],
                'object_ids' => array_column($out['objects'], 'object_id'),
            ];
        }
        return ['rooms' => $result, 'details' => $details];
    }

    public static function contains(array $points, float $x, float $z): bool
    {
        $inside = false;
        $n = count($points);
        for ($i = 0, $j = $n - 1; $i < $n; $j = $i++) {
            [$xi, $zi] = $points[$i];
            [$xj, $zj] = $points[$j];
            if (($zi > $z) !== ($zj > $z) && $x < ($xj - $xi) * ($z - $zi) / ($zj - $zi) + $xi) {
                $inside = !$inside;
            }
        }
        return $inside;
    }

    private static function ownerOf(array $parts, float $x, float $z): int
    {
        foreach ($parts as $index => $part) {
            if (self::contains($part['points'], $x, $z)) {
                return $index;
            }
        }
        return self::nearestPart($parts, $x, $z, false);
    }

    private static function nearestPart(array $parts, float $x, float $z, bool $wallsOnly): int
    {
        $best = 0;
        $bestDistance = INF;
        foreach ($parts as $index => $part) {
            $points = $part['points'];
            $count = count($points);
            $openSet = array_flip($part['open_edges']);
            for ($i = 0; $i < $count; $i++) {
                if ($wallsOnly && isset($openSet[$i])) {
                    continue;
                }
                $distance = self::segmentDistance($x, $z, $points[$i], $points[($i + 1) % $count]);
                if ($distance < $bestDistance) {
                    $bestDistance = $distance;
                    $best = $index;
                }
            }
        }
        return $best;
    }

    private static function segmentDistance(float $x, float $z, array $p, array $q): float
    {
        $dx = $q[0] - $p[0];
        $dz = $q[1] - $p[1];
        $lengthSquared = $dx * $dx + $dz * $dz;
        $t = $lengthSquared < self::EPS ? 0.0 : max(0.0, min(1.0, (($x - $p[0]) * $dx + ($z - $p[1]) * $dz) / $lengthSquared));
        return sqrt(($x - $p[0] - $t * $dx) ** 2 + ($z - $p[1] - $t * $dz) ** 2);
    }

    private static function dropDuplicates(array $points, array $flags): array
    {
        $changed = true;
        while ($changed && count($points) > 2) {
            $changed = false;
            $count = count($points);
            for ($i = 0; $i < $count; $i++) {
                $next = ($i + 1) % $count;
                if (abs($points[$i][0] - $points[$next][0]) < 1e-6 && abs($points[$i][1] - $points[$next][1]) < 1e-6) {
                    array_splice($points, $next, 1);
                    $flags[$i] = $flags[$next];
                    array_splice($flags, $next, 1);
                    $changed = true;
                    break;
                }
            }
        }
        return [array_values($points), array_values($flags)];
    }

    private static function area(array $points): float
    {
        $sum = 0.0;
        $n = count($points);
        for ($i = 0; $i < $n; $i++) {
            [$x1, $z1] = $points[$i];
            [$x2, $z2] = $points[($i + 1) % $n];
            $sum += $x1 * $z2 - $x2 * $z1;
        }
        return abs($sum) / 2;
    }

    private static function perimeter(array $points): float
    {
        $sum = 0.0;
        $n = count($points);
        for ($i = 0; $i < $n; $i++) {
            [$x1, $z1] = $points[$i];
            [$x2, $z2] = $points[($i + 1) % $n];
            $sum += sqrt(($x2 - $x1) ** 2 + ($z2 - $z1) ** 2);
        }
        return $sum;
    }
}
