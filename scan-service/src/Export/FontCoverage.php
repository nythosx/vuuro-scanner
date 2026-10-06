<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FontCoverage
{
    private static array $fonts = [];

    public static function has(string $fontPath, int $codepoint): bool
    {
        if (!array_key_exists($fontPath, self::$fonts)) {
            self::$fonts[$fontPath] = self::load($fontPath);
        }
        $font = self::$fonts[$fontPath];
        if ($font === null) {
            return true;
        }
        [$data, $offset, $format] = $font;
        return $format === 12 ? self::format12($data, $offset, $codepoint) : self::format4($data, $offset, $codepoint);
    }

    private static function load(string $fontPath): ?array
    {
        $data = @file_get_contents($fontPath);
        if ($data === false || strlen($data) < 12) {
            return null;
        }
        $numTables = self::u16($data, 4);
        $cmap = null;
        for ($i = 0; $i < $numTables; $i++) {
            $record = 12 + $i * 16;
            if (substr($data, $record, 4) === 'cmap') {
                $cmap = self::u32($data, $record + 8);
                break;
            }
        }
        if ($cmap === null) {
            return null;
        }
        $best = null;
        $subtables = self::u16($data, $cmap + 2);
        for ($i = 0; $i < $subtables; $i++) {
            $record = $cmap + 4 + $i * 8;
            $platform = self::u16($data, $record);
            $encoding = self::u16($data, $record + 2);
            $offset = $cmap + self::u32($data, $record + 4);
            $format = self::u16($data, $offset);
            $unicode = $platform === 0 || ($platform === 3 && ($encoding === 1 || $encoding === 10));
            if (!$unicode || ($format !== 4 && $format !== 12)) {
                continue;
            }
            if ($best === null || ($format === 12 && $best[2] === 4)) {
                $best = [$data, $offset, $format];
            }
        }
        return $best;
    }

    private static function format4(string $data, int $offset, int $codepoint): bool
    {
        if ($codepoint > 0xFFFF) {
            return false;
        }
        $segCount = intdiv(self::u16($data, $offset + 6), 2);
        $ends = $offset + 14;
        $starts = $ends + $segCount * 2 + 2;
        $deltas = $starts + $segCount * 2;
        $rangeOffsets = $deltas + $segCount * 2;
        for ($i = 0; $i < $segCount; $i++) {
            if ($codepoint > self::u16($data, $ends + $i * 2)) {
                continue;
            }
            $start = self::u16($data, $starts + $i * 2);
            if ($codepoint < $start) {
                return false;
            }
            $delta = self::u16($data, $deltas + $i * 2);
            $rangeOffsetPos = $rangeOffsets + $i * 2;
            $rangeOffset = self::u16($data, $rangeOffsetPos);
            if ($rangeOffset === 0) {
                return (($codepoint + $delta) & 0xFFFF) !== 0;
            }
            $glyph = self::u16($data, $rangeOffsetPos + $rangeOffset + 2 * ($codepoint - $start));
            return $glyph !== 0 && (($glyph + $delta) & 0xFFFF) !== 0;
        }
        return false;
    }

    private static function format12(string $data, int $offset, int $codepoint): bool
    {
        $groups = self::u32($data, $offset + 12);
        for ($i = 0; $i < $groups; $i++) {
            $group = $offset + 16 + $i * 12;
            $start = self::u32($data, $group);
            if ($codepoint < $start) {
                return false;
            }
            if ($codepoint <= self::u32($data, $group + 4)) {
                return self::u32($data, $group + 8) + ($codepoint - $start) !== 0;
            }
        }
        return false;
    }

    private static function u16(string $data, int $at): int
    {
        return $at + 2 <= strlen($data) ? unpack('n', $data, $at)[1] : 0;
    }

    private static function u32(string $data, int $at): int
    {
        return $at + 4 <= strlen($data) ? unpack('N', $data, $at)[1] : 0;
    }
}
