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
    // Sanity bounds on an untrusted raw_capture body. Generous for any real
    // room/building, not tuned to RoomPlan's actual range (which isn't
    // verified on this machine — see docs/adr/0001).
    private const MAX_FLOORS = 50;
    private const MAX_SURFACES_PER_GROUP = 500;
    private const MAX_POLYGON_POINTS = 1000;
    private const MAX_COORDINATE_METERS = 1000.0;

    // Rejects degenerate geometry (collinear points, a self-intersecting
    // outline whose shoelace sum cancels out) that would otherwise present
    // as a real, usable room. 0.25 m2 (50cm x 50cm) is below any real
    // habitable space, so legitimate small rooms (closets, etc) still pass.
    //
    // Known accepted limitation: a self-intersecting ("bowtie") outline
    // whose shoelace area does NOT cancel to ~0 still passes this check with
    // a wrong-but-plausible-looking area. Solving that needs a
    // simple-polygon (non-self-intersecting) check — separate, larger work.
    private const MIN_POLYGON_AREA_M2 = 0.25;

    /**
     * @param int $roomIndexOffset How many rooms already exist in this scan
     *     session before this capture call. A multi-room session is built
     *     from multiple sequential single-room RoomPlan captures, not one
     *     payload with every room in it — the offset is what makes room
     *     numbering continue ("Room 2", "Room 3", ...) across calls instead
     *     of every call restarting at "Room 1". Also folded into room_id so
     *     two capture calls reusing the same underlying RoomPlan floor
     *     identifier (as the bundled fixtures deliberately do) can never
     *     collide within one session.
     */
    public function adapt(array $rawCapture, array $identity, int $roomIndexOffset = 0): array
    {
        if (empty($rawCapture['floors']) || !is_array($rawCapture['floors'])) {
            throw new \InvalidArgumentException('RoomPlan capture has no floors[] — cannot derive a room.');
        }

        self::validateRawCapture($rawCapture);

        // Aggregated across every surface RoomPlan reported for this capture
        // — floor, walls, doors, windows, openings — not just the floor's
        // own confidence field. A room can have a confidently-detected floor
        // outline while its walls were scanned too fast/too dark to trust.
        $coverage = self::computeCoverage($rawCapture);

        $rooms = [];
        foreach ($rawCapture['floors'] as $index => $floor) {
            $corners = $floor['polygonCorners'] ?? null;
            if (!is_array($corners) || count($corners) < 3) {
                throw new \InvalidArgumentException("floors[$index] has fewer than 3 polygonCorners — not a closed room outline.");
            }

            if (isset($floor['identifier']) && !is_string($floor['identifier'])) {
                throw new \InvalidArgumentException("floors[$index].identifier must be a plain string.");
            }

            foreach ($corners as $cornerIndex => $corner) {
                if (!is_array($corner)) {
                    throw new \InvalidArgumentException("floors[$index].polygonCorners[$cornerIndex] is not a [x, y, z] point — each corner must be an array of coordinates.");
                }
            }

            // RoomPlan's world space is y-up; a floor outline lies in the x,z plane.
            $points2d = array_map(static fn (array $p) => [(float) ($p[0] ?? 0), (float) ($p[2] ?? 0)], $corners);

            $area = self::polygonArea($points2d);
            $perimeter = self::polygonPerimeter($points2d);
            [$width, $length] = self::boundingDimensions($points2d);

            if ($area < self::MIN_POLYGON_AREA_M2) {
                throw new \InvalidArgumentException(sprintf(
                    'floors[%d] resolves to a %.4f m2 outline — too small/degenerate (duplicate or collinear polygonCorners?) to be a real room capture.',
                    $index,
                    $area
                ));
            }

            $globalIndex = $roomIndexOffset + $index;
            $rooms[] = [
                'room_id' => sprintf('room-%02d-%s', $globalIndex + 1, (string) ($floor['identifier'] ?? ('floor-' . $index))),
                'label' => 'Room ' . ($globalIndex + 1),
                'floor_area_m2' => round($area, 2),
                'perimeter_m' => round($perimeter, 2),
                'bounding_dimensions_m' => [
                    'width_m' => round($width, 2),
                    'length_m' => round($length, 2),
                ],
                'confidence' => self::mapConfidence($floor['confidence'] ?? null),
                'outline_m' => self::roomLocalOutline($points2d),
                // Same coverage object on every room from this capture call
                // — accurate for the supported one-room-per-call flow.
                'coverage' => $coverage,
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

    /**
     * Room-local outline: the same polygon, translated so its bounding-box
     * minimum corner sits at (0,0). Deliberately NOT in a shared/world
     * coordinate frame — see docs/adr/0002-export-coordinate-frame.md.
     * Separate RoomPlan capture sessions (one per room, per how multi-room
     * sessions are built here) do not share ARKit world tracking, so there
     * is no honest absolute position to preserve across rooms. Consumers
     * (e.g. the PNG floor plan export) must treat each room's outline as
     * self-contained and never assume two rooms' outlines share an origin.
     *
     * @param array<int, array{0: float, 1: float}> $points
     * @return array<int, array{0: float, 1: float}>
     */
    private static function roomLocalOutline(array $points): array
    {
        $xs = array_column($points, 0);
        $ys = array_column($points, 1);
        $minX = min($xs);
        $minY = min($ys);

        return array_map(
            static fn (array $p) => [round($p[0] - $minX, 3), round($p[1] - $minY, 3)],
            $points
        );
    }

    /**
     * Rejects an untrusted raw_capture body that would otherwise crash
     * downstream (non-finite/oversized coordinates) or let one capture call
     * blow up memory/storage (absurd array counts). Runs before anything
     * else touches the payload, so a rejection here is always a clean 422,
     * never a fatal error surfacing later.
     */
    private static function validateRawCapture(array $rawCapture): void
    {
        $floors = $rawCapture['floors'];
        if (count($floors) > self::MAX_FLOORS) {
            throw new \InvalidArgumentException(sprintf(
                'floors[] has %d entries, exceeding the %d-per-capture-call sanity limit.',
                count($floors),
                self::MAX_FLOORS
            ));
        }

        foreach (['walls', 'doors', 'windows', 'openings'] as $group) {
            $items = $rawCapture[$group] ?? [];
            if (is_array($items) && count($items) > self::MAX_SURFACES_PER_GROUP) {
                throw new \InvalidArgumentException(sprintf(
                    '%s[] has %d entries, exceeding the %d-surface sanity limit.',
                    $group,
                    count($items),
                    self::MAX_SURFACES_PER_GROUP
                ));
            }
        }

        foreach ($floors as $index => $floor) {
            $corners = $floor['polygonCorners'] ?? null;
            if (!is_array($corners)) {
                continue; // adapt()'s own check reports this more specifically.
            }
            if (count($corners) > self::MAX_POLYGON_POINTS) {
                throw new \InvalidArgumentException(sprintf(
                    'floors[%d] has %d polygonCorners, exceeding the %d-point sanity limit.',
                    $index,
                    count($corners),
                    self::MAX_POLYGON_POINTS
                ));
            }
            foreach ($corners as $corner) {
                if (!is_array($corner)) {
                    continue;
                }
                foreach (array_slice($corner, 0, 3) as $value) {
                    if (!is_int($value) && !is_float($value)) {
                        continue;
                    }
                    $value = (float) $value;
                    if (!is_finite($value)) {
                        throw new \InvalidArgumentException(
                            "floors[$index].polygonCorners contains a non-finite coordinate (NaN/Infinity) — real capture geometry is always finite."
                        );
                    }
                    if (abs($value) > self::MAX_COORDINATE_METERS) {
                        throw new \InvalidArgumentException(sprintf(
                            'floors[%d].polygonCorners has a coordinate of %.0f, exceeding the %.0f-metre sanity bound.',
                            $index,
                            $value,
                            self::MAX_COORDINATE_METERS
                        ));
                    }
                }
            }
        }
    }

    // Unrecognized/malformed confidence falls through to 'low', same as an
    // omitted field.
    private static function mapConfidence(mixed $raw): string
    {
        return match ($raw) {
            'high' => 'high',
            'medium' => 'medium',
            'low' => 'low',
            default => 'low',
        };
    }

    /**
     * Coverage score: the mean of a per-surface confidence weight (high=100,
     * medium=60, low=20) across every floor/wall/door/window/opening in this
     * capture call. usable is a threshold call (>=70), not derived from any
     * RoomPlan-provided signal — RoomPlan doesn't hand us a single
     * "is this good enough" boolean, so this repo's own bar is documented
     * here rather than left implicit.
     */
    private static function computeCoverage(array $rawCapture): array
    {
        // Non-array groups degrade to "contributes zero surfaces," not a
        // crash — matches how a missing group is already treated.
        $surfaces = array_merge(
            $rawCapture['floors'] ?? [],
            is_array($rawCapture['walls'] ?? null) ? $rawCapture['walls'] : [],
            is_array($rawCapture['doors'] ?? null) ? $rawCapture['doors'] : [],
            is_array($rawCapture['windows'] ?? null) ? $rawCapture['windows'] : [],
            is_array($rawCapture['openings'] ?? null) ? $rawCapture['openings'] : []
        );

        $counts = ['high' => 0, 'medium' => 0, 'low' => 0];
        $weightSum = 0;
        foreach ($surfaces as $surface) {
            $confidence = self::mapConfidence($surface['confidence'] ?? null);
            $counts[$confidence]++;
            $weightSum += match ($confidence) {
                'high' => 100,
                'medium' => 60,
                'low' => 20,
            };
        }

        $surfaceCount = count($surfaces);
        $score = $surfaceCount > 0 ? (int) round($weightSum / $surfaceCount) : 0;
        $usable = $score >= 70;

        return [
            'score' => $score,
            'confidence_counts' => $counts,
            'usable' => $usable,
            'message' => $usable
                ? null
                : sprintf(
                    'Low scan confidence (%d/100) across %d surface(s) — consider rescanning this room before leaving the unit.',
                    $score,
                    $surfaceCount
                ),
        ];
    }
}
