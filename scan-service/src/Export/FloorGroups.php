<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FloorGroups
{
    public static function split(array $rooms): array
    {
        $groups = [];
        $order = [];
        foreach (array_values($rooms) as $room) {
            $floor = self::floorName($room);
            $key = mb_strtolower($floor ?? '', 'UTF-8') . "\x1F" . self::batchToken($room);
            if (!isset($groups[$key])) {
                $groups[$key] = ['floor' => $floor, 'rooms' => []];
                $order[$key] = count($order);
            }
            $groups[$key]['rooms'][] = $room;
        }

        $keys = array_keys($groups);
        usort($keys, static function (string $a, string $b) use ($groups, $order): int {
            $floorA = $groups[$a]['floor'];
            $floorB = $groups[$b]['floor'];
            if (($floorA === null) !== ($floorB === null)) {
                return $floorA === null ? 1 : -1;
            }
            if ($floorA !== null && $floorB !== null) {
                $rankCompare = self::floorRank($floorB) <=> self::floorRank($floorA);
                if ($rankCompare !== 0) {
                    return $rankCompare;
                }
            }
            return $order[$a] <=> $order[$b];
        });

        return array_map(static fn (string $key) => $groups[$key], $keys);
    }

    public static function isFusable(array $rooms): bool
    {
        if (count($rooms) < 2) {
            return false;
        }
        foreach ($rooms as $room) {
            if (!isset($room['structure_origin_m'])) {
                return false;
            }
        }
        return true;
    }

    public static function headings(array $groups): array
    {
        $seen = [];
        $headings = [];
        foreach ($groups as $group) {
            $name = $group['floor'] ?? 'Floor not set';
            $key = mb_strtolower($name, 'UTF-8');
            $seen[$key] = ($seen[$key] ?? 0) + 1;
            $headings[] = $seen[$key] > 1 ? sprintf('%s (separate scan %d)', $name, $seen[$key]) : $name;
        }
        return $headings;
    }

    public static function floorRank(string $name): int
    {
        $n = mb_strtolower($name, 'UTF-8');
        foreach (['attic', 'zolder', 'roof', 'dak', 'loft'] as $word) {
            if (str_contains($n, $word)) {
                return 100;
            }
        }
        foreach (['basement', 'kelder', 'cellar', 'souterrain'] as $word) {
            if (str_contains($n, $word)) {
                return -10;
            }
        }
        if (str_contains($n, 'ground') || str_contains($n, 'begane') || str_contains($n, 'gelijkvloers') || $n === 'bg') {
            return 0;
        }
        if (preg_match('/\d+/', $n, $match) === 1) {
            return (int) $match[0];
        }
        $ordinals = ['first' => 1, 'eerste' => 1, 'second' => 2, 'tweede' => 2, 'third' => 3, 'derde' => 3, 'fourth' => 4, 'vierde' => 4];
        foreach ($ordinals as $word => $rank) {
            if (str_contains($n, $word)) {
                return $rank;
            }
        }
        return 5;
    }

    private static function floorName(array $room): ?string
    {
        $floor = $room['floor'] ?? null;
        if (!is_string($floor)) {
            return null;
        }
        $trimmed = trim($floor);
        return $trimmed === '' ? null : $trimmed;
    }

    private static function batchToken(array $room): string
    {
        $group = $room['capture_group_id'] ?? null;
        if (is_string($group) && $group !== '') {
            return 'group:' . $group;
        }
        return isset($room['structure_origin_m']) ? 'fused' : 'tiles';
    }
}
