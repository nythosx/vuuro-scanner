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
        $nl = ExportLanguage::current() === ExportLanguage::NL;
        return $unit === self::IMPERIAL
            ? ExportLanguage::number($m2 * 10.7639104167, 2) . ' sqft'
            : ExportLanguage::number($m2, 2) . ($nl ? " m\u{00B2}" : ' sqm');
    }

    public static function length(float $m, string $unit): string
    {
        return $unit === self::IMPERIAL
            ? ExportLanguage::number($m * 3.2808398950131, 2) . ' ft'
            : ExportLanguage::number($m, 2) . ' m';
    }

    public static function volume(float $m3, string $unit): string
    {
        $nl = ExportLanguage::current() === ExportLanguage::NL;
        return $unit === self::IMPERIAL
            ? ExportLanguage::number($m3 * 35.3146667215, 2) . ' cuft'
            : ExportLanguage::number($m3, 2) . ($nl ? " m\u{00B3}" : ' m3');
    }
}
