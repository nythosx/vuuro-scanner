<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class TourStands
{
    public const STAND_RADIUS_M = 0.75;
    public const MAX_NEIGHBOURS = 4;
    public const MAX_NEIGHBOUR_DISTANCE_M = 6.0;
    public const DOOR_LINK_RADIUS_M = 3.0;
    public const MIN_STANDS_FOR_WALKTHROUGH = 2;

    public static function compute(array $rooms): array
    {
        $standsByRoom = [];
        foreach ($rooms as $room) {
            $standsByRoom[(string) $room['room_id']] = self::buildStands($room);
        }

        self::linkWithinRooms($standsByRoom);
        self::linkAcrossRoomsThroughDoors($standsByRoom, $rooms);
        self::symmetrise($standsByRoom);

        $maxStands = 0;
        foreach ($standsByRoom as $stands) {
            $maxStands = max($maxStands, count($stands));
        }

        return [
            'stands_by_room' => $standsByRoom,
            'walkthrough' => $maxStands >= self::MIN_STANDS_FOR_WALKTHROUGH,
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

    private static function linkWithinRooms(array &$standsByRoom): void
    {
        foreach ($standsByRoom as $roomId => $stands) {
            $count = count($stands);
            if ($count < 2) {
                continue;
            }
            foreach ($stands as $i => $stand) {
                $candidates = [];
                foreach ($stands as $j => $other) {
                    if ($i === $j) {
                        continue;
                    }
                    $distance = self::distance($stand['center_m'], $other['center_m']);
                    if ($distance > self::MAX_NEIGHBOUR_DISTANCE_M) {
                        continue;
                    }
                    $candidates[] = ['index' => $j, 'distance' => $distance];
                }
                usort($candidates, static function (array $a, array $b): int {
                    return $a['distance'] <=> $b['distance'];
                });
                $candidates = array_slice($candidates, 0, self::MAX_NEIGHBOURS);
                foreach ($candidates as $candidate) {
                    self::addNeighbour(
                        $standsByRoom,
                        $roomId,
                        $stand['stand_id'],
                        $stands[$candidate['index']]['stand_id'],
                        $roomId
                    );
                }
            }
        }
    }

    private static function linkAcrossRoomsThroughDoors(array &$standsByRoom, array $rooms): void
    {
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

            foreach ($room['openings'] ?? [] as $opening) {
                if (!is_array($opening) || ($opening['category'] ?? '') !== 'door') {
                    continue;
                }
                $position = $opening['position_m'] ?? null;
                if (!is_array($position) || count($position) < 2 || !is_numeric($position[0]) || !is_numeric($position[1])) {
                    continue;
                }
                $doorWorld = [(float) $position[0] + $origin[0], (float) $position[1] + $origin[1]];

                $selfStand = self::nearestStandInRoom($standsByRoom, $roomId, $origin, $doorWorld, self::DOOR_LINK_RADIUS_M);
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
                    $candidate = self::nearestStandInRoom($standsByRoom, $otherRoomId, $otherOrigin, $doorWorld, self::DOOR_LINK_RADIUS_M);
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
                self::addNeighbour($standsByRoom, $roomId, $selfStand['stand_id'], $bestTarget['stand_id'], $bestTarget['room_id']);
            }
        }
    }

    private static function nearestStandInRoom(array $standsByRoom, string $roomId, array $origin, array $doorWorld, float $maxDistance): ?array
    {
        $best = null;
        $bestDistance = $maxDistance;
        foreach ($standsByRoom[$roomId] ?? [] as $stand) {
            $world = [$stand['center_m'][0] + $origin[0], $stand['center_m'][1] + $origin[1]];
            $distance = self::distance($world, $doorWorld);
            if ($distance <= $bestDistance) {
                $bestDistance = $distance;
                $best = ['stand_id' => $stand['stand_id'], 'distance' => $distance];
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

    private static function symmetrise(array &$standsByRoom): void
    {
        $lookup = [];
        foreach ($standsByRoom as $roomId => $stands) {
            foreach ($stands as $index => $stand) {
                $lookup[$stand['stand_id']] = ['room_id' => $roomId, 'index' => $index];
            }
        }
        $edges = [];
        foreach ($standsByRoom as $roomId => $stands) {
            foreach ($stands as $stand) {
                foreach ($stand['neighbours'] as $neighbour) {
                    $edges[] = [$roomId, $stand['stand_id'], $neighbour['room_id'], $neighbour['stand_id']];
                }
            }
        }
        foreach ($edges as [$fromRoom, $fromStand, $toRoom, $toStand]) {
            self::addNeighbour($standsByRoom, $toRoom, $toStand, $fromStand, $fromRoom);
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
