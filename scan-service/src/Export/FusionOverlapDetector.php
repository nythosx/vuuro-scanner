<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FusionOverlapDetector
{
    private const OVERLAP_FRACTION_THRESHOLD = 0.15;

    public static function detect(array $rooms): array
    {
        $outlines = [];
        $boxes = [];
        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $minX = INF;
            $minZ = INF;
            $maxX = -INF;
            $maxZ = -INF;
            $outline = [];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                $worldX = $mx + $originX;
                $worldZ = $mz + $originZ;
                $outline[] = [$worldX, $worldZ];
                $minX = min($minX, $worldX);
                $minZ = min($minZ, $worldZ);
                $maxX = max($maxX, $worldX);
                $maxZ = max($maxZ, $worldZ);
            }
            $outlines[$i] = $outline;
            $boxes[$i] = [$minX, $minZ, $maxX, $maxZ];
        }

        $flagged = [];
        $indices = array_keys($boxes);
        $n = count($indices);
        for ($a = 0; $a < $n; $a++) {
            for ($b = $a + 1; $b < $n; $b++) {
                [$aMinX, $aMinZ, $aMaxX, $aMaxZ] = $boxes[$indices[$a]];
                [$bMinX, $bMinZ, $bMaxX, $bMaxZ] = $boxes[$indices[$b]];
                if (min($aMaxX, $bMaxX) - max($aMinX, $bMinX) <= 0 || min($aMaxZ, $bMaxZ) - max($aMinZ, $bMinZ) <= 0) {
                    continue;
                }

                $polyA = $outlines[$indices[$a]];
                $polyB = $outlines[$indices[$b]];
                $overlapAreaM2 = self::intersectionArea($polyA, $polyB);
                if ($overlapAreaM2 <= 0.0) {
                    continue;
                }
                $areaA = self::polygonArea($polyA);
                $areaB = self::polygonArea($polyB);
                $smallerArea = min($areaA, $areaB);
                if ($smallerArea > 0 && $overlapAreaM2 / $smallerArea > self::OVERLAP_FRACTION_THRESHOLD) {
                    $flagged[$indices[$a]] = true;
                    $flagged[$indices[$b]] = true;
                }
            }
        }
        return array_keys($flagged);
    }

    private static function intersectionArea(array $polyA, array $polyB): float
    {
        $trianglesA = self::triangulate($polyA);
        $trianglesB = self::triangulate($polyB);
        $total = 0.0;
        foreach ($trianglesA as $triangleA) {
            foreach ($trianglesB as $triangleB) {
                $total += self::polygonArea(self::clipConvex($triangleA, $triangleB));
            }
        }
        return $total;
    }

    private static function triangulate(array $polygon): array
    {
        if (self::signedArea($polygon) < 0) {
            $polygon = array_reverse($polygon);
        }
        $indices = array_keys($polygon);
        $triangles = [];
        $guard = 0;
        while (count($indices) > 3 && $guard < 10000) {
            $guard++;
            $m = count($indices);
            $earFound = false;
            for ($i = 0; $i < $m; $i++) {
                $iPrev = $indices[($i - 1 + $m) % $m];
                $iCurr = $indices[$i];
                $iNext = $indices[($i + 1) % $m];
                $prev = $polygon[$iPrev];
                $curr = $polygon[$iCurr];
                $next = $polygon[$iNext];
                if (self::cross($prev, $curr, $next) <= 1e-9) {
                    continue;
                }
                $isEar = true;
                foreach ($indices as $idx) {
                    if ($idx === $iPrev || $idx === $iCurr || $idx === $iNext) {
                        continue;
                    }
                    if (self::pointInTriangle($polygon[$idx], $prev, $curr, $next)) {
                        $isEar = false;
                        break;
                    }
                }
                if ($isEar) {
                    $triangles[] = [$prev, $curr, $next];
                    array_splice($indices, $i, 1);
                    $earFound = true;
                    break;
                }
            }
            if (!$earFound) {
                break; // numerically degenerate input; stop rather than loop forever
            }
        }
        if (count($indices) === 3) {
            $triangles[] = [$polygon[$indices[0]], $polygon[$indices[1]], $polygon[$indices[2]]];
        }
        return $triangles;
    }

    // Sutherland-Hodgman: clips $subject against convex polygon $clip.
    // Exact for any subject as long as $clip is convex — both inputs here
    // are always triangles, so that always holds.
    private static function clipConvex(array $subject, array $clip): array
    {
        $output = $subject;
        $clipN = count($clip);
        for ($i = 0; $i < $clipN && $output !== []; $i++) {
            $edgeA = $clip[$i];
            $edgeB = $clip[($i + 1) % $clipN];
            $input = $output;
            $output = [];
            $n = count($input);
            for ($j = 0; $j < $n; $j++) {
                $curr = $input[$j];
                $prev = $input[($j - 1 + $n) % $n];
                $currInside = self::cross($edgeA, $edgeB, $curr) >= 0;
                $prevInside = self::cross($edgeA, $edgeB, $prev) >= 0;
                if ($currInside) {
                    if (!$prevInside) {
                        $output[] = self::lineIntersection($prev, $curr, $edgeA, $edgeB);
                    }
                    $output[] = $curr;
                } elseif ($prevInside) {
                    $output[] = self::lineIntersection($prev, $curr, $edgeA, $edgeB);
                }
            }
        }
        return $output;
    }

    private static function lineIntersection(array $p1, array $p2, array $p3, array $p4): array
    {
        [$x1, $y1] = $p1;
        [$x2, $y2] = $p2;
        [$x3, $y3] = $p3;
        [$x4, $y4] = $p4;
        $denom = ($x1 - $x2) * ($y3 - $y4) - ($y1 - $y2) * ($x3 - $x4);
        if (abs($denom) < 1e-12) {
            return $p2;
        }
        $t = (($x1 - $x3) * ($y3 - $y4) - ($y1 - $y3) * ($x3 - $x4)) / $denom;
        return [$x1 + $t * ($x2 - $x1), $y1 + $t * ($y2 - $y1)];
    }

    private static function pointInTriangle(array $p, array $a, array $b, array $c): bool
    {
        $d1 = self::cross($a, $b, $p);
        $d2 = self::cross($b, $c, $p);
        $d3 = self::cross($c, $a, $p);
        $hasNeg = $d1 < 0 || $d2 < 0 || $d3 < 0;
        $hasPos = $d1 > 0 || $d2 > 0 || $d3 > 0;
        return !($hasNeg && $hasPos);
    }

    // Cross product of (b - a) x (p - a): positive when p is left of a->b.
    private static function cross(array $a, array $b, array $p): float
    {
        return ($b[0] - $a[0]) * ($p[1] - $a[1]) - ($b[1] - $a[1]) * ($p[0] - $a[0]);
    }

    private static function signedArea(array $polygon): float
    {
        $area = 0.0;
        $n = count($polygon);
        for ($i = 0; $i < $n; $i++) {
            [$x1, $y1] = $polygon[$i];
            [$x2, $y2] = $polygon[($i + 1) % $n];
            $area += $x1 * $y2 - $x2 * $y1;
        }
        return $area / 2;
    }

    private static function polygonArea(array $polygon): float
    {
        if (count($polygon) < 3) {
            return 0.0;
        }
        return abs(self::signedArea($polygon));
    }
}
