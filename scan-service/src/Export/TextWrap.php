<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class TextWrap
{
    public static function lines(string $text, int $maxChars): array
    {
        $lines = [];
        foreach (preg_split('/\R/u', mb_scrub($text, 'UTF-8')) ?: [''] as $paragraph) {
            $current = '';
            foreach (preg_split('/\s+/u', trim($paragraph), -1, PREG_SPLIT_NO_EMPTY) ?: [] as $word) {
                foreach (mb_str_split($word, $maxChars, 'UTF-8') as $piece) {
                    if ($current === '') {
                        $current = $piece;
                    } elseif (mb_strlen($current, 'UTF-8') + 1 + mb_strlen($piece, 'UTF-8') <= $maxChars) {
                        $current .= ' ' . $piece;
                    } else {
                        $lines[] = $current;
                        $current = $piece;
                    }
                }
            }
            $lines[] = $current;
        }
        return $lines === [] ? [''] : $lines;
    }
}
