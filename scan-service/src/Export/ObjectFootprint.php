<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class ObjectFootprint
{
    public static function fit(array $room, array $object, float $wallHalfM): array
    {
        [$mx, $mz] = $object['position_m'];
        $mx = (float) $mx;
        $mz = (float) $mz;
        $dims = $object['dimensions_m'] ?? [0.5, 0.0, 0.5];
        $halfW = max(0.05, ((float) ($dims[0] ?? 0.5)) / 2);
        $halfD = max(0.05, ((float) ($dims[2] ?? 0.5)) / 2);

        $outline = $room['outline_m'] ?? [];
        $toFrame = count($outline) >= 2 ? TileOrientation::angleFor($outline) : 0.0;
        $frameRad = -$toFrame;

        $yaw = $object['yaw_deg'] ?? null;
        if (is_int($yaw) || is_float($yaw)) {
            $relative = deg2rad((float) $yaw) - $frameRad;
            if (abs(sin($relative)) > abs(cos($relative))) {
                [$halfW, $halfD] = [$halfD, $halfW];
            }
        }

        if ($outline !== []) {
            $xs = [];
            $zs = [];
            foreach ($outline as $point) {
                [$fx, $fz] = self::rotate((float) $point[0], (float) $point[1], $toFrame);
                $xs[] = $fx;
                $zs[] = $fz;
            }
            [$fx, $fz] = self::rotate($mx, $mz, $toFrame);
            $fx = self::clamp($fx, min($xs) + $wallHalfM + $halfW, max($xs) - $wallHalfM - $halfW);
            $fz = self::clamp($fz, min($zs) + $wallHalfM + $halfD, max($zs) - $wallHalfM - $halfD);
            [$mx, $mz] = self::rotate($fx, $fz, $frameRad);
        }

        return [$mx, $mz, $halfW, $halfD, $frameRad];
    }

    public static function objectPose(array $pose, float $mx, float $mz, float $frameRad): array
    {
        if (abs($frameRad) < 1e-9) {
            return $pose;
        }
        [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $mx, $mz);
        $rotation = $pose['rotationRad'] + $frameRad;
        $cos = cos($rotation);
        $sin = sin($rotation);
        $pose['rotationRad'] = $rotation;
        $pose['originX'] = $wx - ($mx * $cos - $mz * $sin);
        $pose['originZ'] = $wz - ($mx * $sin + $mz * $cos);
        return $pose;
    }

    private static function rotate(float $x, float $z, float $rad): array
    {
        $cos = cos($rad);
        $sin = sin($rad);
        return [$x * $cos - $z * $sin, $x * $sin + $z * $cos];
    }

    private static function clamp(float $value, float $low, float $high): float
    {
        if ($low > $high) {
            return ($low + $high) / 2;
        }
        return max($low, min($high, $value));
    }
}
