<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class TileOrientation
{
    public static function angleFor(array $outlineM): float
    {
        $n = count($outlineM);
        if ($n < 2) {
            return 0.0;
        }
        $longest = 0.0;
        $angle = 0.0;
        for ($i = 0; $i < $n; $i++) {
            [$ax, $az] = $outlineM[$i];
            [$bx, $bz] = $outlineM[($i + 1) % $n];
            $dx = $bx - $ax;
            $dz = $bz - $az;
            $len = sqrt($dx * $dx + $dz * $dz);
            if ($len > $longest) {
                $longest = $len;
                $angle = atan2($dz, $dx);
            }
        }
        return -$angle;
    }
}
