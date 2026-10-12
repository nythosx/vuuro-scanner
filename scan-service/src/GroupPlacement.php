<?php

declare(strict_types=1);

namespace VuuroScan;

final class GroupPlacement
{
    public const MAX_ROTATION_DEG = 360.0;
    public const MAX_TRANSLATION_M = 1000.0;

    public static function transformRoom(array $room, float $rotationDeg, float $tx, float $tz): array
    {
        $origin = $room['structure_origin_m'] ?? null;
        if (!is_array($origin) || count($origin) < 2) {
            throw new \InvalidArgumentException('group_missing_origin');
        }
        if (self::roomHasSplits($room)) {
            throw new \InvalidArgumentException('group_has_splits');
        }

        $theta = deg2rad($rotationDeg);
        $cos = cos($theta);
        $sin = sin($theta);
        $originX = (float) $origin[0];
        $originZ = (float) $origin[1];

        $toWorld = static fn (float $lx, float $lz): array => [
            $originX + $lx,
            $originZ + $lz,
        ];
        $applyRigid = static function (float $wx, float $wz) use ($cos, $sin, $tx, $tz): array {
            return [
                $wx * $cos - $wz * $sin + $tx,
                $wx * $sin + $wz * $cos + $tz,
            ];
        };

        $worldOutline = [];
        foreach (($room['outline_m'] ?? []) as $p) {
            [$wx, $wz] = $toWorld((float) $p[0], (float) $p[1]);
            $worldOutline[] = $applyRigid($wx, $wz);
        }
        if ($worldOutline === []) {
            throw new \InvalidArgumentException('group_missing_outline');
        }
        $minX = min(array_column($worldOutline, 0));
        $minZ = min(array_column($worldOutline, 1));

        $room['outline_m'] = array_map(
            static fn (array $p) => [round($p[0] - $minX, 4), round($p[1] - $minZ, 4)],
            $worldOutline
        );
        $room['structure_origin_m'] = [round($minX, 4), round($minZ, 4)];

        $xs = array_column($room['outline_m'], 0);
        $zs = array_column($room['outline_m'], 1);
        $room['bounding_dimensions_m'] = [
            'width_m' => round(max($xs) - min($xs), 4),
            'length_m' => round(max($zs) - min($zs), 4),
        ];

        if (isset($room['openings']) && is_array($room['openings'])) {
            foreach ($room['openings'] as $i => $opening) {
                $pos = $opening['position_m'] ?? null;
                if (!is_array($pos) || count($pos) < 2) {
                    continue;
                }
                [$wx, $wz] = $toWorld((float) $pos[0], (float) $pos[1]);
                [$nx, $nz] = $applyRigid($wx, $wz);
                $room['openings'][$i]['position_m'] = [
                    round($nx - $minX, 4),
                    round($nz - $minZ, 4),
                ];
            }
        }

        if (isset($room['objects']) && is_array($room['objects'])) {
            foreach ($room['objects'] as $i => $object) {
                $pos = $object['position_m'] ?? null;
                if (is_array($pos) && count($pos) >= 2) {
                    [$wx, $wz] = $toWorld((float) $pos[0], (float) $pos[1]);
                    [$nx, $nz] = $applyRigid($wx, $wz);
                    $room['objects'][$i]['position_m'] = [
                        round($nx - $minX, 4),
                        round($nz - $minZ, 4),
                    ];
                }
                if (isset($object['yaw_deg']) && (is_int($object['yaw_deg']) || is_float($object['yaw_deg']))) {
                    $newYaw = fmod(fmod((float) $object['yaw_deg'] + $rotationDeg, 360.0) + 360.0, 360.0);
                    $room['objects'][$i]['yaw_deg'] = round($newYaw, 2);
                }
            }
        }

        if (isset($room['walk_path_m']) && is_array($room['walk_path_m'])) {
            $moved = [];
            foreach ($room['walk_path_m'] as $p) {
                if (!is_array($p) || count($p) < 2) {
                    continue;
                }
                [$wx, $wz] = $toWorld((float) $p[0], (float) $p[1]);
                [$nx, $nz] = $applyRigid($wx, $wz);
                $moved[] = [round($nx - $minX, 4), round($nz - $minZ, 4)];
            }
            $room['walk_path_m'] = $moved;
        }

        return $room;
    }

    public static function validateRotation(float $deg): void
    {
        if (!is_finite($deg) || abs($deg) > self::MAX_ROTATION_DEG) {
            throw new \InvalidArgumentException('invalid_rotation');
        }
    }

    public static function validateTranslation(float $tx, float $tz): void
    {
        if (!is_finite($tx) || !is_finite($tz)
            || abs($tx) > self::MAX_TRANSLATION_M
            || abs($tz) > self::MAX_TRANSLATION_M) {
            throw new \InvalidArgumentException('invalid_translation');
        }
    }

    public static function centroid(array $rooms): array
    {
        $minX = INF;
        $minZ = INF;
        $maxX = -INF;
        $maxZ = -INF;
        foreach ($rooms as $room) {
            $origin = $room['structure_origin_m'] ?? null;
            if (!is_array($origin) || count($origin) < 2) {
                continue;
            }
            foreach (($room['outline_m'] ?? []) as $p) {
                $wx = (float) $origin[0] + (float) $p[0];
                $wz = (float) $origin[1] + (float) $p[1];
                $minX = min($minX, $wx);
                $minZ = min($minZ, $wz);
                $maxX = max($maxX, $wx);
                $maxZ = max($maxZ, $wz);
            }
        }
        if (!is_finite($minX)) {
            return [0.0, 0.0];
        }
        return [($minX + $maxX) / 2.0, ($minZ + $maxZ) / 2.0];
    }

    public static function distanceBetweenCentroids(array $a, array $b): float
    {
        [$ax, $az] = self::centroid($a);
        [$bx, $bz] = self::centroid($b);
        return sqrt(($ax - $bx) ** 2 + ($az - $bz) ** 2);
    }

    private static function roomHasSplits(array $room): bool
    {
        return isset($room['room_splits']) && is_array($room['room_splits']) && $room['room_splits'] !== [];
    }
}
