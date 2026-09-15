<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class RoomFusionSolver
{
    private const SEAM_MIN_GAP_M = 0.01;
    private const SEAM_MAX_GAP_M = 0.5;
    private const SEAM_MIN_OVERLAP_M = 0.5;
    private const SEAM_PARALLEL_TOLERANCE = 0.3;
    private const SEAM_OFFSET_CONSISTENCY_M = 0.6;
    private const SEAM_WEIGHT_CAP_M = 2.0;
    private const REGULARIZATION = 1e-6;
    private const GAUSS_NEWTON_ITERATIONS = 4;

    public static function solve(array $rooms): array
    {
        $overlapping = FusionOverlapDetector::detect($rooms);
        $overlapSet = array_flip($overlapping);

        $poses = [];
        $edgeTiers = [];
        foreach ($rooms as $i => $room) {
            [$originX, $originZ] = $room['structure_origin_m'];
            $poses[$i] = ['originX' => $originX, 'originZ' => $originZ, 'rotationRad' => 0.0];
            $edgeTiers[$i] = [];
        }

        $eligible = array_values(array_filter(array_keys($rooms), static fn (int $i) => !isset($overlapSet[$i])));
        if (count($eligible) < 2) {
            return ['overlapping' => $overlapping, 'poses' => $poses, 'edgeTiers' => $edgeTiers];
        }

        $seams = self::findSeamConstraints($rooms, $overlapping);
        $constraints = $seams['constraints'];
        foreach ($seams['interiorEdges'] as $roomIndex => $edgeIndices) {
            foreach ($edgeIndices as $edgeIndex => $_) {
                $edgeTiers[$roomIndex][$edgeIndex] = true;
            }
        }
        if ($constraints === []) {
            return ['overlapping' => $overlapping, 'poses' => $poses, 'edgeTiers' => $edgeTiers];
        }

        $anchor = self::pickAnchor($rooms, $eligible);

        $varIndex = [];
        $n = 0;
        foreach ($eligible as $i) {
            if ($i === $anchor) {
                continue;
            }
            $varIndex[$i] = $n;
            $n += 3;
        }

        $theta = array_fill(0, count($rooms), 0.0);
        $tx = array_fill(0, count($rooms), 0.0);
        $tz = array_fill(0, count($rooms), 0.0);

        for ($iter = 0; $iter < self::GAUSS_NEWTON_ITERATIONS; $iter++) {
            $ata = array_fill(0, $n, null);
            for ($r = 0; $r < $n; $r++) {
                $ata[$r] = array_fill(0, $n, 0.0);
            }
            $atb = array_fill(0, $n, 0.0);

            foreach ($constraints as $constraint) {
                [$roomA, $roomB, $rawPoints, $weight] = $constraint;
                foreach ($rawPoints as [$pAx, $pAz, $pBx, $pBz]) {
                    self::accumulateResidual(
                        $ata,
                        $atb,
                        $varIndex,
                        $roomA,
                        $roomB,
                        $pAx,
                        $pAz,
                        $pBx,
                        $pBz,
                        $rooms[$roomA]['structure_origin_m'],
                        $rooms[$roomB]['structure_origin_m'],
                        $theta,
                        $tx,
                        $tz,
                        $weight
                    );
                }
            }

            for ($r = 0; $r < $n; $r++) {
                $ata[$r][$r] += self::REGULARIZATION;
            }

            $delta = self::solveLinearSystem($ata, $atb);
            if ($delta === null) {
                break;
            }

            foreach ($varIndex as $roomIdx => $offset) {
                $theta[$roomIdx] += $delta[$offset];
                $tx[$roomIdx] += $delta[$offset + 1];
                $tz[$roomIdx] += $delta[$offset + 2];
            }
        }

        foreach ($eligible as $i) {
            [$originX, $originZ] = $rooms[$i]['structure_origin_m'];
            $poses[$i] = [
                'originX' => $originX + $tx[$i],
                'originZ' => $originZ + $tz[$i],
                'rotationRad' => $theta[$i],
            ];
        }

        return ['overlapping' => $overlapping, 'poses' => $poses, 'edgeTiers' => $edgeTiers];
    }

    public static function transformPoint(array $pose, float $mx, float $mz): array
    {
        $cos = cos($pose['rotationRad']);
        $sin = sin($pose['rotationRad']);
        return [
            $mx * $cos - $mz * $sin + $pose['originX'],
            $mx * $sin + $mz * $cos + $pose['originZ'],
        ];
    }

    private static function accumulateResidual(
        array &$ata,
        array &$atb,
        array $varIndex,
        int $roomA,
        int $roomB,
        float $pAx,
        float $pAz,
        float $pBx,
        float $pBz,
        array $originA,
        array $originB,
        array $theta,
        array $tx,
        array $tz,
        float $weight
    ): void {
        $localAx = $pAx - $originA[0];
        $localAz = $pAz - $originA[1];
        $localBx = $pBx - $originB[0];
        $localBz = $pBz - $originB[1];

        [$curAx, $curAz] = self::applyPose($localAx, $localAz, $originA, $theta[$roomA], $tx[$roomA], $tz[$roomA]);
        [$curBx, $curBz] = self::applyPose($localBx, $localBz, $originB, $theta[$roomB], $tx[$roomB], $tz[$roomB]);

        $residualX = $curBx - $curAx;
        $residualZ = $curBz - $curAz;

        $cosA = cos($theta[$roomA]);
        $sinA = sin($theta[$roomA]);
        $cosB = cos($theta[$roomB]);
        $sinB = sin($theta[$roomB]);

        $dAx_dThetaA = -$localAx * $sinA - $localAz * $cosA;
        $dAz_dThetaA = $localAx * $cosA - $localAz * $sinA;
        $dBx_dThetaB = -$localBx * $sinB - $localBz * $cosB;
        $dBz_dThetaB = $localBx * $cosB - $localBz * $sinB;

        $rows = [
            'x' => [
                'residual' => $residualX,
                'A' => ['theta' => -$dAx_dThetaA, 'tx' => -1.0, 'tz' => 0.0],
                'B' => ['theta' => $dBx_dThetaB, 'tx' => 1.0, 'tz' => 0.0],
            ],
            'z' => [
                'residual' => $residualZ,
                'A' => ['theta' => -$dAz_dThetaA, 'tx' => 0.0, 'tz' => -1.0],
                'B' => ['theta' => $dBz_dThetaB, 'tx' => 0.0, 'tz' => 1.0],
            ],
        ];

        foreach ($rows as $row) {
            $jacobian = [];
            if (isset($varIndex[$roomA])) {
                $o = $varIndex[$roomA];
                $jacobian[$o] = $row['A']['theta'];
                $jacobian[$o + 1] = $row['A']['tx'];
                $jacobian[$o + 2] = $row['A']['tz'];
            }
            if (isset($varIndex[$roomB])) {
                $o = $varIndex[$roomB];
                $jacobian[$o] = ($jacobian[$o] ?? 0.0) + $row['B']['theta'];
                $jacobian[$o + 1] = ($jacobian[$o + 1] ?? 0.0) + $row['B']['tx'];
                $jacobian[$o + 2] = ($jacobian[$o + 2] ?? 0.0) + $row['B']['tz'];
            }
            if ($jacobian === []) {
                continue;
            }
            foreach ($jacobian as $ri => $vi) {
                $atb[$ri] += -$weight * $vi * $row['residual'];
                foreach ($jacobian as $rj => $vj) {
                    $ata[$ri][$rj] += $weight * $vi * $vj;
                }
            }
        }
    }

    private static function applyPose(float $localX, float $localZ, array $origin, float $theta, float $dx, float $dz): array
    {
        $cos = cos($theta);
        $sin = sin($theta);
        return [
            $localX * $cos - $localZ * $sin + $origin[0] + $dx,
            $localX * $sin + $localZ * $cos + $origin[1] + $dz,
        ];
    }

    private static function pickAnchor(array $rooms, array $eligible): int
    {
        $best = $eligible[array_key_first($eligible)];
        $bestArea = -INF;
        foreach ($eligible as $i) {
            $area = (float) ($rooms[$i]['floor_area_m2'] ?? 0.0);
            if ($area > $bestArea) {
                $bestArea = $area;
                $best = $i;
            }
        }
        return $best;
    }

    private static function findSeamConstraints(array $rooms, array $overlapping): array
    {
        $overlapSet = array_flip($overlapping);
        $outlines = [];
        foreach ($rooms as $i => $room) {
            if (isset($overlapSet[$i])) {
                continue;
            }
            [$originX, $originZ] = $room['structure_origin_m'];
            $outline = [];
            foreach ($room['outline_m'] as [$mx, $mz]) {
                $outline[] = [$mx + $originX, $mz + $originZ];
            }
            $outlines[$i] = $outline;
        }

        $edges = [];
        foreach ($outlines as $roomIndex => $outline) {
            $n = count($outline);
            for ($k = 0; $k < $n; $k++) {
                [$ax, $az] = $outline[$k];
                [$bx, $bz] = $outline[($k + 1) % $n];
                $edges[] = [$roomIndex, $k, $ax, $az, $bx, $bz];
            }
        }

        $constraints = [];
        $interiorEdges = [];
        $count = count($edges);
        for ($i = 0; $i < $count; $i++) {
            [$roomA, $edgeA, $a1x, $a1z, $a2x, $a2z] = $edges[$i];
            $dax = $a2x - $a1x;
            $daz = $a2z - $a1z;
            $lenA = sqrt($dax ** 2 + $daz ** 2);
            if ($lenA < 1e-6) {
                continue;
            }
            $ux = $dax / $lenA;
            $uz = $daz / $lenA;
            $nx = -$uz;
            $nz = $ux;

            for ($j = $i + 1; $j < $count; $j++) {
                [$roomB, $edgeB, $b1x, $b1z, $b2x, $b2z] = $edges[$j];
                if ($roomB === $roomA) {
                    continue;
                }
                $dbx = $b2x - $b1x;
                $dbz = $b2z - $b1z;
                $lenB = sqrt($dbx ** 2 + $dbz ** 2);
                if ($lenB < 1e-6) {
                    continue;
                }
                $vx = $dbx / $lenB;
                $vz = $dbz / $lenB;
                $cross = $ux * $vz - $uz * $vx;
                if (abs($cross) > self::SEAM_PARALLEL_TOLERANCE) {
                    continue;
                }

                $distB1 = ($b1x - $a1x) * $nx + ($b1z - $a1z) * $nz;
                $distB2 = ($b2x - $a1x) * $nx + ($b2z - $a1z) * $nz;
                if (abs($distB1 - $distB2) > self::SEAM_OFFSET_CONSISTENCY_M) {
                    continue;
                }
                $gap = ($distB1 + $distB2) / 2;
                if (abs($gap) < self::SEAM_MIN_GAP_M || abs($gap) > self::SEAM_MAX_GAP_M) {
                    continue;
                }

                $tB1 = ($b1x - $a1x) * $ux + ($b1z - $a1z) * $uz;
                $tB2 = ($b2x - $a1x) * $ux + ($b2z - $a1z) * $uz;
                $tLo = max(0.0, min($tB1, $tB2));
                $tHi = min($lenA, max($tB1, $tB2));
                $overlapLen = $tHi - $tLo;
                if ($overlapLen < self::SEAM_MIN_OVERLAP_M) {
                    continue;
                }

                $pA1x = $a1x + $tLo * $ux;
                $pA1z = $a1z + $tLo * $uz;
                $pA2x = $a1x + $tHi * $ux;
                $pA2z = $a1z + $tHi * $uz;

                $pB1x = $b1x + (($pA1x - $b1x) * $vx + ($pA1z - $b1z) * $vz) * $vx;
                $pB1z = $b1z + (($pA1x - $b1x) * $vx + ($pA1z - $b1z) * $vz) * $vz;
                $pB2x = $b1x + (($pA2x - $b1x) * $vx + ($pA2z - $b1z) * $vz) * $vx;
                $pB2z = $b1z + (($pA2x - $b1x) * $vx + ($pA2z - $b1z) * $vz) * $vz;

                $weight = min($overlapLen, self::SEAM_WEIGHT_CAP_M);
                $constraints[] = [$roomA, $roomB, [[$pA1x, $pA1z, $pB1x, $pB1z], [$pA2x, $pA2z, $pB2x, $pB2z]], $weight];
                $interiorEdges[$roomA][$edgeA] = true;
                $interiorEdges[$roomB][$edgeB] = true;
            }
        }
        return ['constraints' => $constraints, 'interiorEdges' => $interiorEdges];
    }

    private static function solveLinearSystem(array $a, array $b): ?array
    {
        $n = count($b);
        if ($n === 0) {
            return [];
        }
        for ($col = 0; $col < $n; $col++) {
            $pivotRow = $col;
            $pivotVal = abs($a[$col][$col]);
            for ($row = $col + 1; $row < $n; $row++) {
                if (abs($a[$row][$col]) > $pivotVal) {
                    $pivotVal = abs($a[$row][$col]);
                    $pivotRow = $row;
                }
            }
            if ($pivotVal < 1e-12) {
                return null;
            }
            if ($pivotRow !== $col) {
                [$a[$col], $a[$pivotRow]] = [$a[$pivotRow], $a[$col]];
                [$b[$col], $b[$pivotRow]] = [$b[$pivotRow], $b[$col]];
            }
            for ($row = $col + 1; $row < $n; $row++) {
                $factor = $a[$row][$col] / $a[$col][$col];
                if ($factor === 0.0) {
                    continue;
                }
                for ($k = $col; $k < $n; $k++) {
                    $a[$row][$k] -= $factor * $a[$col][$k];
                }
                $b[$row] -= $factor * $b[$col];
            }
        }
        $x = array_fill(0, $n, 0.0);
        for ($row = $n - 1; $row >= 0; $row--) {
            $sum = $b[$row];
            for ($k = $row + 1; $k < $n; $k++) {
                $sum -= $a[$row][$k] * $x[$k];
            }
            $x[$row] = $sum / $a[$row][$row];
        }
        return $x;
    }
}
