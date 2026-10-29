<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class TourStands
{
    public const STAND_RADIUS_M = 0.75;
    public const MAX_NEIGHBOURS = 4;
    public const MAX_NEIGHBOUR_DISTANCE_M = 6.0;
    public const DOOR_LINK_RADIUS_M = 3.0;
    public const MIN_PHOTOS_FOR_LOOK_AROUND = 2;
    public const NEAREST_STAND_RADIUS_M = 3.0;

    public static function compute(array $rooms): array
    {
        $standsByRoom = [];
        foreach ($rooms as $room) {
            $standsByRoom[(string) $room['room_id']] = self::buildStands($room);
        }

        $edges = array_merge(
            self::doorEdges($standsByRoom, $rooms),
            self::roomEdges($standsByRoom)
        );
        self::applyEdges($standsByRoom, $edges);
        foreach ($standsByRoom as $roomId => $stands) {
            foreach ($stands as $index => $stand) {
                unset($standsByRoom[$roomId][$index]['captured']);
            }
        }

        $capturedPhotoCounts = [];
        foreach ($rooms as $room) {
            $roomId = (string) ($room['room_id'] ?? '');
            foreach (is_array($room['photos'] ?? null) ? $room['photos'] : [] as $photo) {
                $storedStandId = $photo['stand_id'] ?? null;
                if (!is_string($storedStandId) || $storedStandId === '' || self::photoPosition($photo) === null) {
                    continue;
                }
                $key = $roomId . "\0" . $storedStandId;
                $capturedPhotoCounts[$key] = ($capturedPhotoCounts[$key] ?? 0) + 1;
            }
        }
        $walkthrough = $capturedPhotoCounts !== [] && max($capturedPhotoCounts) >= self::MIN_PHOTOS_FOR_LOOK_AROUND;

        return [
            'stands_by_room' => $standsByRoom,
            'walkthrough' => $walkthrough,
        ];
    }

    private static function buildStands(array $room): array
    {
        $photos = is_array($room['photos'] ?? null) ? $room['photos'] : [];
        if ($photos === []) {
            return [];
        }

        usort($photos, static function (array $a, array $b): int {
            $byTime = strcmp((string) ($a['captured_at'] ?? ''), (string) ($b['captured_at'] ?? ''));
            if ($byTime !== 0) {
                return $byTime;
            }
            return strcmp((string) ($a['photo_id'] ?? ''), (string) ($b['photo_id'] ?? ''));
        });

        $headings = [];
        foreach ($photos as $photo) {
            $headings[(string) ($photo['photo_id'] ?? '')] = (float) ($photo['heading_deg'] ?? 0);
        }

        $stands = [];
        $sampleCounts = [];
        foreach ($photos as $photo) {
            $position = self::photoPosition($photo);
            if ($position === null) {
                continue;
            }
            $photoId = (string) ($photo['photo_id'] ?? '');
            $storedStandId = $photo['stand_id'] ?? null;
            $storedStandId = is_string($storedStandId) && $storedStandId !== '' ? $storedStandId : null;

            $targetIndex = null;
            if ($storedStandId !== null) {
                foreach ($stands as $index => $stand) {
                    if ($stand['stand_id'] === $storedStandId) {
                        $targetIndex = $index;
                        break;
                    }
                }
            } else {
                $bestDistance = self::STAND_RADIUS_M;
                foreach ($stands as $index => $stand) {
                    if ($stand['stand_id'] !== null) {
                        continue;
                    }
                    $distance = self::distance($stand['center_m'], $position);
                    if ($distance <= $bestDistance) {
                        $bestDistance = $distance;
                        $targetIndex = $index;
                    }
                }
            }

            if ($targetIndex === null) {
                $stands[] = [
                    'stand_id' => $storedStandId,
                    'center_m' => $position,
                    'photo_ids' => [$photoId],
                    'neighbours' => [],
                    'captured' => $storedStandId !== null,
                ];
                $sampleCounts[count($stands) - 1] = 1;
                continue;
            }

            $count = $sampleCounts[$targetIndex];
            $stands[$targetIndex]['center_m'] = [
                ($stands[$targetIndex]['center_m'][0] * $count + $position[0]) / ($count + 1),
                ($stands[$targetIndex]['center_m'][1] * $count + $position[1]) / ($count + 1),
            ];
            $stands[$targetIndex]['photo_ids'][] = $photoId;
            $sampleCounts[$targetIndex] = $count + 1;
        }

        $capturedIndexes = [];
        foreach ($stands as $index => $stand) {
            if ($stand['stand_id'] !== null) {
                $capturedIndexes[] = $index;
            }
        }
        if ($capturedIndexes !== []) {
            $mergedInto = [];
            foreach ($stands as $index => $stand) {
                if ($stand['stand_id'] !== null) {
                    continue;
                }
                $nearest = null;
                $nearestDistance = self::NEAREST_STAND_RADIUS_M;
                foreach ($capturedIndexes as $capturedIndex) {
                    $distance = self::distance($stands[$capturedIndex]['center_m'], $stand['center_m']);
                    if ($distance <= $nearestDistance) {
                        $nearestDistance = $distance;
                        $nearest = $capturedIndex;
                    }
                }
                if ($nearest !== null) {
                    foreach ($stand['photo_ids'] as $pid) {
                        $stands[$nearest]['photo_ids'][] = $pid;
                    }
                    $mergedInto[$index] = true;
                }
            }
            if ($mergedInto !== []) {
                $kept = [];
                foreach ($stands as $index => $stand) {
                    if (!isset($mergedInto[$index])) {
                        $kept[] = $stand;
                    }
                }
                $stands = $kept;
            }
        }

        $roomId = (string) ($room['room_id'] ?? '');
        foreach ($stands as $index => $stand) {
            if ($stand['stand_id'] === null) {
                $stands[$index]['stand_id'] = 'stand-' . $roomId . '-' . ($stand['photo_ids'][0] ?? '');
            }
            $ids = $stand['photo_ids'];
            usort($ids, static function (string $a, string $b) use ($headings): int {
                $ha = $headings[$a] ?? 0;
                $hb = $headings[$b] ?? 0;
                if ($ha === $hb) {
                    return $a <=> $b;
                }
                return $ha <=> $hb;
            });
            $stands[$index]['photo_ids'] = $ids;
        }

        return $stands;
    }

    private static function photoPosition(array $photo): ?array
    {
        $position = $photo['position_m'] ?? null;
        if (!is_array($position) || count($position) < 2) {
            return null;
        }
        $x = $position[0] ?? null;
        $z = $position[1] ?? null;
        if (!is_numeric($x) || !is_numeric($z)) {
            return null;
        }
        return [(float) $x, (float) $z];
    }

    private static function distance(array $a, array $b): float
    {
        $dx = $a[0] - $b[0];
        $dz = $a[1] - $b[1];
        return sqrt($dx * $dx + $dz * $dz);
    }

    private static function roomEdges(array $standsByRoom): array
    {
        $edges = [];
        foreach ($standsByRoom as $roomId => $stands) {
            $roomId = (string) $roomId;
            $count = count($stands);
            for ($i = 0; $i < $count; $i++) {
                for ($j = $i + 1; $j < $count; $j++) {
                    if ($stands[$i]['captured'] !== $stands[$j]['captured']) {
                        continue;
                    }
                    $distance = self::distance($stands[$i]['center_m'], $stands[$j]['center_m']);
                    if ($distance > self::MAX_NEIGHBOUR_DISTANCE_M) {
                        continue;
                    }
                    $edges[] = [
                        'priority' => 1,
                        'distance' => $distance,
                        'a_room' => $roomId,
                        'a_stand' => (string) $stands[$i]['stand_id'],
                        'b_room' => $roomId,
                        'b_stand' => (string) $stands[$j]['stand_id'],
                    ];
                }
            }
        }
        return $edges;
    }

    private static function applyEdges(array &$standsByRoom, array $edges): void
    {
        foreach ($edges as $index => $edge) {
            $first = $edge['a_room'] . "\0" . $edge['a_stand'];
            $second = $edge['b_room'] . "\0" . $edge['b_stand'];
            $edges[$index]['key'] = strcmp($first, $second) <= 0 ? $first . "\1" . $second : $second . "\1" . $first;
        }
        usort($edges, static function (array $a, array $b): int {
            return [$a['priority'], $a['distance'], $a['key']] <=> [$b['priority'], $b['distance'], $b['key']];
        });
        $degree = [];
        $seen = [];
        foreach ($edges as $edge) {
            if (isset($seen[$edge['key']])) {
                continue;
            }
            $first = $edge['a_room'] . "\0" . $edge['a_stand'];
            $second = $edge['b_room'] . "\0" . $edge['b_stand'];
            if (($degree[$first] ?? 0) >= self::MAX_NEIGHBOURS || ($degree[$second] ?? 0) >= self::MAX_NEIGHBOURS) {
                continue;
            }
            $seen[$edge['key']] = true;
            $degree[$first] = ($degree[$first] ?? 0) + 1;
            $degree[$second] = ($degree[$second] ?? 0) + 1;
            self::addNeighbour($standsByRoom, $edge['a_room'], $edge['a_stand'], $edge['b_stand'], $edge['b_room']);
            self::addNeighbour($standsByRoom, $edge['b_room'], $edge['b_stand'], $edge['a_stand'], $edge['a_room']);
        }
    }

    private static function doorEdges(array $standsByRoom, array $rooms): array
    {
        $edges = [];
        foreach ($rooms as $room) {
            $roomId = (string) ($room['room_id'] ?? '');
            if ($roomId === '' || empty($standsByRoom[$roomId])) {
                continue;
            }
            $origin = self::origin($room);
            if ($origin === null) {
                continue;
            }
            $floorKey = self::floorKey($room['floor'] ?? null);

            $doorPoints = [];
            foreach ($room['openings'] ?? [] as $opening) {
                if (is_array($opening) && ($opening['category'] ?? '') === 'door') {
                    $doorPoints[] = $opening['position_m'] ?? null;
                }
            }
            $doorPoints[] = $room['entry_doorway_m'] ?? null;
            foreach ($doorPoints as $position) {
                if (!is_array($position) || count($position) < 2 || !is_numeric($position[0]) || !is_numeric($position[1])) {
                    continue;
                }
                $doorWorld = [(float) $position[0] + $origin[0], (float) $position[1] + $origin[1]];

                foreach ([true, false] as $captured) {
                    $selfStand = self::nearestStandInRoom($standsByRoom, $roomId, $origin, $doorWorld, self::DOOR_LINK_RADIUS_M, $captured);
                    if ($selfStand === null) {
                        continue;
                    }

                    $bestTarget = null;
                    foreach ($rooms as $other) {
                        $otherRoomId = (string) ($other['room_id'] ?? '');
                        if ($otherRoomId === '' || $otherRoomId === $roomId) {
                            continue;
                        }
                        if (self::floorKey($other['floor'] ?? null) !== $floorKey) {
                            continue;
                        }
                        $otherOrigin = self::origin($other);
                        if ($otherOrigin === null) {
                            continue;
                        }
                        if (empty($standsByRoom[$otherRoomId])) {
                            continue;
                        }
                        $candidate = self::nearestStandInRoom($standsByRoom, $otherRoomId, $otherOrigin, $doorWorld, self::DOOR_LINK_RADIUS_M, $captured);
                        if ($candidate === null) {
                            continue;
                        }
                        if ($bestTarget === null || $candidate['distance'] < $bestTarget['distance']) {
                            $bestTarget = [
                                'room_id' => $otherRoomId,
                                'stand_id' => $candidate['stand_id'],
                                'distance' => $candidate['distance'],
                            ];
                        }
                    }
                    if ($bestTarget === null) {
                        continue;
                    }
                    $edges[] = [
                        'priority' => 0,
                        'distance' => $selfStand['distance'] + $bestTarget['distance'],
                        'a_room' => $roomId,
                        'a_stand' => (string) $selfStand['stand_id'],
                        'b_room' => $bestTarget['room_id'],
                        'b_stand' => (string) $bestTarget['stand_id'],
                    ];
                }
            }
        }
        return $edges;
    }

    private static function nearestStandInRoom(array $standsByRoom, string $roomId, array $origin, array $doorWorld, float $maxDistance, ?bool $captured = null): ?array
    {
        $best = null;
        $bestDistance = $maxDistance;
        foreach ($standsByRoom[$roomId] ?? [] as $stand) {
            if ($captured !== null && $stand['captured'] !== $captured) {
                continue;
            }
            $world = [$stand['center_m'][0] + $origin[0], $stand['center_m'][1] + $origin[1]];
            $distance = self::distance($world, $doorWorld);
            if ($distance <= $bestDistance) {
                $bestDistance = $distance;
                $best = ['stand_id' => $stand['stand_id'], 'distance' => $distance, 'captured' => $stand['captured']];
            }
        }
        return $best;
    }

    private static function addNeighbour(array &$standsByRoom, string $sourceRoomId, string $sourceStandId, string $targetStandId, string $targetRoomId): void
    {
        if (!isset($standsByRoom[$sourceRoomId])) {
            return;
        }
        foreach ($standsByRoom[$sourceRoomId] as $index => $stand) {
            if ($stand['stand_id'] !== $sourceStandId) {
                continue;
            }
            foreach ($stand['neighbours'] as $existing) {
                if ($existing['stand_id'] === $targetStandId) {
                    return;
                }
            }
            $standsByRoom[$sourceRoomId][$index]['neighbours'][] = [
                'stand_id' => $targetStandId,
                'room_id' => $targetRoomId,
            ];
            return;
        }
    }

    private static function origin(array $room): ?array
    {
        $origin = $room['structure_origin_m'] ?? null;
        if (!is_array($origin) || count($origin) < 2 || !is_numeric($origin[0]) || !is_numeric($origin[1])) {
            return null;
        }
        return [(float) $origin[0], (float) $origin[1]];
    }

    private static function floorKey(mixed $floor): string
    {
        return is_string($floor) ? mb_strtolower(trim($floor), 'UTF-8') : '';
    }
}
