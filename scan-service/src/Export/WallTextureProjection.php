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

    public static function projectPointRaw(array $photo, float $roomHeadingDeg, float $px, float $py, float $pz): ?array
    {
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

        $zCam = $dx * $fx + $dz * $fz;
        if ($zCam < self::MIN_DEPTH_M) {
            return null;
        }
        $xCam = $dx * $rx + $dz * $rz;
        $yCam = $dy;

        $halfH = tan(deg2rad(self::HORIZONTAL_FOV_DEG / 2.0));
        $halfV = tan(deg2rad(self::VERTICAL_FOV_DEG / 2.0));

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
        $halfH = tan(deg2rad(self::HORIZONTAL_FOV_DEG / 2.0));

        $best = null;
        $bestScore = -INF;
        foreach ($photos as $photo) {
            $pos = $photo['position_m'] ?? null;
            if (!is_array($pos) || count($pos) < 2) {
                continue;
            }
            $forward = self::forwardVector($photo, $roomHeadingDeg);
            if ($forward === null) {
                continue;
            }
            [$fx, $fz] = $forward;
            $dot = $fx * $nx + $fz * $nz;
            if ($dot > $minDot) {
                continue;
            }
            $mid = self::projectPoint($photo, $roomHeadingDeg, $midX, $midHeightY, $midZ);
            if ($mid === null) {
                continue;
            }
            $camX = (float) $pos[0];
            $camZ = (float) $pos[1];
            $zCam = ($midX - $camX) * $fx + ($midZ - $camZ) * $fz;
            if ($zCam < self::MIN_DEPTH_M) {
                continue;
            }
            $coveredSpan = 2.0 * $halfH * $zCam;
            if ($wallLength > self::MAX_WALL_LENGTH_PER_SPAN * $coveredSpan) {
                continue;
            }
            $dist = hypot($midX - $camX, $midZ - $camZ);
            $score = -$dot - $dist * 0.01;
            if ($score > $bestScore) {
                $bestScore = $score;
                $best = $photo;
            }
        }
        return $best;
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
