<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class UnitFormatter
{
    public const METRIC = 'metric';
    public const IMPERIAL = 'imperial';
    public const VALID = [self::METRIC, self::IMPERIAL];

    public static function area(float $m2, string $unit): string
    {
        return $unit === self::IMPERIAL
            ? sprintf('%.2f sqft', $m2 * 10.7639104167)
            : sprintf('%.2f sqm', $m2);
    }

    public static function length(float $m, string $unit): string
    {
        return $unit === self::IMPERIAL
            ? sprintf('%.2f ft', $m * 3.2808398950131)
            : sprintf('%.2f m', $m);
    }

    public static function volume(float $m3, string $unit): string
    {
        return $unit === self::IMPERIAL
            ? sprintf('%.2f cuft', $m3 * 35.3146667215)
            : sprintf('%.2f m3', $m3);
    }
}
