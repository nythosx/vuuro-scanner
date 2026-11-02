<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class TourReadiness
{
    public const OUTSIDE_TOLERANCE_M = 0.3;

    public static function compute(array $rooms, array $standsByRoom): array
    {
        $roomReports = [];
        $positioned = 0;
        $inside = 0;
        $worstOutside = 0.0;
        $roomsWithoutPhotos = [];
        $spotCount = 0;
        $unconnected = [];
        $roomsWithoutDoor = [];

        foreach ($rooms as $room) {
            $roomId = (string) ($room['room_id'] ?? '');
            $label = (string) ($room['label'] ?? $roomId);
            $outline = self::outline($room['outline_m'] ?? null);
            $photos = is_array($room['photos'] ?? null) ? $room['photos'] : [];

            $roomPositioned = 0;
            $roomInside = 0;
            $roomWorst = 0.0;
            $standIds = [];
            foreach ($photos as $photo) {
                $standId = $photo['stand_id'] ?? null;
                if (is_string($standId) && $standId !== '') {
                    $standIds[$standId] = true;
                }
                $point = self::point($photo['position_m'] ?? null);
                if ($point === null || $outline === null) {
                    continue;
                }
                $roomPositioned++;
                $outside = self::distanceOutside($point, $outline);
                if ($outside <= self::OUTSIDE_TOLERANCE_M) {
                    $roomInside++;
                }
                $roomWorst = max($roomWorst, $outside);
            }

            $spots = [];
            $roomUnconnected = [];
            foreach ($standsByRoom[$roomId] ?? [] as $stand) {
                $id = (string) ($stand['stand_id'] ?? '');
                if (!isset($standIds[$id])) {
                    continue;
                }
                $spots[] = $id;
                if (empty($stand['neighbours'])) {
                    $roomUnconnected[] = $id;
                }
            }

            $hasDoor = self::hasDoor($room);

            $positioned += $roomPositioned;
            $inside += $roomInside;
            $worstOutside = max($worstOutside, $roomWorst);
            if ($photos === []) {
                $roomsWithoutPhotos[] = $label;
            }
            $spotCount += count($spots);
            foreach ($roomUnconnected as $id) {
                $unconnected[] = ['room' => $label, 'stand_id' => $id];
            }
            if (!$hasDoor) {
                $roomsWithoutDoor[] = $label;
            }

            $roomReports[] = [
                'room_id' => $roomId,
                'label' => $label,
                'photos' => count($photos),
                'positioned' => $roomPositioned,
                'inside' => $roomInside,
                'max_outside_m' => round($roomWorst, 2),
                'spots' => count($spots),
                'unconnected_spots' => count($roomUnconnected),
                'door' => $hasDoor,
            ];
        }

        $checks = [
            self::positionsCheck($positioned, $inside, $worstOutside),
            self::photosCheck(count($rooms), $roomsWithoutPhotos),
            self::spotsCheck($spotCount, $unconnected),
            self::doorsCheck(count($rooms), $roomsWithoutDoor),
        ];

        $ready = true;
        foreach ($checks as $check) {
            if ($check['status'] === 'fail') {
                $ready = false;
            }
        }

        return [
            'ready' => $ready,
            'tolerance_m' => self::OUTSIDE_TOLERANCE_M,
            'checks' => $checks,
            'rooms' => $roomReports,
        ];
    }

    private static function positionsCheck(int $positioned, int $inside, float $worst): array
    {
        if ($positioned === 0) {
            return ['key' => 'positions_inside', 'status' => 'n/a', 'summary' => 'No photo has a position yet.'];
        }
        $outside = $positioned - $inside;
        if ($outside === 0) {
            return ['key' => 'positions_inside', 'status' => 'pass', 'summary' => "All $positioned photo positions are inside the room outline."];
        }
        return [
            'key' => 'positions_inside',
            'status' => 'fail',
            'summary' => "$outside of $positioned photo positions are outside the room outline, up to " . number_format($worst, 1) . ' m out.',
        ];
    }

    private static function photosCheck(int $roomCount, array $roomsWithoutPhotos): array
    {
        if ($roomCount === 0) {
            return ['key' => 'photos_per_room', 'status' => 'n/a', 'summary' => 'No rooms yet.'];
        }
        if ($roomsWithoutPhotos === []) {
            return ['key' => 'photos_per_room', 'status' => 'pass', 'summary' => 'Every room has photos.'];
        }
        return ['key' => 'photos_per_room', 'status' => 'fail', 'summary' => 'No photos in: ' . implode(', ', $roomsWithoutPhotos) . '.'];
    }

    private static function spotsCheck(int $spotCount, array $unconnected): array
    {
        if ($spotCount === 0) {
            return ['key' => 'connected_spots', 'status' => 'n/a', 'summary' => 'No 360 spots captured.'];
        }
        if ($spotCount === 1) {
            return ['key' => 'connected_spots', 'status' => 'pass', 'summary' => 'One 360 spot. Take a second spot to walk between them.'];
        }
        if ($unconnected === []) {
            return ['key' => 'connected_spots', 'status' => 'pass', 'summary' => "All $spotCount 360 spots connect to another spot."];
        }
        $names = array_map(static fn (array $u): string => $u['room'], $unconnected);
        return [
            'key' => 'connected_spots',
            'status' => 'fail',
            'summary' => count($unconnected) . " of $spotCount 360 spots do not connect to another spot (" . implode(', ', array_values(array_unique($names))) . ').',
        ];
    }

    private static function doorsCheck(int $roomCount, array $roomsWithoutDoor): array
    {
        if ($roomCount <= 1) {
            return ['key' => 'door_per_room', 'status' => 'n/a', 'summary' => 'Single room, no door needed to connect rooms.'];
        }
        if ($roomsWithoutDoor === []) {
            return ['key' => 'door_per_room', 'status' => 'pass', 'summary' => 'Every room has a door.'];
        }
        return ['key' => 'door_per_room', 'status' => 'fail', 'summary' => 'No door found in: ' . implode(', ', $roomsWithoutDoor) . '.'];
    }

    private static function hasDoor(array $room): bool
    {
        foreach (is_array($room['openings'] ?? null) ? $room['openings'] : [] as $opening) {
            if (is_array($opening) && ($opening['category'] ?? '') === 'door' && self::point($opening['position_m'] ?? null) !== null) {
                return true;
            }
        }
        return self::point($room['entry_doorway_m'] ?? null) !== null;
    }

    private static function point(mixed $value): ?array
    {
        if (!is_array($value) || count($value) < 2) {
            return null;
        }
        $x = $value[0] ?? null;
        $z = $value[1] ?? null;
        if (!is_numeric($x) || !is_numeric($z)) {
            return null;
        }
        return [(float) $x, (float) $z];
    }

    private static function outline(mixed $value): ?array
    {
        if (!is_array($value) || count($value) < 3) {
            return null;
        }
        $points = [];
        foreach ($value as $p) {
            $point = self::point($p);
            if ($point === null) {
                return null;
            }
            $points[] = $point;
        }
        return $points;
    }

    public static function distanceOutside(array $p, array $outline): float
    {
        $inside = false;
        $n = count($outline);
        $best = INF;
        for ($i = 0, $j = $n - 1; $i < $n; $j = $i++) {
            $a = $outline[$i];
            $b = $outline[$j];
            if ((($a[1] > $p[1]) !== ($b[1] > $p[1]))
                && ($p[0] < ($b[0] - $a[0]) * ($p[1] - $a[1]) / ($b[1] - $a[1]) + $a[0])) {
                $inside = !$inside;
            }
            $best = min($best, self::segmentDistance($p, $a, $b));
        }
        return $inside ? 0.0 : $best;
    }

    private static function segmentDistance(array $p, array $a, array $b): float
    {
        $dx = $b[0] - $a[0];
        $dz = $b[1] - $a[1];
        $len2 = $dx * $dx + $dz * $dz;
        $t = $len2 > 0 ? max(0.0, min(1.0, (($p[0] - $a[0]) * $dx + ($p[1] - $a[1]) * $dz) / $len2)) : 0.0;
        $cx = $a[0] + $t * $dx - $p[0];
        $cz = $a[1] + $t * $dz - $p[1];
        return sqrt($cx * $cx + $cz * $cz);
    }
}
