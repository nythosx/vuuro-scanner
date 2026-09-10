<?php

declare(strict_types=1);

namespace VuuroScan\Adapters;

use VuuroScan\RoomType;

/**
 * Converts a RoomPlan-shaped capture payload (CapturedRoom-style JSON: a
 * `floors` array of surfaces with `polygonCorners`) into the vendor-neutral
 * FloorPlan contract (contracts/floorplan.schema.json). This is the only
 * place in the Scan Service allowed to know that "polygonCorners" and
 * "floors" are RoomPlan vocabulary — everything downstream of adapt() only
 * ever sees the FloorPlan contract.
 *
 * Named "Simulator" because no physical LiDAR device is available for this
 * window (see docs/adr/0001-scan-service-stack.md); the payload shape is
 * the same either way, so a real RoomPlan/RoomPlan-simulator export slots
 * into the same adapter without a rewrite once one is reachable.
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

            [$minX, $minZ] = self::minXZ($points2d);

            // LIDAR-10: height/volume are indicative only (hard constraint
            // #2 — never certified), derived from captured wall dimensions.
            // Null (not 0) when no wall height was reported, same honesty
            // pattern as measurement_basis never defaulting to certified.
            $height = self::computeHeight($rawCapture);
            $volume = $height !== null ? round($area * $height, 2) : null;

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
                // LIDAR-10: same room-local frame as outline_m (docs/adr/0002)
                // — same coverage/openings/height/objects on every room from
                // this capture call, accurate for the one-room-per-call flow
                // computeCoverage() already assumes.
                'coverage' => $coverage,
                'openings' => self::mapOpenings($rawCapture, $minX, $minZ),
                'height_m' => $height,
                'volume_m3_indicative' => $volume,
                'objects' => self::mapObjects($rawCapture, $minX, $minZ),
                // LIDAR-5/11: additive, null unless this capture came from a
                // StructureBuilder-merged multi-room visit (docs/proposals/multi-room-fusion.md).
                'structure_origin_m' => self::structureOriginM($rawCapture),
                'room_type' => self::mapRoomType($rawCapture),
                'walk_path_m' => self::mapWalkPath($rawCapture, $minX, $minZ),
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
            'capture_location' => self::normalizeCaptureLocation($identity['capture_location'] ?? null),
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
        [$minX, $minZ] = self::minXZ($points);

        return array_map(
            static fn (array $p) => [round($p[0] - $minX, 3), round($p[1] - $minZ, 3)],
            $points
        );
    }

    /**
     * The room-local translation shared by roomLocalOutline() and every
     * LIDAR-10 opening/object position — all of them must land in the exact
     * same room-local frame outline_m already uses (docs/adr/0002), so this
     * is computed once per room and passed down rather than re-derived.
     *
     * @param array<int, array{0: float, 1: float}> $points
     * @return array{0: float, 1: float}
     */
    private static function minXZ(array $points): array
    {
        return [min(array_column($points, 0)), min(array_column($points, 1))];
    }

    /**
     * LIDAR-10: doors/windows/openings this capture call reported, with
     * positions — the card's "positions, not only coverage" requirement.
     * Position is the room-local centroid of the item's own polygonCorners
     * (world-space per CapturedRoomExporter.swift's worldPolygonCorners()),
     * translated into outline_m's frame the same way the floor outline is.
     * An item with no polygonCorners (older client, or RoomPlan genuinely
     * reported none) is dropped rather than given a fabricated (0,0) —
     * this is also what makes the "door present in capture but missing from
     * the contract" failure mode real and independently checkable.
     *
     * @return array<int, array{opening_id: string, category: string, position_m: array{0: float, 1: float}, confidence: string}>
     */
    private static function mapOpenings(array $rawCapture, float $minX, float $minZ): array
    {
        $openings = [];
        foreach (['doors' => 'door', 'windows' => 'window', 'openings' => 'opening'] as $group => $category) {
            $items = $rawCapture[$group] ?? [];
            if (!is_array($items)) {
                continue;
            }
            foreach ($items as $item) {
                if (!is_array($item)) {
                    continue;
                }
                $corners = $item['polygonCorners'] ?? null;
                if (!is_array($corners) || empty($corners)) {
                    continue;
                }
                $points2d = [];
                foreach ($corners as $corner) {
                    if (is_array($corner)) {
                        $points2d[] = [(float) ($corner[0] ?? 0), (float) ($corner[2] ?? 0)];
                    }
                }
                if (empty($points2d)) {
                    continue;
                }
                $centroidX = array_sum(array_column($points2d, 0)) / count($points2d);
                $centroidZ = array_sum(array_column($points2d, 1)) / count($points2d);
                $openings[] = [
                    'opening_id' => (string) ($item['identifier'] ?? ($category . '-' . count($openings))),
                    'category' => $category,
                    'position_m' => [round($centroidX - $minX, 3), round($centroidZ - $minZ, 3)],
                    'confidence' => self::mapConfidence($item['confidence'] ?? null),
                ];
            }
        }
        return $openings;
    }

    private static function mapWalkPath(array $rawCapture, float $minX, float $minZ): array
    {
        $walkPath = $rawCapture['walk_path'] ?? [];
        if (!is_array($walkPath)) {
            return [];
        }
        $points = [];
        foreach ($walkPath as $point) {
            if (!is_array($point) || !isset($point[0], $point[2])) {
                continue;
            }
            if (!is_numeric($point[0]) || !is_numeric($point[2])) {
                continue;
            }
            $points[] = [round((float) $point[0] - $minX, 3), round((float) $point[2] - $minZ, 3)];
        }
        return $points;
    }

    /**
     * LIDAR-10: tallest wall segment reported for this capture call is the
     * honest ceiling-height proxy — a partially-tracked short wall segment
     * should not pull the room's reported height down. Null (never 0) when
     * no wall carried a numeric height, so the contract can tell "no data"
     * apart from "a room with zero height."
     */
    private static function computeHeight(array $rawCapture): ?float
    {
        $walls = $rawCapture['walls'] ?? [];
        if (!is_array($walls)) {
            return null;
        }
        $heights = [];
        foreach ($walls as $wall) {
            if (!is_array($wall)) {
                continue;
            }
            $dims = $wall['dimensions'] ?? null;
            if (!is_array($dims) || !isset($dims[1]) || (!is_int($dims[1]) && !is_float($dims[1]))) {
                continue;
            }
            $height = (float) $dims[1];
            if (is_finite($height) && $height > 0) {
                $heights[] = $height;
            }
        }
        return empty($heights) ? null : max($heights);
    }

    /**
     * LIDAR-10: real captured furniture/fixtures for this room, empty only
     * when the capture reported none — never invented. category is passed
     * through as RoomPlan/the exporter reported it, same as door/window
     * categories already are; the adapter never invents a category.
     *
     * @return array<int, array{object_id: string, category: string, position_m: array{0: float, 1: float}, dimensions_m: array{0: float, 1: float, 2: float}, confidence: string}>
     */
    private static function mapObjects(array $rawCapture, float $minX, float $minZ): array
    {
        $items = $rawCapture['objects'] ?? [];
        if (!is_array($items)) {
            return [];
        }
        $objects = [];
        foreach ($items as $item) {
            if (!is_array($item)) {
                continue;
            }
            $position = $item['position'] ?? null;
            if (!is_array($position) || count($position) < 3) {
                continue;
            }
            $dims = $item['dimensions'] ?? null;
            if (!is_array($dims) || count($dims) < 3) {
                // Same drop-not-fabricate rule as position above: a
                // missing/truncated dimensions array is unknown size, not a
                // real 0x0x0 object. Review finding — this used to fall back
                // to [0.0, 0.0, 0.0], fabricating a size the capture never
                // reported.
                continue;
            }
            $dimensions = [(float) $dims[0], (float) $dims[1], (float) $dims[2]];
            $objects[] = [
                'object_id' => (string) ($item['identifier'] ?? ('object-' . count($objects))),
                'category' => is_string($item['category'] ?? null) ? $item['category'] : 'object',
                'position_m' => [round(((float) ($position[0] ?? 0)) - $minX, 3), round(((float) ($position[2] ?? 0)) - $minZ, 3)],
                'dimensions_m' => $dimensions,
                'confidence' => self::mapConfidence($item['confidence'] ?? null),
            ];
        }
        return $objects;
    }

    // Already validated by public/index.php — passed through as-is, honest null when absent.
    private static function normalizeCaptureLocation(?array $loc): ?array
    {
        if ($loc === null) {
            return null;
        }
        return [
            'lat' => (float) $loc['lat'],
            'lon' => (float) $loc['lon'],
            'accuracy_m' => (float) $loc['accuracy_m'],
            'captured_at' => isset($loc['captured_at']) ? (string) $loc['captured_at'] : null,
        ];
    }

    // LIDAR-5/11: passes structure_origin_m through as-is (already
    // validated numeric/finite in validateRawCapture) — null when absent.
    private static function structureOriginM(array $rawCapture): ?array
    {
        $origin = $rawCapture['structure_origin_m'] ?? null;
        if (!is_array($origin) || count($origin) < 2) {
            return null;
        }
        return [(float) $origin[0], (float) $origin[1]];
    }

    private static function mapRoomType(array $rawCapture): ?array
    {
        $roomType = $rawCapture['room_type'] ?? null;
        if (!is_array($roomType)) {
            return null;
        }
        $guess = $roomType['guess'] ?? null;
        $guessSource = $roomType['guess_source'] ?? null;
        if (!is_string($guess) || !in_array($guess, RoomType::VALUES, true)
            || !is_string($guessSource) || !in_array($guessSource, RoomType::GUESS_SOURCES, true)) {
            return null;
        }
        $confirmed = $roomType['confirmed'] ?? null;
        if ($confirmed !== null) {
            $confirmed = is_string($confirmed) && RoomType::isValidConfirmedValue($confirmed) ? trim($confirmed) : null;
        }
        return [
            'guess' => $guess,
            'guess_source' => $guessSource,
            'confirmed' => $confirmed,
        ];
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

        // Capture-surface scan finding: adapt()'s room-building loop does
        // `$roomIndexOffset + $index` on floors[]'s own array key (to build
        // each room's global index/room_id) without ever checking that key
        // is actually an integer. is_array() is true for BOTH a JSON array
        // (`[...]`, decodes to sequential int keys) and a JSON object
        // (`{...}`, decodes to string keys) — so a client sending
        // `"floors": {"myFloor": {...}}` instead of `"floors": [...]` passed
        // every earlier check here and then crashed with an uncaught
        // TypeError ("Unsupported operand types: int + string") once
        // adapt() reached that arithmetic. Confirmed live before this fix.
        // That's a real fatal error surfacing later, exactly what this
        // function's own docblock promises never happens — and worse, a
        // TypeError isn't an InvalidArgumentException, so it skips the
        // capture route's catch block entirely (including the
        // idempotency-claim release fix), same as an uncaught exception
        // anywhere else on this path. array_is_list() (PHP 8.1+, matches
        // this repo's documented floor) rejects it here instead, as a clean
        // 422 like every other malformed-shape rejection in this file.
        if (!array_is_list($floors)) {
            throw new \InvalidArgumentException('floors[] must be a JSON array (e.g. [...]), not an object with named keys.');
        }

        // LIDAR-10 review finding (confirmed live, not theoretical): a
        // multi-floor capture call would previously be accepted silently —
        // area/perimeter/outline are computed correctly per floor, but
        // mapOpenings()/mapObjects()/computeHeight() read the WHOLE
        // rawCapture's doors/windows/openings/objects/walls, not anything
        // scoped to the floor they're being attached to (RoomPlan doesn't
        // tag a door/window/object with which floor/room it belongs to in
        // this payload shape, so real per-floor scoping isn't possible with
        // the data available). Confirmed: a 2-floor capture with one door
        // physically in floor A produced a second, phantom "door" entry in
        // floor B's openings[], translated into floor B's own room-local
        // frame — a plausible-looking but entirely wrong position, not a
        // missing-data gap.
        //
        // Only rejected when walls/doors/windows/openings/objects data is
        // actually present, not on floor count alone — net/verify_exports.php
        // legitimately submits a 40-floor, geometry-only capture (no walls/
        // openings/objects at all) to exercise PDF pagination and the PNG
        // canvas-size bound, and that has nothing ambiguous to misattribute:
        // area/perimeter/outline/height_m(null)/openings([])/objects([]) are
        // all correct per floor with no cross-floor data to duplicate. Same
        // "one room per capture call" assumption computeCoverage() already
        // documents for its own aggregation, now enforced here instead of
        // silently relied on. Revisit when LIDAR-4 (multi-room) defines a
        // real per-floor association for these groups.
        if (count($floors) > 1) {
            $hasAmbiguousData = isset($rawCapture['structure_origin_m']) || isset($rawCapture['room_type']);
            foreach (['walls', 'doors', 'windows', 'openings', 'objects'] as $group) {
                $items = $rawCapture[$group] ?? [];
                if (is_array($items) && !empty($items)) {
                    $hasAmbiguousData = true;
                    break;
                }
            }
            // Review finding: this message reaches an end user verbatim —
            // public/index.php's InvalidArgumentException catch wraps it as
            // "This capture couldn't be processed: <this> Please rescan this
            // room." and ios-app's ErrorCodeView renders that string as-is
            // (AppError.userMessage). No internal ticket reference or
            // payload-shape jargon belongs in it; that context lives in the
            // comment above, for a developer reading this file, not in the
            // string a landlord/agent sees on their phone.
            if ($hasAmbiguousData) {
                throw new \InvalidArgumentException(
                    'This capture reported more than one room along with wall, door, window, or furniture data — only one room per scan is supported when that data is present right now.'
                );
            }
        }

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
            self::validatePoints("floors[$index].polygonCorners", $corners);
        }

        // LIDAR-10: doors/windows/openings/objects corners and positions are
        // just as untrusted as floors[].polygonCorners — mapOpenings() and
        // mapObjects() would otherwise be the first place a non-numeric or
        // absurd coordinate is touched, well past the clean-422 boundary
        // this function exists to be.
        foreach (['doors', 'windows', 'openings'] as $group) {
            $items = $rawCapture[$group] ?? [];
            if (!is_array($items)) {
                continue;
            }
            foreach ($items as $itemIndex => $item) {
                if (!is_array($item)) {
                    continue;
                }
                $corners = $item['polygonCorners'] ?? null;
                if (!is_array($corners)) {
                    continue; // no position reported; mapOpenings() drops it rather than fabricating one.
                }
                if (count($corners) > self::MAX_POLYGON_POINTS) {
                    throw new \InvalidArgumentException(sprintf(
                        '%s[%d].polygonCorners has %d entries, exceeding the %d-point sanity limit.',
                        $group,
                        $itemIndex,
                        count($corners),
                        self::MAX_POLYGON_POINTS
                    ));
                }
                self::validatePoints("$group\[$itemIndex].polygonCorners", $corners);
            }
        }

        $walkPath = $rawCapture['walk_path'] ?? null;
        if (is_array($walkPath)) {
            if (count($walkPath) > self::MAX_POLYGON_POINTS) {
                throw new \InvalidArgumentException(sprintf(
                    'walk_path[] has %d entries, exceeding the %d-point sanity limit.',
                    count($walkPath),
                    self::MAX_POLYGON_POINTS
                ));
            }
            self::validatePoints('walk_path', $walkPath);
        }

        $objects = $rawCapture['objects'] ?? [];
        if (is_array($objects)) {
            if (count($objects) > self::MAX_SURFACES_PER_GROUP) {
                throw new \InvalidArgumentException(sprintf(
                    'objects[] has %d entries, exceeding the %d-surface sanity limit.',
                    count($objects),
                    self::MAX_SURFACES_PER_GROUP
                ));
            }
            foreach ($objects as $objectIndex => $object) {
                if (!is_array($object)) {
                    continue;
                }
                $position = $object['position'] ?? null;
                if (is_array($position)) {
                    self::validatePoints("objects[$objectIndex].position", [$position]);
                } // else: no position reported; mapObjects() drops it rather than fabricating one.

                // Review finding: dimensions_m was reaching mapObjects()'s
                // `(float) ($dims[n] ?? 0)` cast with no numeric/finite/bounds
                // check at all — the same silent-corruption/absurd-value
                // shape validatePoints() already exists to close off for
                // every other coordinate in this file, just missed here.
                $dimensions = $object['dimensions'] ?? null;
                if (is_array($dimensions)) {
                    self::validatePoints("objects[$objectIndex].dimensions", [$dimensions]);
                }
            }
        }

        // LIDAR-5/11: structure_origin_m is just as untrusted as any other
        // client-supplied coordinate.
        $structureOrigin = $rawCapture['structure_origin_m'] ?? null;
        if (is_array($structureOrigin)) {
            self::validatePoints('structure_origin_m', [$structureOrigin]);
        }

        // computeHeight() reads walls[].dimensions[1] with no prior bounds
        // check — same gap as objects[].dimensions above, just on the field
        // that now feeds height_m/volume_m3_indicative.
        $walls = $rawCapture['walls'] ?? [];
        if (is_array($walls)) {
            foreach ($walls as $wallIndex => $wall) {
                if (!is_array($wall)) {
                    continue;
                }
                $dimensions = $wall['dimensions'] ?? null;
                if (is_array($dimensions)) {
                    self::validatePoints("walls[$wallIndex].dimensions", [$dimensions]);
                }
            }
        }
    }

    /**
     * Shared numeric/finite/bounds validation for any [x, y, z]-shaped point
     * list — floor polygonCorners originally, now also door/window/opening
     * polygonCorners and object positions (LIDAR-10). Same three rejections
     * every caller needs: non-numeric, non-finite, and absurdly large.
     *
     * @param array<int, mixed> $points
     */
    private static function validatePoints(string $label, array $points): void
    {
        foreach ($points as $point) {
            if (!is_array($point)) {
                continue;
            }
            foreach (array_slice($point, 0, 3) as $value) {
                if ($value === null) {
                    // An absent dimension — adapt()'s mapping falls back to
                    // 0 via `?? 0` for this, same as a shorter-than-3 point.
                    continue;
                }
                if (!is_int($value) && !is_float($value)) {
                    // Anything else (string, bool, array, ...) used to fall
                    // through this check unrejected, then get silently
                    // coerced to 0/1 by a `(float) $p[n]` cast — same
                    // silent-corruption shape as the capture_provider/
                    // identifier bugs fixed earlier, just on a coordinate
                    // instead of a string field. A non-numeric coordinate is
                    // never a real capture.
                    throw new \InvalidArgumentException(sprintf(
                        '%s contains a non-numeric coordinate (%s) — real capture geometry is always numeric.',
                        $label,
                        get_debug_type($value)
                    ));
                }
                $value = (float) $value;
                if (!is_finite($value)) {
                    throw new \InvalidArgumentException(
                        "$label contains a non-finite coordinate (NaN/Infinity) — real capture geometry is always finite."
                    );
                }
                if (abs($value) > self::MAX_COORDINATE_METERS) {
                    throw new \InvalidArgumentException(sprintf(
                        '%s has a coordinate of %.0f, exceeding the %.0f-metre sanity bound.',
                        $label,
                        $value,
                        self::MAX_COORDINATE_METERS
                    ));
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
