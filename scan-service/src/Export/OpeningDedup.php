<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class OpeningDedup
{
    private const SAME_OPENING_DISTANCE_M = 0.45;

    public static function filter(array $rooms, array $poses): array
    {
        $kept = [];
        foreach ($rooms as $i => $room) {
            $openings = [];
            foreach ($room['openings'] ?? [] as $opening) {
                [$wx, $wz] = RoomFusionSolver::transformPoint($poses[$i], (float) $opening['position_m'][0], (float) $opening['position_m'][1]);
                $category = (string) ($opening['category'] ?? '');
                $duplicate = false;
                foreach ($kept as [$keptCategory, $kx, $kz]) {
                    if ($keptCategory === $category && hypot($kx - $wx, $kz - $wz) < self::SAME_OPENING_DISTANCE_M) {
                        $duplicate = true;
                        break;
                    }
                }
                if ($duplicate) {
                    continue;
                }
                $kept[] = [$category, $wx, $wz];
                $openings[] = $opening;
            }
            $rooms[$i]['openings'] = $openings;
        }
        return $rooms;
    }
}
