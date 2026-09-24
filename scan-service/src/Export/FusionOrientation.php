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
