<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FurnitureCatalog
{
    public const FIXTURES = [
        'sink', 'toilet', 'bathtub', 'stove', 'oven', 'dishwasher',
        'refrigerator', 'washerdryer', 'fireplace', 'stairs',
    ];

    public const MOVABLE = [
        'bed', 'sofa', 'chair', 'table', 'desk', 'television', 'storage', 'other',
    ];

    public const ALL = [...self::FIXTURES, ...self::MOVABLE];

    public const LABELS = [
        'sink' => 'Sink',
        'toilet' => 'Toilet',
        'bathtub' => 'Bathtub',
        'stove' => 'Stove',
        'oven' => 'Oven',
        'dishwasher' => 'Dishwasher',
        'refrigerator' => 'Fridge',
        'washerdryer' => 'Washer/Dryer',
        'fireplace' => 'Fireplace',
        'stairs' => 'Stairs',
        'bed' => 'Bed',
        'sofa' => 'Sofa',
        'chair' => 'Chair',
        'table' => 'Table',
        'desk' => 'Desk',
        'television' => 'TV',
        'storage' => 'Storage',
        'other' => 'Other',
    ];

    public static function normalize(string $category): string
    {
        return strtolower(str_replace(['_', ' ', '-'], '', $category));
    }

    public static function isFixture(string $category): bool
    {
        return in_array(self::normalize($category), self::FIXTURES, true);
    }

    public static function isFurniture(string $category): bool
    {
        return !self::isFixture($category);
    }

    public static function isKnown(string $category): bool
    {
        return in_array(self::normalize($category), self::ALL, true);
    }

    public static function labelFor(string $category): string
    {
        $normalized = self::normalize($category);
        return self::LABELS[$normalized] ?? ucfirst($normalized);
    }
}
