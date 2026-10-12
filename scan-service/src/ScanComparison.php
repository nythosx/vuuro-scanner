<?php

declare(strict_types=1);

namespace VuuroScan;

final class ScanComparison
{
    public static function compare(array $earlierPlan, array $laterPlan, float $areaChangeM2, float $areaChangePercent): array
    {
        $earlierRooms = array_values($earlierPlan['rooms'] ?? []);
        $laterRooms = array_values($laterPlan['rooms'] ?? []);
        $pairs = self::matchRooms($earlierRooms, $laterRooms);

        $matchedEarlier = [];
        $matchedLater = [];
        $changed = [];
        $unchanged = [];
        $objectsGone = [];
        foreach ($pairs as [$earlierIndex, $laterIndex, $matchedBy]) {
            $matchedEarlier[$earlierIndex] = true;
            $matchedLater[$laterIndex] = true;
            $earlier = $earlierRooms[$earlierIndex];
            $later = $laterRooms[$laterIndex];
            $earlierArea = (float) ($earlier['floor_area_m2'] ?? 0.0);
            $laterArea = (float) ($later['floor_area_m2'] ?? 0.0);
            $delta = $laterArea - $earlierArea;
            $percent = $earlierArea > 0.0 ? $delta / $earlierArea * 100.0 : null;
            $entry = [
                'earlier_room_id' => $earlier['room_id'] ?? null,
                'later_room_id' => $later['room_id'] ?? null,
                'label' => (string) ($later['label'] ?? ''),
                'floor' => $later['floor'] ?? null,
                'matched_by' => $matchedBy,
                'earlier_area_m2' => round($earlierArea, 2),
                'later_area_m2' => round($laterArea, 2),
                'area_change_m2' => round($delta, 2),
                'area_change_percent' => $percent === null ? null : round($percent, 1),
            ];
            $isChanged = abs($delta) > $areaChangeM2 || ($percent !== null && abs($percent) > $areaChangePercent);
            if ($isChanged) {
                $changed[] = $entry;
            } else {
                $unchanged[] = $entry;
            }
            foreach (self::objectsGone($earlier, $later) as $name => $count) {
                $objectsGone[] = [
                    'later_room_id' => $later['room_id'] ?? null,
                    'room_label' => (string) ($later['label'] ?? ''),
                    'floor' => $later['floor'] ?? null,
                    'name' => (string) $name,
                    'count' => $count,
                ];
            }
        }

        $added = [];
        foreach ($laterRooms as $index => $room) {
            if (!isset($matchedLater[$index])) {
                $added[] = self::roomSummary($room);
            }
        }
        $notMatched = [];
        foreach ($earlierRooms as $index => $room) {
            if (!isset($matchedEarlier[$index])) {
                $notMatched[] = self::roomSummary($room);
            }
        }

        $laterLabels = [];
        foreach ($laterRooms as $room) {
            $laterLabels[(string) ($room['room_id'] ?? '')] = (string) ($room['label'] ?? '');
        }

        return [
            'measurement_basis' => 'indicative',
            'thresholds' => ['area_change_m2' => $areaChangeM2, 'area_change_percent' => $areaChangePercent],
            'rooms' => [
                'added' => $added,
                'changed' => $changed,
                'unchanged' => $unchanged,
                'not_matched' => $notMatched,
            ],
            'notes_added' => self::damageFirst(array_map(
                static fn (array $note): array => [
                    'note_id' => $note['note_id'] ?? null,
                    'room_id' => $note['room_id'] ?? null,
                    'room_label' => isset($note['room_id']) ? ($laterLabels[(string) $note['room_id']] ?? null) : null,
                    'text' => (string) ($note['text'] ?? ''),
                    'tags' => self::tags($note),
                ],
                array_values($laterPlan['notes'] ?? [])
            )),
            'photos_added' => self::damageFirst(array_map(
                static fn (array $photo): array => [
                    'photo_id' => $photo['photo_id'] ?? null,
                    'room_id' => $photo['room_id'] ?? null,
                    'room_label' => isset($photo['room_id']) ? ($laterLabels[(string) $photo['room_id']] ?? null) : null,
                    'caption' => $photo['caption'] ?? null,
                    'url' => $photo['url'] ?? null,
                    'tags' => self::tags($photo),
                ],
                array_values($laterPlan['photos'] ?? [])
            )),
            'objects_gone' => $objectsGone,
        ];
    }

