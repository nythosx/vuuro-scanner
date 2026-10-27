<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class DimensionRuns
{
    private const PERPENDICULAR_TOLERANCE_DEG = 10.0;
    private const MERGE_GAP_M = 0.05;
    private const MIN_WALL_M = 0.3;
    private const END_SNAP_M = 0.25;

    public static function forFused(array $rooms, array $poses, array $edgeTiers, int $axis): array
    {
        $outlines = [];
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i] ?? ['originX' => 0.0, 'originZ' => 0.0, 'rotationRad' => 0.0];
            $world = [];
            foreach ($room['outline_m'] ?? [] as $p) {
                $world[] = RoomFusionSolver::transformPoint($pose, (float) $p[0], (float) $p[1]);
            }
            $skip = array_flip($room['open_edges'] ?? []) + ($edgeTiers[$i] ?? []);
            $outlines[] = ['points' => $world, 'skip' => $skip];
        }
        return self::breakpoints($outlines, $axis);
    }

    public static function forOutline(array $points, int $axis, array $openEdges = [], ?string $side = null): array
    {
        $outlines = [['points' => $points, 'skip' => array_flip($openEdges)]];
        return $side === null ? self::breakpoints($outlines, $axis) : self::sideBreakpoints($outlines, $axis, $side);
    }

    public static function forFusedSide(array $rooms, array $poses, array $edgeTiers, int $axis, string $side): array
    {
        $outlines = [];
        foreach ($rooms as $i => $room) {
            $pose = $poses[$i] ?? ['originX' => 0.0, 'originZ' => 0.0, 'rotationRad' => 0.0];
            $world = [];
            foreach ($room['outline_m'] ?? [] as $p) {
                $world[] = RoomFusionSolver::transformPoint($pose, (float) $p[0], (float) $p[1]);
            }
            $skip = array_flip($room['open_edges'] ?? []) + ($edgeTiers[$i] ?? []);
            $outlines[] = ['points' => $world, 'skip' => $skip];
        }
        return self::sideBreakpoints($outlines, $axis, $side);
    }

    private static function sideBreakpoints(array $outlines, int $axis, string $side): array
    {
        $other = 1 - $axis;
        $sinTol = sin(deg2rad(self::PERPENDICULAR_TOLERANCE_DEG));
        $min = INF;
        $max = -INF;
        $walls = [];
        foreach ($outlines as $outline) {
            $points = $outline['points'];
            $n = count($points);
            if ($n < 3) {
                continue;
            }
            foreach ($points as $p) {
                $min = min($min, (float) $p[$axis]);
                $max = max($max, (float) $p[$axis]);
            }
            for ($k = 0; $k < $n; $k++) {
                if (isset($outline['skip'][$k])) {
                    continue;
                }
                $a = $points[$k];
                $b = $points[($k + 1) % $n];
                $len = hypot((float) $b[0] - (float) $a[0], (float) $b[1] - (float) $a[1]);
                $across = (float) $b[$other] - (float) $a[$other];
                if ($len < self::MIN_WALL_M || abs($across) > $len * $sinTol) {
                    continue;
                }
                $walls[] = [
                    'lo' => min((float) $a[$axis], (float) $b[$axis]),
                    'hi' => max((float) $a[$axis], (float) $b[$axis]),
                    'at' => ((float) $a[$other] + (float) $b[$other]) / 2.0,
                ];
            }
        }
        if (!is_finite($min) || !is_finite($max)) {
            return [];
        }

        $cuts = [$min, $max];
        foreach ($walls as $wall) {
            $cuts[] = $wall['lo'];
            $cuts[] = $wall['hi'];
        }
        sort($cuts);
        $stops = [];
        foreach ($cuts as $c) {
            if ($stops === [] || $c - end($stops) > self::MERGE_GAP_M) {
                $stops[] = $c;
            }
        }

        $facing = [];
        for ($i = 0; $i < count($stops) - 1; $i++) {
            $mid = ($stops[$i] + $stops[$i + 1]) / 2.0;
            $best = null;
            foreach ($walls as $wall) {
                if ($wall['lo'] > $mid || $wall['hi'] < $mid) {
                    continue;
                }
                if ($best === null || ($side === 'min' ? $wall['at'] < $best : $wall['at'] > $best)) {
                    $best = $wall['at'];
                }
            }
            $facing[] = $best;
        }

        $out = [$stops[0]];
        for ($i = 1; $i < count($stops) - 1; $i++) {
            $before = $facing[$i - 1];
            $after = $facing[$i];
            $same = $before === null || $after === null
                ? $before === $after
                : abs($before - $after) <= self::MIN_WALL_M;
            if (!$same) {
                $out[] = $stops[$i];
            }
        }
        $out[] = end($stops);

        return array_values(array_filter(
            $out,
            fn (float $v, int $i): bool => $i === 0 || $i === count($out) - 1 || ($v - $min > self::END_SNAP_M && $max - $v > self::END_SNAP_M),
            ARRAY_FILTER_USE_BOTH
        ));
    }

    public static function straightWalls(array $outline, array $skip = []): array
    {
        $n = count($outline);
        $edges = [];
        for ($k = 0; $k < $n; $k++) {
            $a = [(float) $outline[$k][0], (float) $outline[$k][1]];
            $b = [(float) $outline[($k + 1) % $n][0], (float) $outline[($k + 1) % $n][1]];
            $len = hypot($b[0] - $a[0], $b[1] - $a[1]);
            if ($len < self::MIN_WALL_M) {
                continue;
            }
            $edges[] = ['a' => $a, 'b' => $b, 'length' => $len, 'skip' => isset($skip[$k])];
        }
        $count = count($edges);
        if ($count === 0) {
            return [];
        }
        $continues = static function (array $first, array $next): bool {
            if ($first['skip'] || $next['skip']) {
                return false;
            }
            $d1 = [($first['b'][0] - $first['a'][0]) / $first['length'], ($first['b'][1] - $first['a'][1]) / $first['length']];
            $d2 = [($next['b'][0] - $next['a'][0]) / $next['length'], ($next['b'][1] - $next['a'][1]) / $next['length']];
            if ($d1[0] * $d2[0] + $d1[1] * $d2[1] < cos(deg2rad(self::PERPENDICULAR_TOLERANCE_DEG))) {
                return false;
            }
            $ox = $next['a'][0] - $first['a'][0];
            $oz = $next['a'][1] - $first['a'][1];
            return abs($ox * $d1[1] - $oz * $d1[0]) <= self::MIN_WALL_M;
        };

        $start = 0;
        for ($k = 0; $k < $count; $k++) {
            if (!$continues($edges[($k - 1 + $count) % $count], $edges[$k])) {
                $start = $k;
                break;
            }
        }

        $runs = [];
        for ($step = 0; $step < $count; $step++) {
            $edge = $edges[($start + $step) % $count];
            $last = $runs === [] ? null : $runs[count($runs) - 1];
            if ($last !== null && $continues($last['tail'], $edge)) {
                $runs[count($runs) - 1]['b'] = $edge['b'];
                $runs[count($runs) - 1]['length'] += $edge['length'];
                $runs[count($runs) - 1]['tail'] = $edge;
            } else {
                $runs[] = ['a' => $edge['a'], 'b' => $edge['b'], 'length' => $edge['length'], 'skip' => $edge['skip'], 'tail' => $edge];
            }
        }

        $out = [];
        foreach ($runs as $run) {
            if ($run['skip']) {
                continue;
            }
            $out[] = ['a' => $run['a'], 'b' => $run['b'], 'length' => $run['length']];
        }
        return $out;
    }

    private static function breakpoints(array $outlines, int $axis): array
    {
        $values = [];
        $min = INF;
        $max = -INF;
        $sinTol = sin(deg2rad(self::PERPENDICULAR_TOLERANCE_DEG));

        foreach ($outlines as $outline) {
            $points = $outline['points'];
            $n = count($points);
            if ($n < 3) {
                continue;
            }
            foreach ($points as $p) {
                $min = min($min, (float) $p[$axis]);
                $max = max($max, (float) $p[$axis]);
            }
            for ($k = 0; $k < $n; $k++) {
                if (isset($outline['skip'][$k])) {
                    continue;
                }
                $a = $points[$k];
                $b = $points[($k + 1) % $n];
                $along = (float) $b[$axis] - (float) $a[$axis];
                $len = hypot((float) $b[0] - (float) $a[0], (float) $b[1] - (float) $a[1]);
                if ($len < self::MIN_WALL_M || abs($along) > $len * $sinTol) {
                    continue;
                }
                $values[] = ((float) $a[$axis] + (float) $b[$axis]) / 2.0;
            }
        }

        if (!is_finite($min) || !is_finite($max)) {
            return [];
        }
        $values = array_values(array_filter(
            $values,
            fn (float $v): bool => $v - $min > self::END_SNAP_M && $max - $v > self::END_SNAP_M
        ));
        $values[] = $min;
        $values[] = $max;
        sort($values);
        $out = [];
        foreach ($values as $v) {
            if ($out === [] || $v - end($out) > self::MERGE_GAP_M) {
                $out[] = $v;
            }
        }
        return $out;
    }
}
