<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class StandSkybox
{
    public const VERSION = 'sky-1';
    public const FACES = ['f', 'r', 'b', 'l', 'u', 'd'];
    public const MIN_FACE_PX = 256;
    public const MAX_FACE_PX = 1024;
    public const JPEG_QUALITY = 85;
    private const PHOTO_FOV_DEG = 60.0;
    private const FEATHER = 0.12;
    private const FILL_WEIGHT = 0.004;
    private const GAIN_SAMPLE_PX = 16;
    private const GAIN_MIN = 0.75;
    private const GAIN_MAX = 1.33;
    private const TILE_PX = 32;

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
        $parts = [self::VERSION];
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
                $fileStamp((string) ($photo['url'] ?? '')),
            ]);
        }
        return substr(hash('sha256', implode("\n", $parts)), 0, 24);
    }

    public static function pose(array $photo): array
    {
        $m = $photo['camera_transform'] ?? null;
        $valid = is_array($m) && count($m) === 16;
        for ($i = 0; $valid && $i < 12; $i++) {
            if (!is_int($m[$i]) && !is_float($m[$i])) {
                $valid = false;
            } elseif (!is_finite((float) $m[$i])) {
                $valid = false;
            }
        }
        if ($valid && ((float) $m[8] !== 0.0 || (float) $m[9] !== 0.0 || (float) $m[10] !== 0.0)) {
            $c0 = self::normalize([(float) $m[0], (float) $m[1], (float) $m[2]]);
            $c1 = self::normalize([(float) $m[4], (float) $m[5], (float) $m[6]]);
            $fwd = self::neg(self::normalize([(float) $m[8], (float) $m[9], (float) $m[10]]));
            if (abs((float) $m[5]) > abs((float) $m[1])) {
                return (float) $m[5] >= 0
                    ? ['fwd' => $fwd, 'right' => $c0, 'up' => $c1]
                    : ['fwd' => $fwd, 'right' => self::neg($c0), 'up' => self::neg($c1)];
            }
            return (float) $m[1] <= 0
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

    public static function render(array $sources, ?int $faceSize = null): array
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
            ];
        }
        if (count($items) < 2) {
            throw new \InvalidArgumentException('A 360 spot needs at least two readable photos to stitch.');
        }

        $size = $faceSize ?? self::faceSize($items);
        $prepared = self::prepare($items, $size);
        $fill = self::fillColors($prepared);
        $faces = [];
        foreach (self::FACES as $face) {
            $faces[$face] = self::renderFace(self::faceBasis($face), $size, $prepared, $fill);
        }
        return ['size' => $size, 'faces' => $faces];
    }

    private static function prepare(array $items, int $faceSize): array
    {
        $means = [];
        foreach ($items as $i => $item) {
            $means[$i] = self::mean($item['image'], $item['width'], $item['height']);
        }
        $valid = array_filter($means);
        $ref = null;
        if (count($valid) >= 2) {
            $ref = [];
            for ($c = 0; $c < 3; $c++) {
                $ref[$c] = self::median(array_map(static fn (array $m): float => $m[$c], $valid));
            }
        }

        $prepared = [];
        foreach ($items as $i => $item) {
            $frame = self::frame($item['photo'], $item['width'], $item['height']);
            if ($frame['right'] <= $frame['left'] || $frame['top'] <= $frame['bottom']) {
                continue;
            }
            $image = $item['image'];
            $width = $item['width'];
            $height = $item['height'];
            $limit = (int) ceil($faceSize / 2 * ($frame['right'] - $frame['left']) * 1.25);
            if ($width > $limit && $limit > 8) {
                $scaledHeight = max(1, (int) round($height * $limit / $width));
                $scaled = imagecreatetruecolor($limit, $scaledHeight);
                imagecopyresampled($scaled, $image, 0, 0, 0, 0, $limit, $scaledHeight, $width, $height);
                $image = $scaled;
                $width = $limit;
                $height = $scaledHeight;
            }
            $gain = [1.0, 1.0, 1.0];
            if ($ref !== null && $means[$i] !== null) {
                for ($c = 0; $c < 3; $c++) {
                    $gain[$c] = max(self::GAIN_MIN, min(self::GAIN_MAX, $ref[$c] / max(1.0, $means[$i][$c])));
                }
            }
            $prepared[] = [
                'pose' => self::pose($item['photo']),
                'frame' => $frame,
                'image' => $image,
                'width' => $width,
                'height' => $height,
                'gain' => $gain,
                'mean' => $means[$i],
            ];
        }
        return $prepared;
    }

    private static function renderFace(array $basis, int $size, array $prepared, array $fill): string
    {
        $out = imagecreatetruecolor($size, $size);
        $f = $basis['fwd'];
        $r = $basis['right'];
        $u = $basis['up'];
        $tiles = (int) ceil($size / self::TILE_PX);
        $eu = self::FEATHER;
        $invF = 1 / self::FEATHER;
        for ($ty = 0; $ty < $tiles; $ty++) {
            for ($tx = 0; $tx < $tiles; $tx++) {
                $x0 = $tx * self::TILE_PX;
                $y0 = $ty * self::TILE_PX;
                $x1 = min($size, $x0 + self::TILE_PX);
                $y1 = min($size, $y0 + self::TILE_PX);
                $candidates = self::tileCandidates($prepared, $basis, $size, $x0, $y0, $x1, $y1);
                for ($y = $y0; $y < $y1; $y++) {
                    $v = 1 - 2 * ($y + 0.5) / $size;
                    for ($x = $x0; $x < $x1; $x++) {
                        $s = 2 * ($x + 0.5) / $size - 1;
                        $dx = $f[0] + $r[0] * $s + $u[0] * $v;
                        $dy = $f[1] + $r[1] * $s + $u[1] * $v;
                        $dz = $f[2] + $r[2] * $s + $u[2] * $v;
                        $len = sqrt($dx * $dx + $dy * $dy + $dz * $dz);
                        $dx /= $len;
                        $dy /= $len;
                        $dz /= $len;
                        $fc = $dy > 0 ? self::mix($fill['mid'], $fill['top'], self::smooth(0.0, 0.8, $dy)) : self::mix($fill['mid'], $fill['bottom'], self::smooth(0.0, 0.8, -$dy));
                        $ar = $fc[0] * self::FILL_WEIGHT;
                        $ag = $fc[1] * self::FILL_WEIGHT;
                        $ab = $fc[2] * self::FILL_WEIGHT;
                        $wsum = self::FILL_WEIGHT;
                        foreach ($candidates as $p) {
                            $z = $dx * $p[0] + $dy * $p[1] + $dz * $p[2];
                            if ($z < 0.05) {
                                continue;
                            }
                            $uu = (($dx * $p[3] + $dy * $p[4] + $dz * $p[5]) / $z - $p[9]) * $p[10];
                            if ($uu <= 0 || $uu >= 1) {
                                continue;
                            }
                            $vv = ($p[11] - ($dx * $p[6] + $dy * $p[7] + $dz * $p[8]) / $z) * $p[12];
                            if ($vv <= 0 || $vv >= 1) {
                                continue;
                            }
                            $e = $uu < $eu ? $uu : (1 - $uu < $eu ? 1 - $uu : $eu);
                            $t1 = $e * $invF;
                            $e = $vv < $eu ? $vv : (1 - $vv < $eu ? 1 - $vv : $eu);
                            $t2 = $e * $invF;
                            $z2 = $z * $z;
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
        ob_start();
        imagejpeg($out, null, self::JPEG_QUALITY);
        return (string) ob_get_clean();
    }

    private static function tileCandidates(array $prepared, array $basis, int $size, int $x0, int $y0, int $x1, int $y1): array
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
        $out = [];
        foreach ($prepared as $p) {
            $fr = $p['frame'];
            $halfDiag = atan(sqrt(max(abs($fr['left']), abs($fr['right'])) ** 2 + max(abs($fr['top']), abs($fr['bottom'])) ** 2));
            $angle = acos(max(-1.0, min(1.0, self::dot($center, $p['pose']['fwd']))));
            if ($angle <= $halfDiag + $radius + 0.01) {
                $o = $p['pose'];
                $out[] = [
                    $o['fwd'][0], $o['fwd'][1], $o['fwd'][2],
                    $o['right'][0], $o['right'][1], $o['right'][2],
                    $o['up'][0], $o['up'][1], $o['up'][2],
                    $fr['left'], 1 / ($fr['right'] - $fr['left']),
                    $fr['top'], 1 / ($fr['top'] - $fr['bottom']),
                    $p['image'], $p['width'], $p['height'], $p['width'] - 1, $p['height'] - 1,
                    $p['gain'][0], $p['gain'][1], $p['gain'][2],
                ];
            }
        }
        return $out;
    }

    private static function mean(\GdImage $image, int $width, int $height): ?array
    {
        $n = self::GAIN_SAMPLE_PX;
        $small = imagecreatetruecolor($n, $n);
        imagecopyresampled($small, $image, 0, 0, 0, 0, $n, $n, $width, $height);
        $sum = [0, 0, 0];
        for ($y = 0; $y < $n; $y++) {
            for ($x = 0; $x < $n; $x++) {
                $c = imagecolorat($small, $x, $y);
                $sum[0] += ($c >> 16) & 255;
                $sum[1] += ($c >> 8) & 255;
                $sum[2] += $c & 255;
            }
        }
        $mean = [$sum[0] / ($n * $n), $sum[1] / ($n * $n), $sum[2] / ($n * $n)];
        return $mean[0] + $mean[1] + $mean[2] > 3 ? $mean : null;
    }

    private static function fillColors(array $prepared): array
    {
        $sum = [0.0, 0.0, 0.0];
        $n = 0;
        foreach ($prepared as $p) {
            if ($p['mean'] === null) {
                continue;
            }
            for ($c = 0; $c < 3; $c++) {
                $sum[$c] += $p['mean'][$c];
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

    private static function median(array $values): float
    {
        sort($values);
        $count = count($values);
        $mid = intdiv($count, 2);
        return $count % 2 === 1 ? (float) $values[$mid] : ($values[$mid - 1] + $values[$mid]) / 2;
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