    public static function roomKey(array $room): string
    {
        return self::normalize((string) ($room['label'] ?? '')) . '|' . self::normalize(is_string($room['floor'] ?? null) ? $room['floor'] : '');
    }

    private static function matchRooms(array $earlierRooms, array $laterRooms): array
    {
        $pairs = [];
        $usedEarlier = [];
        $usedLater = [];
        $earlierById = [];
        foreach ($earlierRooms as $index => $room) {
            $id = $room['room_id'] ?? null;
            if (is_string($id) && $id !== '' && !isset($earlierById[$id])) {
                $earlierById[$id] = $index;
            }
        }
        foreach ($laterRooms as $laterIndex => $room) {
            $id = $room['room_id'] ?? null;
            if (is_string($id) && isset($earlierById[$id]) && !isset($usedEarlier[$earlierById[$id]])) {
                $pairs[] = [$earlierById[$id], $laterIndex, 'room_id'];
                $usedEarlier[$earlierById[$id]] = true;
                $usedLater[$laterIndex] = true;
            }
        }
        foreach ($laterRooms as $laterIndex => $room) {
            if (isset($usedLater[$laterIndex]) || self::normalize((string) ($room['label'] ?? '')) === '') {
                continue;
            }
            $key = self::roomKey($room);
            foreach ($earlierRooms as $earlierIndex => $earlierRoom) {
                if (!isset($usedEarlier[$earlierIndex]) && self::roomKey($earlierRoom) === $key) {
                    $pairs[] = [$earlierIndex, $laterIndex, 'label_and_floor'];
                    $usedEarlier[$earlierIndex] = true;
                    $usedLater[$laterIndex] = true;
                    break;
                }
            }
        }
        return $pairs;
    }

    private static function objectsGone(array $earlier, array $later): array
    {
        $earlierCounts = self::objectCounts($earlier);
        $laterCounts = self::objectCounts($later);
        $gone = [];
        foreach ($earlierCounts as $key => [$name, $count]) {
            $missing = $count - ($laterCounts[$key][1] ?? 0);
            if ($missing > 0) {
                $gone[$name] = $missing;
            }
        }
        return $gone;
    }

    private static function objectCounts(array $room): array
    {
        $counts = [];
        foreach (is_array($room['objects'] ?? null) ? $room['objects'] : [] as $object) {
            if (!is_array($object)) {
                continue;
            }
            $customName = is_string($object['custom_name'] ?? null) ? trim($object['custom_name']) : '';
            $name = $customName !== '' ? $customName : trim((string) ($object['category'] ?? ''));
            if ($name === '') {
                continue;
            }
            $key = mb_strtolower($name, 'UTF-8');
            $counts[$key] = [$counts[$key][0] ?? $name, ($counts[$key][1] ?? 0) + 1];
        }
        return $counts;
    }

    private static function roomSummary(array $room): array
    {
        return [
            'room_id' => $room['room_id'] ?? null,
            'label' => (string) ($room['label'] ?? ''),
            'floor' => $room['floor'] ?? null,
            'area_m2' => round((float) ($room['floor_area_m2'] ?? 0.0), 2),
        ];
    }

    private static function tags(array $item): array
    {
        return array_values(array_filter(is_array($item['tags'] ?? null) ? $item['tags'] : [], 'is_string'));
    }

    private static function damageFirst(array $items): array
    {
        $damage = array_values(array_filter($items, static fn (array $item): bool => in_array('damage', $item['tags'], true)));
        $other = array_values(array_filter($items, static fn (array $item): bool => !in_array('damage', $item['tags'], true)));
        return [...$damage, ...$other];
    }

    private static function normalize(string $value): string
    {
        return preg_replace('/\s+/u', '', mb_strtolower(trim($value), 'UTF-8')) ?? '';
    }
}
