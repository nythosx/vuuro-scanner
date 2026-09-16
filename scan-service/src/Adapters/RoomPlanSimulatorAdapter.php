<?php

declare(strict_types=1);

namespace VuuroScan\Adapters;

use VuuroScan\RoomType;

final class RoomPlanSimulatorAdapter
{
    private const MAX_FLOORS = 50;
    private const MAX_SURFACES_PER_GROUP = 500;
    private const MAX_POLYGON_POINTS = 1000;
    private const MAX_COORDINATE_METERS = 1000.0;

    private const MIN_POLYGON_AREA_M2 = 0.25;

    public function adapt(array $rawCapture, array $identity, int $roomIndexOffset = 0): array
    {
        if (empty($rawCapture['floors']) || !is_array($rawCapture['floors'])) {
            throw new \InvalidArgumentException('RoomPlan capture has no floors[] — cannot derive a room.');
        }

        self::validateRawCapture($rawCapture);

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
                'coverage' => $coverage,
                'openings' => self::mapOpenings($rawCapture, $minX, $minZ),
                'height_m' => $height,
                'volume_m3_indicative' => $volume,
                'objects' => self::mapObjects($rawCapture, $minX, $minZ),
                'structure_origin_m' => self::structureOriginM($rawCapture),
                'heading_deg' => self::headingDeg($rawCapture),
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
     * @param array<int, array{0: float, 1: float}> $points
     * @return array{0: float, 1: float}
     */
    private static function minXZ(array $points): array
    {
        return [min(array_column($points, 0)), min(array_column($points, 1))];
    }

    /**
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

    private static function structureOriginM(array $rawCapture): ?array
    {
        $origin = $rawCapture['structure_origin_m'] ?? null;
        if (!is_array($origin) || count($origin) < 2) {
            return null;
        }
        return [(float) $origin[0], (float) $origin[1]];
    }

    private static function headingDeg(array $rawCapture): ?float
    {
        $heading = $rawCapture['heading_deg'] ?? null;
        if (!is_int($heading) && !is_float($heading)) {
            return null;
        }
        return (float) $heading;
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

    private static function validateRawCapture(array $rawCapture): void
    {
        $floors = $rawCapture['floors'];

        if (!array_is_list($floors)) {
            throw new \InvalidArgumentException('floors[] must be a JSON array (e.g. [...]), not an object with named keys.');
        }

        if (count($floors) > 1) {
            $hasAmbiguousData = isset($rawCapture['structure_origin_m']) || isset($rawCapture['room_type']);
            foreach (['walls', 'doors', 'windows', 'openings', 'objects'] as $group) {
                $items = $rawCapture[$group] ?? [];
                if (is_array($items) && !empty($items)) {
                    $hasAmbiguousData = true;
                    break;
                }
            }
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
                continue;
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
                    continue;
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
                }

                $dimensions = $object['dimensions'] ?? null;
                if (is_array($dimensions)) {
                    self::validatePoints("objects[$objectIndex].dimensions", [$dimensions]);
                }
            }
        }

        $structureOrigin = $rawCapture['structure_origin_m'] ?? null;
        if (is_array($structureOrigin)) {
            self::validatePoints('structure_origin_m', [$structureOrigin]);
        }

        $heading = $rawCapture['heading_deg'] ?? null;
        if ($heading !== null) {
            if (!is_int($heading) && !is_float($heading)) {
                throw new \InvalidArgumentException('heading_deg must be a number or null, not ' . get_debug_type($heading) . '.');
            }
            if (!is_finite((float) $heading)) {
                throw new \InvalidArgumentException('heading_deg must be a finite number, not NaN/Infinity.');
            }
            if ($heading < 0 || $heading >= 360) {
                throw new \InvalidArgumentException("heading_deg must be within [0, 360), got {$heading}.");
            }
        }

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
                    continue;
                }
                if (!is_int($value) && !is_float($value)) {
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

    private static function mapConfidence(mixed $raw): string
    {
        return match ($raw) {
            'high' => 'high',
            'medium' => 'medium',
            'low' => 'low',
            default => 'low',
        };
    }

    private static function computeCoverage(array $rawCapture): array
    {
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