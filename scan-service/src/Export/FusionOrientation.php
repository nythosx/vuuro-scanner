<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FusionOrientation
{
    public static function apply(array $rooms, array $poses, string $orientation): array
    {
        if ($orientation !== 'longest_horizontal' || count($rooms) === 0) {
            return ['rooms' => $rooms, 'poses' => $poses];
        }

        $skew = self::dominantWallAngle($rooms, $poses);
        if ($skew !== null && abs($skew) > self::MIN_STRAIGHTEN_RAD) {
            [$cx, $cz] = self::center($rooms, $poses);
            foreach ($poses as $i => $pose) {
                $poses[$i] = self::rotatePose($pose, -$skew, $cx, $cz);
            }
        }

        $minX = INF;
        $minZ = INF;
        $maxX = -INF;
        $maxZ = -INF;
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
        $width = $maxX - $minX;
        $height = $maxZ - $minZ;
        if ($width >= $height) {
            return ['rooms' => $rooms, 'poses' => $poses];
        }

        $cx = ($minX + $maxX) / 2;
        $cz = ($minZ + $maxZ) / 2;
        $rot = -M_PI / 2;

        $newPoses = [];
        foreach ($poses as $i => $pose) {
            $newPoses[$i] = self::rotatePose($pose, $rot, $cx, $cz);
        }
        return ['rooms' => $rooms, 'poses' => $newPoses];
    }

    private const MIN_STRAIGHTEN_RAD = 0.005;

    private static function dominantWallAngle(array $rooms, array $poses): ?float
    {
        $sumX = 0.0;
        $sumY = 0.0;
        $total = 0.0;
        foreach ($rooms as $i => $room) {
            $points = array_map(
                static fn (array $point) => RoomFusionSolver::transformPoint($poses[$i], (float) $point[0], (float) $point[1]),
                $room['outline_m']
            );
            $count = count($points);
            for ($k = 0; $k < $count; $k++) {
                [$ax, $az] = $points[$k];
                [$bx, $bz] = $points[($k + 1) % $count];
                $length = hypot($bx - $ax, $bz - $az);
                if ($length < 0.3) {
                    continue;
                }
                $angle = atan2($bz - $az, $bx - $ax);
                $sumX += $length * cos(4 * $angle);
                $sumY += $length * sin(4 * $angle);
                $total += $length;
            }
        }
        if ($total <= 0.0 || hypot($sumX, $sumY) < 0.3 * $total) {
            return null;
        }
        return atan2($sumY, $sumX) / 4;
    }

    private static function center(array $rooms, array $poses): array
    {
        $minX = INF;
        $minZ = INF;
        $maxX = -INF;
        $maxZ = -INF;
        foreach ($rooms as $i => $room) {
            foreach ($room['outline_m'] as [$mx, $mz]) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($poses[$i], $mx, $mz);
                $minX = min($minX, $wx);
                $minZ = min($minZ, $wz);
                $maxX = max($maxX, $wx);
                $maxZ = max($maxZ, $wz);
            }
        }
        return [($minX + $maxX) / 2, ($minZ + $maxZ) / 2];
    }

    private static function rotatePose(array $pose, float $theta, float $cx, float $cz): array
    {
        $cos = cos($theta);
        $sin = sin($theta);
        $dx = $pose['originX'] - $cx;
        $dz = $pose['originZ'] - $cz;
        return [
            'originX' => $cos * $dx - $sin * $dz + $cx,
            'originZ' => $sin * $dx + $cos * $dz + $cz,
            'rotationRad' => $pose['rotationRad'] + $theta,
        ];
    }
}
