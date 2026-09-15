<?php

declare(strict_types=1);

namespace VuuroScan;

final class InspectionTag
{
    public const VALUES = [
        'damage',
        'wear_and_tear',
        'missing_item',
        'safety_issue',
        'pre_existing_condition',
        'maintenance_needed',
        'confirmed_present',
        'other',
    ];

    public const LABELS = [
        'damage' => 'Damage',
        'wear_and_tear' => 'Wear and tear',
        'missing_item' => 'Missing item',
        'safety_issue' => 'Safety issue',
        'pre_existing_condition' => 'Pre-existing condition',
        'maintenance_needed' => 'Maintenance needed',
        'confirmed_present' => 'Confirmed present',
        'other' => 'Other',
    ];

    public static function isValidList(array $tags): bool
    {
        foreach ($tags as $tag) {
            if (!is_string($tag) || !in_array($tag, self::VALUES, true)) {
                return false;
            }
        }
        return true;
    }

    public static function labelFor(string $value): string
    {
        return self::LABELS[$value] ?? $value;
    }
}
