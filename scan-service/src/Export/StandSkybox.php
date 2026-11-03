<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class StandSkybox
{
    public const VERSION = 'sky-2';
    public const FACES = ['f', 'r', 'b', 'l', 'u', 'd'];
    public const MIN_FACE_PX = 256;
    public const MAX_FACE_PX = 1024;
    public const JPEG_QUALITY = 85;
    public const GAIN_MIN = 0.6;
    public const GAIN_MAX = 1.67;
    private const PHOTO_FOV_DEG = 60.0;
    private const FEATHER = 0.12;
    private const FILL_WEIGHT = 1e-7;
    private const SMALL_PX = 48;
    private const TILE_PX = 32;
    private const TILE_SLACK_RAD = 0.3;
    private const GAIN_SAMPLES = 2500;
    private const GAIN_EDGE = 0.1;
    private const GAIN_PRIOR = 2.0;
    private const GAIN_ITERATIONS = 60;
    private const OCCLUSION_RATIO = 1.05;
    private const OCCLUSION_SLACK_M = 0.05;

    public static function faceBasis(string $face): array
    {
        return match ($face) {
            'f' => ['fwd' => [0.0, 0.0, -1.0], 'right' => [1.0, 0.0, 0.0], 'up' => [0.0, 1.0, 0.0]],
            'r' => ['fwd' => [1.0, 0.0, 0.0], 'right' => [0.0, 0.0, 1.0], 'up' => [0.0, 1.0, 0.0]],
            'b' => ['fwd' => [0.0, 0.0, 1.0], 'right' => [-1.0, 0.0, 0.0], 'up' => [0.0, 1.0, 0.0]],
            'l' => ['fwd' => [-1.0, 0.0, 0.0], 'right' => [0.0, 0.0, -1.0], 'up' => [0.0, 1.0, 0.0]],
            'u' => ['fwd' => [0.0, 1.0, 0.0], 'right' => [1.0, 0.0, 0.0], 'up' => [0.0, 0.0, 1.0]],
            'd' => ['fwd' => [0.0, -1.0, 0.0], 'right' => [1.0, 0.0, 0.0], 'up' => [0.0, 0.0, -1.0]],
            default => throw new \InvalidArgumentException("Unknown skybox face '{$face}'."),
        };
    }

    public static function cacheKey(array $photos, callable $fileStamp): string
    {
        $parts = [self::VERSION, StandDepthCube::VERSION];
        usort($photos, static fn (array $a, array $b): int => strcmp((string) ($a['photo_id'] ?? ''), (string) ($b['photo_id'] ?? '')));
        foreach ($photos as $photo) {
            $parts[] = json_encode([
                $photo['photo_id'] ?? null,
                $photo['url'] ?? null,
                $photo['camera_transform'] ?? null,
                $photo['intrinsics'] ?? null,
                $photo['heading_deg'] ?? null,
                $photo['pitch_deg'] ?? null,
                $photo['zoom'] ?? null,
                $photo['has_depth'] ?? null,
                $photo['depth_intrinsics'] ?? null,
                $fileStamp((string) ($photo['url'] ?? '')),
            ]);
        }
        return substr(hash('sha256', implode("\n", $parts)), 0, 24);
    }

    public static function pose(array $photo): array
    {
        $m = self::transform($photo);
        if ($m !== null && ($m[8] !== 0.0 || $m[9] !== 0.0 || $m[10] !== 0.0)) {
            $c0 = self::normalize([$m[0], $m[1], $m[2]]);
            $c1 = self::normalize([$m[4], $m[5], $m[6]]);
            $fwd = self::neg(self::normalize([$m[8], $m[9], $m[10]]));
            if (abs($m[5]) > abs($m[1])) {
                return $m[5] >= 0
                    ? ['fwd' => $fwd, 'right' => $c0, 'up' => $c1]
                    : ['fwd' => $fwd, 'right' => self::neg($c0), 'up' => self::neg($c1)];
            }
            return $m[1] <= 0
                ? ['fwd' => $fwd, 'right' => $c1, 'up' => self::neg($c0)]
                : ['fwd' => $fwd, 'right' => self::neg($c1), 'up' => $c0];
        }
        $b = deg2rad(self::bearing($photo));
        $p = deg2rad(is_numeric($photo['pitch_deg'] ?? null) ? (float) $photo['pitch_deg'] : 0.0);
        $f = [sin($b) * cos($p), sin($p), -cos($b) * cos($p)];
        $r = [cos($b), 0.0, sin($b)];
        return ['fwd' => $f, 'right' => $r, 'up' => self::cross($r, $f)];
    }

    public static function frame(array $photo, int $width, int $height): array
    {
        $k = $photo['intrinsics'] ?? null;
        if (is_array($k) && count($k) === 4 && self::allPositive($k)) {
            [$fx, $fy, $cx, $cy] = array_map('floatval', array_values($k));
            if ($width > 0 && $height > 0) {
                $scale = $width / (2 * $cx);
                if (abs($scale - 1) > 0.2) {
                    $fx *= $scale;
                    $fy *= $scale;
                    $cx *= $scale;
                    $cy *= $scale;
                }
            } else {
                $width = (int) round(2 * $cx);
                $height = (int) round(2 * $cy);
            }
            return ['left' => -$cx / $fx, 'right' => ($width - $cx) / $fx, 'top' => $cy / $fy, 'bottom' => -($height - $cy) / $fy];
        }
        $zoom = is_numeric($photo['zoom'] ?? null) && (float) $photo['zoom'] > 1 ? (float) $photo['zoom'] : 1.0;
        $halfW = tan(deg2rad(self::PHOTO_FOV_DEG) / 2) / $zoom;
        $aspect = $width > 0 && $height > 0 ? $height / $width : 0.75;
        return ['left' => -$halfW, 'right' => $halfW, 'top' => $halfW * $aspect, 'bottom' => -$halfW * $aspect];
    }

    public static function faceSize(array $items): int
    {
        $best = 0.0;
        foreach ($items as $item) {
            $frame = self::frame($item['photo'], $item['width'], $item['height']);
            $span = $frame['right'] - $frame['left'];
            if ($span > 0) {
                $best = max($best, $item['width'] / $span);
            }
        }
        $size = (int) (ceil(2 * $best / 128) * 128);
        return max(self::MIN_FACE_PX, min(self::MAX_FACE_PX, $size));
    }

    public static function render(array $sources, ?int $faceSize = null, ?array $depth = null): array
    {
        $items = [];
        foreach ($sources as $source) {
            $image = @imagecreatefromstring((string) $source['bytes']);
            if ($image === false) {
                continue;
            }
            if (!imageistruecolor($image)) {
                imagepalettetotruecolor($image);
            }
            $items[] = [
                'photo' => $source['photo'],
                'image' => $image,
                'width' => imagesx($image),
                'height' => imagesy($image),
                'depth' => isset($source['depth']) && is_string($source['depth']) ? $source['depth'] : null,
            ];
        }
        if (count($items) < 2) {
            throw new \InvalidArgumentException('A 360 spot needs at least two readable photos to stitch.');
        }
        if ($depth !== null && !self::validDepth($depth)) {
            $depth = null;
        }

        $size = $faceSize ?? self::faceSize($items);
        $prepared = self::prepare($items, $size, $depth);
        $gains = self::exposureGains($prepared, $depth);
        foreach ($prepared as $i => $p) {
            $prepared[$i]['gain'] = [$gains[$i], $gains[$i], $gains[$i]];
        }
        $fill = self::fillColors($prepared, $gains);
        $faces = [];
        foreach (self::FACES as $index => $face) {
            $faces[$face] = self::renderFace(self::faceBasis($face), $index, $size, $prepared, $fill, $depth);
        }
        return ['size' => $size, 'faces' => $faces, 'gains' => array_map(static fn (float $g): float => round($g, 4), $gains)];
    }

    public static function exposureGainsFor(array $observations, int $count): array
    {
        $pairs = [];
        foreach ($observations as $seen) {
            $n = count($seen);
            for ($a = 0; $a < $n; $a++) {
                for ($b = 0; $b < $n; $b++) {
                    if ($a !== $b) {
                        $pairs[$seen[$a][0]][$seen[$b][0]][] = $seen[$a][1] - $seen[$b][1];
                    }
                }
            }
        }
        $links = array_fill(0, $count, []);
        foreach ($pairs as $i => $others) {
            foreach ($others as $j => $diffs) {
                sort($diffs);
                $links[$i][] = [$j, $diffs[intdiv(count($diffs), 2)], count($diffs)];
            }
        }
        $g = array_fill(0, $count, 0.0);
        for ($it = 0; $it < self::GAIN_ITERATIONS; $it++) {
            for ($i = 0; $i < $count; $i++) {
                if ($links[$i] === []) {
                    continue;
                }
                $sum = 0.0;
                $weight = 0.0;
                foreach ($links[$i] as [$j, $d, $w]) {
                    $sum += ($g[$j] - $d) * $w;
                    $weight += $w;
                }
                $g[$i] = $sum / ($weight + self::GAIN_PRIOR);
            }
            $shift = array_sum($g) / $count;
            foreach ($g as $i => $value) {
                $g[$i] = $value - $shift;
            }
        }
        $mean = $count > 0 ? array_sum($g) / $count : 0.0;
        $lo = log(self::GAIN_MIN);
        $hi = log(self::GAIN_MAX);
        return array_map(static fn (float $v): float => exp(max($lo, min($hi, $v - $mean))), $g);
    }

    private static function validDepth(array $depth): bool
    {
        $size = (int) ($depth['size'] ?? 0);
        return $size > 0
            && is_array($depth['values'] ?? null)
            && count($depth['values']) === count(self::FACES) * $size * $size
            && is_array($depth['center'] ?? null)
            && count($depth['center']) === 3;
    }

    private static function transform(array $photo): ?array
    {
        $m = $photo['camera_transform'] ?? null;
        if (!is_array($m) || count($m) !== 16) {
            return null;
        }
        $out = [];
        foreach (array_values($m) as $value) {
            if ((!is_int($value) && !is_float($value)) || !is_finite((float) $value)) {
                return null;
            }
            $out[] = (float) $value;
        }
        return $out;
    }

    private static function prepare(array $items, int $faceSize, ?array $depth): array
    {
        $prepared = [];
        foreach ($items as $item) {
            $frame = self::frame($item['photo'], $item['width'], $item['height']);
            if ($frame['right'] <= $frame['left'] || $frame['top'] <= $frame['bottom']) {
                continue;
            }
            $image = $item['image'];
            $width = $item['width'];
            $height = $item['height'];
            $small = imagecreatetruecolor(self::SMALL_PX, max(1, (int) round(self::SMALL_PX * $height / max(1, $width))));
            imagecopyresampled($small, $image, 0, 0, 0, 0, imagesx($small), imagesy($small), $width, $height);
            $limit = (int) ceil($faceSize / 2 * ($frame['right'] - $frame['left']) * 1.25);
            if ($width > $limit && $limit > 8) {
                $scaledHeight = max(1, (int) round($height * $limit / $width));
                $scaled = imagecreatetruecolor($limit, $scaledHeight);
                imagecopyresampled($scaled, $image, 0, 0, 0, 0, $limit, $scaledHeight, $width, $height);
                $image = $scaled;
                $width = $limit;
                $height = $scaledHeight;
            }
            $m = self::transform($item['photo']);
            $offset = [0.0, 0.0, 0.0];
            $occlusion = null;
            if ($depth !== null && $m !== null) {
                $offset = [$m[12] - $depth['center'][0], $m[13] - $depth['center'][1], $m[14] - $depth['center'][2]];
                if ($item['depth'] !== null && StandDepthCube::usable($item['photo'], $item['depth'])) {
                    $occlusion = [
                        'map' => array_values(unpack('v*', $item['depth'])),
                        'w' => (int) $item['photo']['depth_width'],
                        'h' => (int) $item['photo']['depth_height'],
                        'k' => array_map('floatval', $item['photo']['depth_intrinsics']),
                        'c0' => [$m[0], $m[1], $m[2]],
                        'c1' => [$m[4], $m[5], $m[6]],
                    ];
                }
            }
            $prepared[] = [
                'pose' => self::pose($item['photo']),
                'frame' => $frame,
                'image' => $image,
                'small' => $small,
                'width' => $width,
                'height' => $height,
                'mean' => self::mean($small),
                'offset' => $offset,
                'occlusion' => $occlusion,
            ];
        }
        return $prepared;
    }

    private static function depthAt(?array $depth, array $dir): float
    {
        if ($depth === null) {
            return 0.0;
        }
        [$x, $y, $z] = $dir;
        $ax = abs($x);
        $ay = abs($y);
        $az = abs($z);
        if ($ax >= $ay && $ax >= $az) {
            [$f, $s, $t] = $x > 0 ? [1, $z / $ax, $y / $ax] : [3, -$z / $ax, $y / $ax];
        } elseif ($ay >= $az) {
            [$f, $s, $t] = $y > 0 ? [4, $x / $ay, $z / $ay] : [5, $x / $ay, -$z / $ay];
        } else {
            [$f, $s, $t] = $z < 0 ? [0, $x / $az, $y / $az] : [2, -$x / $az, $y / $az];
        }
        $n = $depth['size'];
        $gx = min($n - 1, max(0, (int) (($s + 1) * $n / 2)));
        $gy = min($n - 1, max(0, (int) ((1 - $t) * $n / 2)));
        return (float) $depth['values'][($f * $n + $gy) * $n + $gx];
    }

    private static function project(array $p, array $q): ?array
    {
        $o = $p['pose'];
        $z = $q[0] * $o['fwd'][0] + $q[1] * $o['fwd'][1] + $q[2] * $o['fwd'][2];
        $len = sqrt($q[0] * $q[0] + $q[1] * $q[1] + $q[2] * $q[2]);
        if ($len <= 0 || $z / $len < 0.05) {
            return null;
        }
        $fr = $p['frame'];
        $uu = (($q[0] * $o['right'][0] + $q[1] * $o['right'][1] + $q[2] * $o['right'][2]) / $z - $fr['left']) / ($fr['right'] - $fr['left']);
        $vv = ($fr['top'] - ($q[0] * $o['up'][0] + $q[1] * $o['up'][1] + $q[2] * $o['up'][2]) / $z) / ($fr['top'] - $fr['bottom']);
        return [$uu, $vv, $z];
    }

    private static function occluded(?array $occ, array $q, float $z): bool
    {
        if ($occ === null) {
            return false;
        }
        [$fx, $fy, $cx, $cy] = $occ['k'];
        $x = $q[0] * $occ['c0'][0] + $q[1] * $occ['c0'][1] + $q[2] * $occ['c0'][2];
        $y = $q[0] * $occ['c1'][0] + $q[1] * $occ['c1'][1] + $q[2] * $occ['c1'][2];
        $u = (int) floor($fx * $x / $z + $cx);
        $v = (int) floor($cy - $fy * $y / $z);
        if ($u < 0 || $v < 0 || $u >= $occ['w'] || $v >= $occ['h']) {
            return false;
        }
        $mm = $occ['map'][$v * $occ['w'] + $u];
        return $mm > 0 && $z > $mm * 0.001 * self::OCCLUSION_RATIO + self::OCCLUSION_SLACK_M;
    }

    private static function exposureGains(array $prepared, ?array $depth): array
    {
        $count = count($prepared);
        if ($count < 2) {
            return array_fill(0, $count, 1.0);
        }
        $observations = [];
        $golden = M_PI * (3 - sqrt(5));
        for ($k = 0; $k < self::GAIN_SAMPLES; $k++) {
            $y = 1 - 2 * ($k + 0.5) / self::GAIN_SAMPLES;
            $radius = sqrt(max(0.0, 1 - $y * $y));
            $dir = [cos($golden * $k) * $radius, $y, sin($golden * $k) * $radius];
            $r = self::depthAt($depth, $dir);
            $seen = [];
            foreach ($prepared as $i => $p) {
                $q = $r > 0
                    ? [$dir[0] * $r - $p['offset'][0], $dir[1] * $r - $p['offset'][1], $dir[2] * $r - $p['offset'][2]]
                    : $dir;
                $hit = self::project($p, $q);
                if ($hit === null) {
                    continue;
                }
                [$uu, $vv, $z] = $hit;
                if ($uu < self::GAIN_EDGE || $uu > 1 - self::GAIN_EDGE || $vv < self::GAIN_EDGE || $vv > 1 - self::GAIN_EDGE) {
                    continue;
                }
                if ($r > 0 && self::occluded($p['occlusion'], $q, $z)) {
                    continue;
                }
                $small = $p['small'];
                $c = imagecolorat($small, min(imagesx($small) - 1, (int) ($uu * imagesx($small))), min(imagesy($small) - 1, (int) ($vv * imagesy($small))));
                $lum = 0.299 * (($c >> 16) & 255) + 0.587 * (($c >> 8) & 255) + 0.114 * ($c & 255);
                if ($lum > 6 && $lum < 249) {
                    $seen[] = [$i, log($lum)];
                }
            }
            if (count($seen) >= 2) {
                $observations[] = $seen;
            }
        }
        return self::exposureGainsFor($observations, $count);
    }

    private static function renderFace(array $basis, int $faceIndex, int $size, array $prepared, array $fill, ?array $depth): string
    {
        $out = imagecreatetruecolor($size, $size);
        $f = $basis['fwd'];
        $r = $basis['right'];
        $u = $basis['up'];
        $tiles = (int) ceil($size / self::TILE_PX);
        $eu = self::FEATHER;
        $invF = 1 / self::FEATHER;
        $ds = $depth !== null ? $depth['size'] : 0;
        $values = $depth !== null ? $depth['values'] : [];
        $depthBase = $faceIndex * $ds * $ds;
        $depthScale = $ds > 0 ? $ds / $size : 0.0;
        $mask = str_repeat("\0", $size * $size);
        $holes = 0;
        $holeLimit = self::FILL_WEIGHT * 1.000001;
        for ($ty = 0; $ty < $tiles; $ty++) {
            for ($tx = 0; $tx < $tiles; $tx++) {
                $x0 = $tx * self::TILE_PX;
                $y0 = $ty * self::TILE_PX;
                $x1 = min($size, $x0 + self::TILE_PX);
                $y1 = min($size, $y0 + self::TILE_PX);
                $candidates = self::tileCandidates($prepared, $basis, $size, $x0, $y0, $x1, $y1, $depth);
                for ($y = $y0; $y < $y1; $y++) {
                    $v = 1 - 2 * ($y + 0.5) / $size;
                    $depthRow = $ds > 0 ? $depthBase + min($ds - 1, (int) (($y + 0.5) * $depthScale)) * $ds : 0;
                    for ($x = $x0; $x < $x1; $x++) {
                        $s = 2 * ($x + 0.5) / $size - 1;
                        $dx = $f[0] + $r[0] * $s + $u[0] * $v;
                        $dy = $f[1] + $r[1] * $s + $u[1] * $v;
                        $dz = $f[2] + $r[2] * $s + $u[2] * $v;
                        $len = sqrt($dx * $dx + $dy * $dy + $dz * $dz);
                        $dx /= $len;
                        $dy /= $len;
                        $dz /= $len;
                        $range = $ds > 0 ? $values[$depthRow + min($ds - 1, (int) (($x + 0.5) * $depthScale))] : 0.0;
                        $fc = $dy > 0 ? self::mix($fill['mid'], $fill['top'], self::smooth(0.0, 0.8, $dy)) : self::mix($fill['mid'], $fill['bottom'], self::smooth(0.0, 0.8, -$dy));
                        $ar = $fc[0] * self::FILL_WEIGHT;
                        $ag = $fc[1] * self::FILL_WEIGHT;
                        $ab = $fc[2] * self::FILL_WEIGHT;
                        $wsum = self::FILL_WEIGHT;
                        foreach ($candidates as $p) {
                            if ($range > 0) {
                                $qx = $dx * $range - $p[21];
                                $qy = $dy * $range - $p[22];
                                $qz = $dz * $range - $p[23];
                            } else {
                                $qx = $dx;
                                $qy = $dy;
                                $qz = $dz;
                            }
                            $z = $qx * $p[0] + $qy * $p[1] + $qz * $p[2];
                            if ($z <= 0) {
                                continue;
                            }
                            $uu = (($qx * $p[3] + $qy * $p[4] + $qz * $p[5]) / $z - $p[9]) * $p[10];
                            if ($uu <= 0 || $uu >= 1) {
                                continue;
                            }
                            $vv = ($p[11] - ($qx * $p[6] + $qy * $p[7] + $qz * $p[8]) / $z) * $p[12];
                            if ($vv <= 0 || $vv >= 1) {
                                continue;
                            }
                            $zn = $range > 0 ? $z / sqrt($qx * $qx + $qy * $qy + $qz * $qz) : $z;
                            if ($zn < 0.05) {
                                continue;
                            }
                            if ($range > 0 && $p[24] !== null) {
                                $occ = $p[24];
                                $ou = (int) floor($occ['k'][0] * ($qx * $occ['c0'][0] + $qy * $occ['c0'][1] + $qz * $occ['c0'][2]) / $z + $occ['k'][2]);
                                $ov = (int) floor($occ['k'][3] - $occ['k'][1] * ($qx * $occ['c1'][0] + $qy * $occ['c1'][1] + $qz * $occ['c1'][2]) / $z);
                                if ($ou >= 0 && $ov >= 0 && $ou < $occ['w'] && $ov < $occ['h']) {
                                    $mm = $occ['map'][$ov * $occ['w'] + $ou];
                                    if ($mm > 0 && $z > $mm * 0.001 * self::OCCLUSION_RATIO + self::OCCLUSION_SLACK_M) {
                                        continue;
                                    }
                                }
                            }
                            $e = $uu < $eu ? $uu : (1 - $uu < $eu ? 1 - $uu : $eu);
                            $t1 = $e * $invF;
                            $e = $vv < $eu ? $vv : (1 - $vv < $eu ? 1 - $vv : $eu);
                            $t2 = $e * $invF;
                            $z2 = $zn * $zn;
                            $w = $t1 * $t1 * (3 - 2 * $t1) * $t2 * $t2 * (3 - 2 * $t2) * $z2 * $z2;
                            if ($w <= 0) {
                                continue;
                            }
                            $sx = $uu * $p[14] - 0.5;
                            $sy = $vv * $p[15] - 0.5;
                            $ix = (int) $sx;
                            $iy = (int) $sy;
                            if ($sx < 0) {
                                $ix = -1;
                            }
                            if ($sy < 0) {
                                $iy = -1;
                            }
                            $fx = $sx - $ix;
                            $fy = $sy - $iy;
                            $xa = $ix < 0 ? 0 : $ix;
                            $xb = $ix + 1 > $p[16] ? $p[16] : $ix + 1;
                            $ya = $iy < 0 ? 0 : $iy;
                            $yb = $iy + 1 > $p[17] ? $p[17] : $iy + 1;
                            $img = $p[13];
                            $c00 = imagecolorat($img, $xa, $ya);
                            $c10 = imagecolorat($img, $xb, $ya);
                            $c01 = imagecolorat($img, $xa, $yb);
                            $c11 = imagecolorat($img, $xb, $yb);
                            $w00 = (1 - $fx) * (1 - $fy) * $w;
                            $w10 = $fx * (1 - $fy) * $w;
                            $w01 = (1 - $fx) * $fy * $w;
                            $w11 = $fx * $fy * $w;
                            $ar += ((($c00 >> 16) & 255) * $w00 + (($c10 >> 16) & 255) * $w10 + (($c01 >> 16) & 255) * $w01 + (($c11 >> 16) & 255) * $w11) * $p[18];
                            $ag += ((($c00 >> 8) & 255) * $w00 + (($c10 >> 8) & 255) * $w10 + (($c01 >> 8) & 255) * $w01 + (($c11 >> 8) & 255) * $w11) * $p[19];
                            $ab += (($c00 & 255) * $w00 + ($c10 & 255) * $w10 + ($c01 & 255) * $w01 + ($c11 & 255) * $w11) * $p[20];
                            $wsum += $w;
                        }
                        if ($wsum <= $holeLimit) {
                            $mask[$y * $size + $x] = "\1";
                            $holes++;
                        }
                        $cr = $ar / $wsum;
                        $cg = $ag / $wsum;
                        $cb = $ab / $wsum;
                        $cr = $cr > 255 ? 255 : $cr;
                        $cg = $cg > 255 ? 255 : $cg;
                        $cb = $cb > 255 ? 255 : $cb;
                        imagesetpixel($out, $x, $y, ((int) round($cr) << 16) | ((int) round($cg) << 8) | (int) round($cb));
                    }
                }
            }
        }
        if ($holes > 0 && $holes < $size * $size) {
            self::fillHoles($out, $size, $mask);
        }
        ob_start();
        imagejpeg($out, null, self::JPEG_QUALITY);
        return (string) ob_get_clean();
    }

    public static function fillHoles(\GdImage $out, int $size, string $mask): void
    {
        $levels = [];
        $n = intdiv($size + 1, 2);
        $r = array_fill(0, $n * $n, 0.0);
        $g = $r;
        $b = $r;
        $w = $r;
        for ($y = 0; $y < $size; $y++) {
            $row = intdiv($y, 2) * $n;
            for ($x = 0; $x < $size; $x++) {
                if ($mask[$y * $size + $x] !== "\0") {
                    continue;
                }
                $c = imagecolorat($out, $x, $y);
                $i = $row + intdiv($x, 2);
                $r[$i] += ($c >> 16) & 255;
                $g[$i] += ($c >> 8) & 255;
                $b[$i] += $c & 255;
                $w[$i] += 1.0;
            }
        }
        $levels[] = [$n, $r, $g, $b, $w];
        while ($n > 1) {
            [$pn, $pr, $pg, $pb, $pw] = $levels[count($levels) - 1];
            $n = intdiv($pn + 1, 2);
            $r = array_fill(0, $n * $n, 0.0);
            $g = $r;
            $b = $r;
            $w = $r;
            for ($y = 0; $y < $pn; $y++) {
                $row = intdiv($y, 2) * $n;
                for ($x = 0; $x < $pn; $x++) {
                    $j = $y * $pn + $x;
                    if ($pw[$j] <= 0) {
                        continue;
                    }
                    $i = $row + intdiv($x, 2);
                    $r[$i] += $pr[$j];
                    $g[$i] += $pg[$j];
                    $b[$i] += $pb[$j];
                    $w[$i] += $pw[$j];
                }
            }
            $levels[] = [$n, $r, $g, $b, $w];
        }
        for ($k = count($levels) - 1; $k >= 0; $k--) {
            [$n, $r, $g, $b, $w] = $levels[$k];
            for ($i = 0; $i < $n * $n; $i++) {
                if ($w[$i] > 0) {
                    $r[$i] /= $w[$i];
                    $g[$i] /= $w[$i];
                    $b[$i] /= $w[$i];
                    $w[$i] = 1.0;
                } elseif ($k + 1 < count($levels)) {
                    [$cn, $cr, $cg, $cb, $cw] = $levels[$k + 1];
                    $p = intdiv(intdiv($i, $n), 2) * $cn + intdiv($i % $n, 2);
                    if ($cw[$p] > 0) {
                        $r[$i] = $cr[$p];
                        $g[$i] = $cg[$p];
                        $b[$i] = $cb[$p];
                        $w[$i] = 1.0;
                    }
                }
            }
            $levels[$k] = [$n, $r, $g, $b, $w];
        }
        [$n, $r, $g, $b, $w] = $levels[0];
        for ($y = 0; $y < $size; $y++) {
            $fy = ($y + 0.5) / 2 - 0.5;
            $y0 = max(0, min($n - 1, (int) floor($fy)));
            $y1 = min($n - 1, $y0 + 1);
            $ty = max(0.0, min(1.0, $fy - $y0));
            for ($x = 0; $x < $size; $x++) {
                if ($mask[$y * $size + $x] === "\0") {
                    continue;
                }
                $fx = ($x + 0.5) / 2 - 0.5;
                $x0 = max(0, min($n - 1, (int) floor($fx)));
                $x1 = min($n - 1, $x0 + 1);
                $tx = max(0.0, min(1.0, $fx - $x0));
                $acc = [0.0, 0.0, 0.0];
                $sum = 0.0;
                foreach ([[$x0, $y0, (1 - $tx) * (1 - $ty)], [$x1, $y0, $tx * (1 - $ty)], [$x0, $y1, (1 - $tx) * $ty], [$x1, $y1, $tx * $ty]] as [$cx, $cy, $cwt]) {
                    $i = $cy * $n + $cx;
                    if ($w[$i] > 0 && $cwt > 0) {
                        $acc[0] += $r[$i] * $cwt;
                        $acc[1] += $g[$i] * $cwt;
                        $acc[2] += $b[$i] * $cwt;
                        $sum += $cwt;
                    }
                }
                if ($sum <= 0) {
                    continue;
                }
                imagesetpixel($out, $x, $y, ((int) round($acc[0] / $sum) << 16) | ((int) round($acc[1] / $sum) << 8) | (int) round($acc[2] / $sum));
            }
        }
    }

    private static function tileCandidates(array $prepared, array $basis, int $size, int $x0, int $y0, int $x1, int $y1, ?array $depth): array
    {
        $dirs = [];
        foreach ([[$x0, $y0], [$x1, $y0], [$x0, $y1], [$x1, $y1], [($x0 + $x1) / 2, ($y0 + $y1) / 2]] as [$x, $y]) {
            $s = 2 * $x / $size - 1;
            $v = 1 - 2 * $y / $size;
            $dirs[] = self::normalize([
                $basis['fwd'][0] + $basis['right'][0] * $s + $basis['up'][0] * $v,
                $basis['fwd'][1] + $basis['right'][1] * $s + $basis['up'][1] * $v,
                $basis['fwd'][2] + $basis['right'][2] * $s + $basis['up'][2] * $v,
            ]);
        }
        $center = $dirs[4];
        $radius = 0.0;
        for ($i = 0; $i < 4; $i++) {
            $radius = max($radius, acos(max(-1.0, min(1.0, self::dot($center, $dirs[$i])))));
        }
        $range = self::depthAt($depth, $center);
        $out = [];
        foreach ($prepared as $p) {
            $fr = $p['frame'];
            $halfDiag = atan(sqrt(max(abs($fr['left']), abs($fr['right'])) ** 2 + max(abs($fr['top']), abs($fr['bottom'])) ** 2));
            $hasOffset = $p['offset'] !== [0.0, 0.0, 0.0];
            $look = $range > 0 && $hasOffset
                ? self::normalize([$center[0] * $range - $p['offset'][0], $center[1] * $range - $p['offset'][1], $center[2] * $range - $p['offset'][2]])
                : $center;
            $angle = acos(max(-1.0, min(1.0, self::dot($look, $p['pose']['fwd']))));
            $slack = $hasOffset && $depth !== null ? self::TILE_SLACK_RAD : 0.01;
            if ($angle <= $halfDiag + $radius + $slack) {
                $o = $p['pose'];
                $out[] = [
                    $o['fwd'][0], $o['fwd'][1], $o['fwd'][2],
                    $o['right'][0], $o['right'][1], $o['right'][2],
                    $o['up'][0], $o['up'][1], $o['up'][2],
                    $fr['left'], 1 / ($fr['right'] - $fr['left']),
                    $fr['top'], 1 / ($fr['top'] - $fr['bottom']),
                    $p['image'], $p['width'], $p['height'], $p['width'] - 1, $p['height'] - 1,
                    $p['gain'][0], $p['gain'][1], $p['gain'][2],
                    $p['offset'][0], $p['offset'][1], $p['offset'][2],
                    $p['occlusion'],
                ];
            }
        }
        return $out;
    }

    private static function mean(\GdImage $small): ?array
    {
        $w = imagesx($small);
        $h = imagesy($small);
        $sum = [0, 0, 0];
        for ($y = 0; $y < $h; $y++) {
            for ($x = 0; $x < $w; $x++) {
                $c = imagecolorat($small, $x, $y);
                $sum[0] += ($c >> 16) & 255;
                $sum[1] += ($c >> 8) & 255;
                $sum[2] += $c & 255;
            }
        }
        $n = max(1, $w * $h);
        $mean = [$sum[0] / $n, $sum[1] / $n, $sum[2] / $n];
        return $mean[0] + $mean[1] + $mean[2] > 3 ? $mean : null;
    }

    private static function fillColors(array $prepared, array $gains): array
    {
        $sum = [0.0, 0.0, 0.0];
        $n = 0;
        foreach ($prepared as $i => $p) {
            if ($p['mean'] === null) {
                continue;
            }
            for ($c = 0; $c < 3; $c++) {
                $sum[$c] += min(255.0, $p['mean'][$c] * ($gains[$i] ?? 1.0));
            }
            $n++;
        }
        $mid = $n > 0 ? [$sum[0] / $n, $sum[1] / $n, $sum[2] / $n] : [107.0, 105.0, 99.0];
        return [
            'mid' => $mid,
            'top' => array_map(static fn (float $c): float => min(255.0, $c * 1.15), $mid),
            'bottom' => array_map(static fn (float $c): float => $c * 0.75, $mid),
        ];
    }

    private static function bearing(array $photo): float
    {
        $m = $photo['camera_transform'] ?? null;
        if (is_array($m) && count($m) === 16 && is_numeric($m[8]) && is_numeric($m[10]) && ((float) $m[8] !== 0.0 || (float) $m[10] !== 0.0)) {
            return rad2deg(atan2(-(float) $m[8], (float) $m[10]));
        }
        return is_numeric($photo['heading_deg'] ?? null) ? (float) $photo['heading_deg'] : 0.0;
    }

    private static function allPositive(array $values): bool
    {
        foreach ($values as $value) {
            if (!is_numeric($value) || (float) $value <= 0) {
                return false;
            }
        }
        return true;
    }

    private static function smooth(float $a, float $b, float $x): float
    {
        $t = max(0.0, min(1.0, ($x - $a) / ($b - $a)));
        return $t * $t * (3 - 2 * $t);
    }

    private static function mix(array $a, array $b, float $t): array
    {
        return [$a[0] + ($b[0] - $a[0]) * $t, $a[1] + ($b[1] - $a[1]) * $t, $a[2] + ($b[2] - $a[2]) * $t];
    }

    private static function dot(array $a, array $b): float
    {
        return $a[0] * $b[0] + $a[1] * $b[1] + $a[2] * $b[2];
    }

    private static function cross(array $a, array $b): array
    {
        return [$a[1] * $b[2] - $a[2] * $b[1], $a[2] * $b[0] - $a[0] * $b[2], $a[0] * $b[1] - $a[1] * $b[0]];
    }

    private static function normalize(array $v): array
    {
        $len = sqrt(self::dot($v, $v)) ?: 1.0;
        return [$v[0] / $len, $v[1] / $len, $v[2] / $len];
    }

    private static function neg(array $v): array
    {
        return [-$v[0], -$v[1], -$v[2]];
    }
}
