<?php

declare(strict_types=1);

namespace VuuroScan;

final class RoomType
{
    public const VALUES = ['living_room', 'bedroom', 'bathroom', 'kitchen', 'dining_room'];
    public const GUESS_SOURCES = ['roomplan_section', 'object_heuristic'];
    public const CONFIRMED_VALUES = [...self::VALUES, 'other'];
    public const LABELS = [
        'living_room' => 'Living room',
        'bedroom' => 'Bedroom',
        'bathroom' => 'Bathroom',
        'kitchen' => 'Kitchen',
        'dining_room' => 'Dining room',
        'hallway' => 'Hallway',
        'office' => 'Office',
        'garage' => 'Garage',
        'laundry_room' => 'Laundry room',
        'storage_room' => 'Storage room',
        'balcony' => 'Balcony',
        'basement' => 'Basement',
        'attic' => 'Attic',
        'walk_in_closet' => 'Walk-in closet',
        'guest_room' => 'Guest room',
    ];

    public const CUSTOM_MAX_LENGTH = 60;

    public static function isValidConfirmedValue(string $value): bool
    {
        $trimmed = trim($value);
        if ($trimmed === '') {
            return false;
        }
        if (in_array($value, self::CONFIRMED_VALUES, true)) {
            return true;
        }
        if (mb_strlen($trimmed) > self::CUSTOM_MAX_LENGTH) {
            return false;
        }
        return preg_match('/[\x00-\x1f\x7f]/', $trimmed) !== 1;
    }

    public static function labelFor(string $value): string
    {
        return self::LABELS[$value] ?? $value;
    }

    public static function displayLabelForRoom(array $room): string
    {
        $roomType = is_array($room['room_type'] ?? null) ? $room['room_type'] : [];
        $confirmed = $roomType['confirmed'] ?? null;
        $label = (string) ($room['label'] ?? '');
        if (is_string($confirmed) && trim($confirmed) !== '' && preg_match('/^Room \d+$/', trim($label)) === 1) {
            return sprintf('%s (%s)', self::labelFor($confirmed), trim($label));
        }
        return self::displayLabel($label, $confirmed ?? $roomType['guess'] ?? null);
    }

    public static function displayLabel(string $label, ?string $roomTypeValue): string
    {
        if ($roomTypeValue === null) {
            return $label;
        }
        $typeName = self::labelFor($roomTypeValue);
        if (strcasecmp(trim($label), trim($typeName)) === 0) {
            return $label;
        }
        return sprintf('%s (%s)', $label, $typeName);
    }
}
