<?php

declare(strict_types=1);

namespace VuuroScan\Adapters;

/**
 * Converts a RoomPlan-shaped capture payload (CapturedRoom-style JSON: a
 * `floors` array of surfaces with `polygonCorners`) into the vendor-neutral
 * FloorPlan contract (contracts/floorplan.schema.json). This is the only
 * place in the Scan Service allowed to know that "polygonCorners" and
 * "floors" are RoomPlan vocabulary — everything downstream of adapt() only
 * ever sees the FloorPlan contract.
 *
 * Named "Simulator" because no physical LiDAR device is available for this
 * window (see CLAUDE.md); the payload shape is the same either way, so a
 * real RoomPlan/RoomPlan-simulator export slots into the same adapter
 * without a rewrite once one is reachable.
 */
final class RoomPlanSimulatorAdapter
{
    public function adapt(array $rawCapture, array $identity): array
    {
        if (empty($rawCapture['floors']) || !is_array($rawCapture['floors'])) {
            throw new \InvalidArgumentException('RoomPlan capture has no floors[] — cannot derive a room.');
        }

        $rooms = [];
        foreach ($rawCapture['floors'] as $index => $floor) {
            $corners = $floor['polygonCorners'] ?? null;
            if (!is_array($corners) || count($corners) < 3) {
                throw new \InvalidArgumentException("floors[$index] has fewer than 3 polygonCorners — not a closed room outline.");
            }

            // RoomPlan's world space is y-up; a floor outline lies in the x,z plane.
            $points2d = array_map(static fn (array $p) => [(float) $p[0], (float) $p[2]], $corners);

            $area = self::polygonArea($points2d);
            $perimeter = self::polygonPerimeter($points2d);
            [$width, $length] = self::boundingDimensions($points2d);

            $rooms[] = [
                'room_id' => (string) ($floor['identifier'] ?? ('floor-' . $index)),
                'label' => 'Room ' . ($index + 1),
                'floor_area_m2' => round($area, 2),
                'perimeter_m' => round($perimeter, 2),
                'bounding_dimensions_m' => [
                    'width_m' => round($width, 2),
                    'length_m' => round($length, 2),
                ],
                'confidence' => self::mapConfidence($floor['confidence'] ?? null),
            ];
        }

        return [
            'scan_session_id' => $identity['scan_session_id'],
            'property_id' => $identity['property_id'],
            'unit_id' => $identity['unit_id'],
            'organisation_id' => $identity['organisation_id'],
            'capture_provider' => $identity['capture_provider'] ?? 'roomplan_simulator_fixture',
            'captured_at' => $identity['captured_at'] ?? gmdate('c'),
            // Hard constraint #2: an automated adapter may never claim certified_survey.
            'measurement_basis' => 'indicative_nen2580_inspired',
            'purpose' => $identity['purpose'],
            'rooms' => $rooms,
            'photos' => [],
            'notes' => [],
        ];
    }

    /** @param array<int, array{0: float, 1: float}> $points */
    private static function polygonArea(array $points): float
    {
        $n = count($points);
        $sum = 0.0;
        for ($i = 0; $i < $n; $i++) {
            [$x1, $y1] = $points[$i];
            [$x2, $y2] = $points[($i + 1) % $n];
            $sum += ($x1 * $y2) - ($x2 * $y1);
        }
        return abs($sum) / 2.0;
    }

    /** @param array<int, array{0: float, 1: float}> $points */
    private static function polygonPerimeter(array $points): float
    {
        $n = count($points);
        $sum = 0.0;
        for ($i = 0; $i < $n; $i++) {
            [$x1, $y1] = $points[$i];
            [$x2, $y2] = $points[($i + 1) % $n];
            $sum += sqrt((($x2 - $x1) ** 2) + (($y2 - $y1) ** 2));
        }
        return $sum;
    }

    /**
     * @param array<int, array{0: float, 1: float}> $points
     * @return array{0: float, 1: float}
     */
    private static function boundingDimensions(array $points): array
    {
        $xs = array_column($points, 0);
        $ys = array_column($points, 1);
        return [max($xs) - min($xs), max($ys) - min($ys)];
    }

    private static function mapConfidence(?string $raw): string
    {
        return match ($raw) {
            'high' => 'high',
            'medium' => 'medium',
            'low' => 'low',
            default => 'low',
        };
    }
}
