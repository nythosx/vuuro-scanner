<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class WallTextureProjection
{
    public const CAMERA_HEIGHT_M = 1.5;
    public const HORIZONTAL_FOV_DEG = 60.0;
    public const VERTICAL_FOV_DEG = 60.0;
    public const MIN_DEPTH_M = 0.2;
    public const MAX_HEADING_OFFSET_DEG = 60.0;
    public const MAX_WALL_LENGTH_PER_SPAN = 2.0;
    public const MIN_EYE_HEIGHT_M = 0.3;
    public const MAX_EYE_HEIGHT_M = 2.6;

    public static function projectPointRaw(array $photo, float $roomHeadingDeg, float $px, float $py, float $pz): ?array
    {
        $posed = self::posedCamera($photo);
        if ($posed !== null) {
            return self::projectPosed($posed, $px, $py, $pz);
        }

        $forward = self::forwardVector($photo, $roomHeadingDeg);
        if ($forward === null) {
            return null;
        }
        [$fx, $fz] = $forward;
        $rx = $fz;
        $rz = -$fx;

        $camX = (float) $photo['position_m'][0];
        $camZ = (float) $photo['position_m'][1];
        $dx = $px - $camX;
        $dy = $py - self::CAMERA_HEIGHT_M;
        $dz = $pz - $camZ;

        $pitch = deg2rad(self::pitchDeg($photo));
        $along = $dx * $fx + $dz * $fz;
        $zCam = $along * cos($pitch) + $dy * sin($pitch);
        if ($zCam < self::MIN_DEPTH_M) {
            return null;
        }
        $xCam = $dx * $rx + $dz * $rz;
        $yCam = $dy * cos($pitch) - $along * sin($pitch);

        $photoZoom = self::zoom($photo);
        $halfH = tan(deg2rad(self::HORIZONTAL_FOV_DEG / 2.0)) / $photoZoom;
        $halfV = tan(deg2rad(self::VERTICAL_FOV_DEG / 2.0)) / $photoZoom;

        $u = 0.5 + $xCam / (2.0 * $halfH * $zCam);
        $v = 0.5 - $yCam / (2.0 * $halfV * $zCam);

        return [$u, $v];
    }

    public static function projectPoint(array $photo, float $roomHeadingDeg, float $px, float $py, float $pz): ?array
    {
        $uv = self::projectPointRaw($photo, $roomHeadingDeg, $px, $py, $pz);
        if ($uv === null) {
            return null;
        }
        if ($uv[0] < 0.0 || $uv[0] > 1.0 || $uv[1] < 0.0 || $uv[1] > 1.0) {
            return null;
        }
        return $uv;
    }

    public static function pickWallPhoto(
        array $wallA,
        array $wallB,
        array $inwardNormal,
        float $roomHeadingDeg,
        float $wallHeightM,
        array $photos
    ): ?array {
        $ax = (float) $wallA[0];
        $az = (float) $wallA[1];
        $bx = (float) $wallB[0];
        $bz = (float) $wallB[1];
        $nx = (float) $inwardNormal[0];
        $nz = (float) $inwardNormal[1];
        $minDot = -cos(deg2rad(self::MAX_HEADING_OFFSET_DEG));
        $midX = ($ax + $bx) / 2.0;
        $midZ = ($az + $bz) / 2.0;
        $midHeightY = $wallHeightM / 2.0;
        $wallLength = hypot($bx - $ax, $bz - $az);
        $best = null;
        $bestScore = -INF;
        foreach ($photos as $photo) {
            $posed = self::posedCamera($photo);
            if ($posed !== null) {
                $camX = $posed['x'];
                $camZ = $posed['z'];
                $flat = hypot($posed['fwd'][0], $posed['fwd'][2]);
                if ($flat < 1e-6) {
                    continue;
                }
                $fx = $posed['fwd'][0] / $flat;
                $fz = $posed['fwd'][2] / $flat;
                $halfH = $posed['width'] / (2.0 * $posed['fx']);
            } else {
                $pos = $photo['position_m'] ?? null;
                if (!is_array($pos) || count($pos) < 2) {
                    continue;
                }
                $forward = self::forwardVector($photo, $roomHeadingDeg);
                if ($forward === null) {
                    continue;
                }
                [$fx, $fz] = $forward;
                $camX = (float) $pos[0];
                $camZ = (float) $pos[1];
                $halfH = tan(deg2rad(self::HORIZONTAL_FOV_DEG / 2.0)) / self::zoom($photo);
            }
            $dot = $fx * $nx + $fz * $nz;
            if ($dot > $minDot) {
                continue;
            }
            $mid = self::projectPoint($photo, $roomHeadingDeg, $midX, $midHeightY, $midZ);
            if ($mid === null) {
                continue;
            }
            $zCam = ($midX - $camX) * $fx + ($midZ - $camZ) * $fz;
            if ($zCam < self::MIN_DEPTH_M) {
                continue;
            }
            $coveredSpan = 2.0 * $halfH * $zCam;
            if ($wallLength > self::MAX_WALL_LENGTH_PER_SPAN * $coveredSpan) {
                continue;
            }
            $dist = hypot($midX - $camX, $midZ - $camZ);
            $centred = 1.0 - min(1.0, hypot($mid[0] - 0.5, $mid[1] - 0.5) * 2.0);
            $score = -$dot + 0.25 * $centred - $dist * 0.01;
            if ($score > $bestScore) {
                $bestScore = $score;
                $best = $photo;
            }
        }
        return $best;
    }

    public static function posedCamera(array $photo): ?array
    {
        $m = $photo['camera_transform'] ?? null;
        $k = $photo['intrinsics'] ?? null;
        if (!is_array($m) || count($m) !== 16 || !is_array($k) || count($k) !== 4) {
            return null;
        }
        $m = array_values($m);
        $k = array_values($k);
        foreach ($m as $value) {
            if (!is_numeric($value) || !is_finite((float) $value)) {
                return null;
            }
        }
        foreach ($k as $value) {
            if (!is_numeric($value) || !is_finite((float) $value) || (float) $value <= 0) {
                return null;
            }
        }
        $m = array_map('floatval', $m);
        [$kfx, $kfy, $kcx, $kcy] = array_map('floatval', $k);

        $c0 = self::normalize([$m[0], $m[1], $m[2]]);
        $c1 = self::normalize([$m[4], $m[5], $m[6]]);
        $back = self::normalize([$m[8], $m[9], $m[10]]);
        if ($c0 === null || $c1 === null || $back === null) {
            return null;
        }
        $fwd = [-$back[0], -$back[1], -$back[2]];
        if (abs($m[5]) > abs($m[1])) {
            $right = $m[5] >= 0 ? $c0 : self::negate($c0);
            $up = $m[5] >= 0 ? $c1 : self::negate($c1);
        } elseif ($m[1] <= 0) {
            $right = $c1;
            $up = self::negate($c0);
        } else {
            $right = self::negate($c1);
            $up = $c0;
        }

        $width = isset($photo['image_width']) && (float) $photo['image_width'] > 0 ? (float) $photo['image_width'] : 2.0 * $kcx;
        $height = isset($photo['image_height']) && (float) $photo['image_height'] > 0 ? (float) $photo['image_height'] : 2.0 * $kcy;
        $ref = $width / (2.0 * $kcx);
        if (abs($ref - 1.0) > 0.2) {
            $kfx *= $ref;
            $kfy *= $ref;
            $kcx *= $ref;
            $kcy *= $ref;
        }

        $eye = $m[13];
        if ($eye < self::MIN_EYE_HEIGHT_M || $eye > self::MAX_EYE_HEIGHT_M) {
            $eye = self::CAMERA_HEIGHT_M;
        }

        return [
            'x' => $m[12],
            'y' => $eye,
            'z' => $m[14],
            'fwd' => $fwd,
            'right' => $right,
            'up' => $up,
            'fx' => $kfx,
            'fy' => $kfy,
            'cx' => $kcx,
            'cy' => $kcy,
            'width' => $width,
            'height' => $height,
        ];
    }

    private static function projectPosed(array $cam, float $px, float $py, float $pz): ?array
    {
        $d = [$px - $cam['x'], $py - $cam['y'], $pz - $cam['z']];
        $z = $d[0] * $cam['fwd'][0] + $d[1] * $cam['fwd'][1] + $d[2] * $cam['fwd'][2];
        if ($z < self::MIN_DEPTH_M) {
            return null;
        }
        $x = $d[0] * $cam['right'][0] + $d[1] * $cam['right'][1] + $d[2] * $cam['right'][2];
        $y = $d[0] * $cam['up'][0] + $d[1] * $cam['up'][1] + $d[2] * $cam['up'][2];
        $u = ($cam['fx'] * $x / $z + $cam['cx']) / $cam['width'];
        $v = ($cam['cy'] - $cam['fy'] * $y / $z) / $cam['height'];
        return [$u, $v];
    }

    private static function normalize(array $v): ?array
    {
        $length = sqrt($v[0] * $v[0] + $v[1] * $v[1] + $v[2] * $v[2]);
        if ($length < 1e-9) {
            return null;
        }
        return [$v[0] / $length, $v[1] / $length, $v[2] / $length];
    }

    private static function negate(array $v): array
    {
        return [-$v[0], -$v[1], -$v[2]];
    }

    private static function zoom(array $photo): float
    {
        $photoZoom = isset($photo['zoom']) ? (float) $photo['zoom'] : 1.0;
        return is_finite($photoZoom) && $photoZoom >= 1.0 ? $photoZoom : 1.0;
    }

    private static function pitchDeg(array $photo): float
    {
        $pitch = isset($photo['pitch_deg']) && is_numeric($photo['pitch_deg']) ? (float) $photo['pitch_deg'] : 0.0;
        return is_finite($pitch) ? max(-89.0, min(89.0, $pitch)) : 0.0;
    }

    private static function forwardVector(array $photo, float $roomHeadingDeg): ?array
    {
        if (!isset($photo['heading_deg'])) {
            return null;
        }
        $theta = deg2rad($roomHeadingDeg - (float) $photo['heading_deg']);
        return [sin($theta), cos($theta)];
    }
}
