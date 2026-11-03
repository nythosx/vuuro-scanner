<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class StandDepthCube
{
    public const VERSION = 'depth-1';
    public const FACE_PX = 256;
    public const MIN_COVERAGE = 0.3;
    public const EYE_HEIGHT_M = 1.4;
    public const MIN_EYE_M = 0.6;
    public const MAX_EYE_M = 2.4;
    private const MIN_RANGE_M = 0.2;
    private const MERGE_RATIO = 0.05;
    private const FILL_PASSES = 3;
    private const FILL_MIN_NEIGHBOURS = 3;

    public static function center(array $centerXZ, array $photos): array
    {
        $heights = [];
        foreach ($photos as $photo) {
            $m = $photo['camera_transform'] ?? null;
            $y = is_array($m) && count($m) === 16 && is_numeric($m[13]) ? (float) $m[13] : NAN;
            if (is_finite($y) && $y >= self::MIN_EYE_M && $y <= self::MAX_EYE_M) {
                $heights[] = $y;
            }
        }
        sort($heights);
        $eye = $heights === [] ? self::EYE_HEIGHT_M : $heights[intdiv(count($heights), 2)];
        return [(float) $centerXZ[0], $eye, (float) $centerXZ[1]];
    }

    public static function usable(array $photo, string $bytes): bool
    {
        $m = $photo['camera_transform'] ?? null;
        $k = $photo['depth_intrinsics'] ?? null;
        $w = (int) ($photo['depth_width'] ?? 0);
        $h = (int) ($photo['depth_height'] ?? 0);
        if (!is_array($m) || count($m) !== 16 || !is_array($k) || count($k) !== 4 || $w <= 0 || $h <= 0) {
            return false;
        }
        foreach ($m as $value) {
            if ((!is_int($value) && !is_float($value)) || !is_finite((float) $value)) {
                return false;
            }
        }
        foreach ($k as $value) {
            if ((!is_int($value) && !is_float($value)) || !is_finite((float) $value) || (float) $value <= 0) {
                return false;
            }
        }
        return strlen($bytes) === $w * $h * 2;
    }

    public static function render(array $sources, array $center, int $size = self::FACE_PX): array
    {
        $faceCount = count(StandSkybox::FACES);
        $total = $faceCount * $size * $size;
        $near = array_fill(0, $total, 0.0);
        $sum = array_fill(0, $total, 0.0);
        $count = array_fill(0, $total, 0);
        $bases = [];
        foreach (StandSkybox::FACES as $face) {
            $bases[] = StandSkybox::faceBasis($face);
        }
        [$c0, $c1, $c2] = $center;
        $half = $size / 2;
        $used = 0;

        foreach ($sources as $source) {
            $photo = $source['photo'];
            $bytes = (string) $source['bytes'];
            if (!self::usable($photo, $bytes)) {
                continue;
            }
            $used++;
            $m = array_map('floatval', $photo['camera_transform']);
            [$fx, $fy, $cx, $cy] = array_map('floatval', $photo['depth_intrinsics']);
            $w = (int) $photo['depth_width'];
            $h = (int) $photo['depth_height'];
            $values = unpack('v*', $bytes);
            $ax = [];
            for ($u = 0; $u < $w; $u++) {
                $ax[$u] = ($u + 0.5 - $cx) / $fx;
            }
            $tx = $m[12] - $c0;
            $ty = $m[13] - $c1;
            $tz = $m[14] - $c2;
            $i = 1;
            for ($v = 0; $v < $h; $v++) {
                $by = -($v + 0.5 - $cy) / $fy;
                $rx = $m[4] * $by - $m[8];
                $ry = $m[5] * $by - $m[9];
                $rz = $m[6] * $by - $m[10];
                for ($u = 0; $u < $w; $u++, $i++) {
                    $mm = $values[$i];
                    if ($mm === 0) {
                        continue;
                    }
                    $d = $mm * 0.001;
                    $a = $ax[$u];
                    $px = ($m[0] * $a + $rx) * $d + $tx;
                    $py = ($m[1] * $a + $ry) * $d + $ty;
                    $pz = ($m[2] * $a + $rz) * $d + $tz;
                    $qx = $px < 0 ? -$px : $px;
                    $qy = $py < 0 ? -$py : $py;
                    $qz = $pz < 0 ? -$pz : $pz;
                    if ($qx >= $qy && $qx >= $qz) {
                        if ($qx < 1e-6) {
                            continue;
                        }
                        if ($px > 0) {
                            $f = 1;
                            $s = $pz / $qx;
                        } else {
                            $f = 3;
                            $s = -$pz / $qx;
                        }
                        $t = $py / $qx;
                    } elseif ($qy >= $qz) {
                        $s = $px / $qy;
                        if ($py > 0) {
                            $f = 4;
                            $t = $pz / $qy;
                        } else {
                            $f = 5;
                            $t = -$pz / $qy;
                        }
                    } else {
                        $t = $py / $qz;
                        if ($pz < 0) {
                            $f = 0;
                            $s = $px / $qz;
                        } else {
                            $f = 2;
                            $s = -$px / $qz;
                        }
                    }
                    $r = sqrt($px * $px + $py * $py + $pz * $pz);
                    if ($r < self::MIN_RANGE_M || $r > 65.0) {
                        continue;
                    }
                    $gx = (int) (($s + 1) * $half);
                    $gy = (int) ((1 - $t) * $half);
                    if ($gx >= $size) {
                        $gx = $size - 1;
                    }
                    if ($gy >= $size) {
                        $gy = $size - 1;
                    }
                    if ($gx < 0) {
                        $gx = 0;
                    }
                    if ($gy < 0) {
                        $gy = 0;
                    }
                    $idx = ($f * $size + $gy) * $size + $gx;
                    $cur = $near[$idx];
                    if ($cur === 0.0 || $r < $cur * (1 - self::MERGE_RATIO)) {
                        $near[$idx] = $r;
                        $sum[$idx] = $r;
                        $count[$idx] = 1;
                    } elseif ($r <= $cur * (1 + self::MERGE_RATIO)) {
                        if ($r < $cur) {
                            $near[$idx] = $r;
                        }
                        $sum[$idx] += $r;
                        $count[$idx]++;
                    }
                }
            }
        }

        $depth = array_fill(0, $total, 0.0);
        $measured = 0;
        for ($idx = 0; $idx < $total; $idx++) {
            if ($count[$idx] > 0) {
                $depth[$idx] = $sum[$idx] / $count[$idx];
                $measured++;
            }
        }
        unset($near, $sum, $count);

        for ($pass = 0; $pass < self::FILL_PASSES; $pass++) {
            $depth = self::fillPass($depth, $faceCount, $size);
        }

        $filled = 0;
        $mm = [];
        for ($idx = 0; $idx < $total; $idx++) {
            $r = $depth[$idx];
            if ($r > 0) {
                $filled++;
                $mm[] = min(65535, (int) round($r * 1000));
            } else {
                $mm[] = 0;
            }
        }
        $bytes = '';
        foreach (array_chunk($mm, 8192) as $chunk) {
            $bytes .= pack('v*', ...$chunk);
        }

        return [
            'size' => $size,
            'center_m' => [round($center[0], 4), round($center[1], 4), round($center[2], 4)],
            'photos' => $used,
            'measured' => $total > 0 ? round($measured / $total, 4) : 0.0,
            'coverage' => $total > 0 ? round($filled / $total, 4) : 0.0,
            'bytes' => $bytes,
            'values' => $depth,
        ];
    }

    private static function fillPass(array $depth, int $faceCount, int $size): array
    {
        $out = $depth;
        for ($f = 0; $f < $faceCount; $f++) {
            $base = $f * $size * $size;
            for ($y = 0; $y < $size; $y++) {
                $row = $base + $y * $size;
                for ($x = 0; $x < $size; $x++) {
                    if ($depth[$row + $x] > 0) {
                        continue;
                    }
                    $found = [];
                    for ($dy = -1; $dy <= 1; $dy++) {
                        $yy = $y + $dy;
                        if ($yy < 0 || $yy >= $size) {
                            continue;
                        }
                        $nrow = $base + $yy * $size;
                        for ($dx = -1; $dx <= 1; $dx++) {
                            $xx = $x + $dx;
                            if (($dx === 0 && $dy === 0) || $xx < 0 || $xx >= $size) {
                                continue;
                            }
                            $value = $depth[$nrow + $xx];
                            if ($value > 0) {
                                $found[] = $value;
                            }
                        }
                    }
                    if (count($found) >= self::FILL_MIN_NEIGHBOURS) {
                        sort($found);
                        $out[$row + $x] = $found[intdiv(count($found), 2)];
                    }
                }
            }
        }
        return $out;
    }
}
