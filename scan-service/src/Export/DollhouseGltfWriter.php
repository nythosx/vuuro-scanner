<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class DollhouseGltfWriter
{
    private const WALL_THICKNESS_M = 0.20;
    private const SEAM_OVERLAP_M = 0.015;
    private const FLOOR_STACK_GAP_M = 0.6;
    private const DEFAULT_HEIGHT_M = 2.4;
    private const FLOOR_COLOR = [0.90, 0.86, 0.78, 1.0];
    private const WALL_COLOR = [0.95, 0.94, 0.92, 1.0];
    private const OVERLAP_COLOR = [0.84, 0.27, 0.24, 1.0];
    private const MAX_OPENING_WALL_DISTANCE_M = 0.6;
    private const MAX_TRIANGLES = 150000;
    private const MAX_TEXTURE_EDGE_PX = 1600;
    private const DOOR_HEIGHT_M = 2.05;
    private const WINDOW_SILL_M = 0.9;
    private const WINDOW_HEIGHT_M = 1.2;
    private const OTHER_OPENING_HEIGHT_M = 1.0;
    private const FRAME_POST_M = 0.04;
    private const FRAME_EXTRA_DEPTH_M = 0.03;
    private const DOOR_COLOR = [1.0, 0.51, 0.07, 1.0];
    private const WINDOW_COLOR = [0.18, 0.76, 1.0, 1.0];
    private const OTHER_OPENING_COLOR = [0.55, 0.55, 0.56, 1.0];

    public function write(array $floorPlan, ?callable $photoLoader = null): string
    {
        if ($photoLoader === null) {
            return $this->writeFlat($floorPlan);
        }
        return $this->writeTextured($floorPlan, $photoLoader);
    }

    private function writeFlat(array $floorPlan): string
    {
        $rooms = $floorPlan['rooms'] ?? null;
        if (!is_array($rooms) || $rooms === []) {
            throw new \InvalidArgumentException('This session has no captured rooms to draw in 3D.');
        }
        $placements = self::placements($rooms);
        $positions = [];
        $normals = [];
        $colors = [];
        $indices = [];
        foreach ($rooms as $i => $room) {
            self::appendRoom($room, $placements[$i], $positions, $normals, $colors, $indices);
            if (intdiv(count($indices), 3) > self::MAX_TRIANGLES) {
                throw new \InvalidArgumentException(sprintf(
                    'This floor plan needs more than %d triangles to draw in 3D.',
                    self::MAX_TRIANGLES
                ));
            }
        }
        if ($positions === []) {
            throw new \InvalidArgumentException('The captured rooms produced no usable 3D geometry.');
        }
        return self::packGlb($positions, $normals, $colors, $indices);
    }

    private function writeTextured(array $floorPlan, callable $photoLoader): string
    {
        $rooms = $floorPlan['rooms'] ?? null;
        if (!is_array($rooms) || $rooms === []) {
            throw new \InvalidArgumentException('This session has no captured rooms to draw in 3D.');
        }
        $layout = self::fusedLayout($rooms);
        $rooms = $layout['rooms'];

        $photosByRoom = [];
        foreach ($floorPlan['photos_360'] ?? [] as $photo) {
            if (!is_array($photo)) {
                continue;
            }
            $roomId = $photo['room_id'] ?? null;
            if (is_string($roomId) && $roomId !== '') {
                $photosByRoom[$roomId][] = $photo;
            }
        }

        $overlapRoomIds = self::overlappingRoomIds($rooms);

        $flat = [
            'positions' => [],
            'normals' => [],
            'colors' => [],
            'indices' => [],
        ];
        $texturedWalls = [];

        foreach ($rooms as $i => $room) {
            $roomId = is_string($room['room_id'] ?? null) ? $room['room_id'] : '';
            $roomPhotos = $roomId === '' ? [] : ($photosByRoom[$roomId] ?? []);
            $isOverlap = $roomId !== '' && isset($overlapRoomIds[$roomId]);
            $roomEdgeTiers = FloorPlanPalette::withOpenEdges($layout['edgeTiers'][$i] ?? [], $room);
            self::appendRoomTextured($room, $layout['poses'][$i], $roomEdgeTiers, $roomPhotos, $photoLoader, $isOverlap, $flat, $texturedWalls);

            $tris = intdiv(count($flat['indices']), 3);
            foreach ($texturedWalls as $bucket) {
                $tris += intdiv(count($bucket['indices']), 3);
            }
            if ($tris > self::MAX_TRIANGLES) {
                throw new \InvalidArgumentException(sprintf(
                    'This floor plan needs more than %d triangles to draw in 3D.',
                    self::MAX_TRIANGLES
                ));
            }
        }

        if ($flat['positions'] === [] && $texturedWalls === []) {
            throw new \InvalidArgumentException('The captured rooms produced no usable 3D geometry.');
        }

        $roomPoses = [];
        foreach ($rooms as $i => $room) {
            $pose = $layout['poses'][$i];
            $roomPoses[] = [
                'room_id' => (string) ($room['room_id'] ?? ''),
                'origin_x' => (float) $pose['originX'],
                'origin_z' => (float) $pose['originZ'],
                'rotation_rad' => (float) $pose['rotationRad'],
                'base_y' => (float) ($pose['baseY'] ?? 0.0),
            ];
        }

        return self::packGlbMulti($flat, $texturedWalls, $roomPoses);
    }

    private static function capTextureSize(string $bytes, string $mime, int $width, int $height): array
    {
        $longest = max($width, $height);
        if ($width <= 0 || $height <= 0 || $longest <= self::MAX_TEXTURE_EDGE_PX) {
            return [$bytes, $mime];
        }
        $image = @imagecreatefromstring($bytes);
        if ($image === false) {
            return [$bytes, $mime];
        }
        $scale = self::MAX_TEXTURE_EDGE_PX / $longest;
        $targetWidth = max(1, (int) round($width * $scale));
        $targetHeight = max(1, (int) round($height * $scale));
        $resized = imagecreatetruecolor($targetWidth, $targetHeight);
        imagecopyresampled($resized, $image, 0, 0, 0, 0, $targetWidth, $targetHeight, $width, $height);
        imagedestroy($image);
        ob_start();
        imagejpeg($resized, null, 82);
        $resizedBytes = (string) ob_get_clean();
        imagedestroy($resized);
        return [$resizedBytes, 'image/jpeg'];
    }

    private static function overlappingRoomIds(array $rooms): array
    {
        $candidates = [];
        $candidateIndex = [];
        foreach ($rooms as $i => $room) {
            if (isset($room['structure_origin_m']) && is_array($room['structure_origin_m'])) {
                $candidateIndex[] = $i;
                $candidates[] = $room;
            }
        }
        if ($candidates === []) {
            return [];
        }
        $flagged = [];
        foreach (FusionOverlapDetector::detect($candidates) as $ci) {
            $orig = $candidateIndex[$ci] ?? null;
            $roomId = $orig !== null ? ($rooms[$orig]['room_id'] ?? null) : null;
            if (is_string($roomId) && $roomId !== '') {
                $flagged[$roomId] = true;
            }
        }
        return $flagged;
    }

    private static function fusedLayout(array $rooms): array
    {
        $poses = [];
        $edgeTiers = [];
        foreach (self::placements($rooms) as $i => [$x, $z]) {
            $poses[$i] = ['originX' => $x, 'originZ' => $z, 'rotationRad' => 0.0];
            $edgeTiers[$i] = [];
        }
        foreach ($rooms as $room) {
            if (!isset($room['structure_origin_m'])
                || !is_array($room['structure_origin_m'])
                || count($room['structure_origin_m']) < 2) {
                return ['rooms' => $rooms, 'poses' => $poses, 'edgeTiers' => $edgeTiers];
            }
        }

        $byFloor = [];
        foreach ($rooms as $i => $room) {
            $byFloor[mb_strtolower(trim((string) ($room['floor'] ?? '')), 'UTF-8')][] = $i;
        }
        foreach ($byFloor as $indices) {
            $subset = [];
            foreach ($indices as $i) {
                $room = $rooms[$i];
                $room['structure_origin_m'] = [(float) $room['structure_origin_m'][0], (float) $room['structure_origin_m'][1]];
                $subset[] = $room;
            }
            $fusion = RoomFusionSolver::solve($subset);
            $deduped = OpeningDedup::filter($subset, $fusion['poses']);
            foreach ($indices as $k => $i) {
                $poses[$i] = $fusion['poses'][$k];
                $edgeTiers[$i] = $fusion['edgeTiers'][$k] ?? [];
                $rooms[$i]['openings'] = $deduped[$k]['openings'] ?? [];
            }
        }
        return ['rooms' => $rooms, 'poses' => self::stackFloors($rooms, $poses), 'edgeTiers' => $edgeTiers];
    }

    private static function stackFloors(array $rooms, array $poses): array
    {
        $floors = [];
        foreach ($rooms as $i => $room) {
            $name = trim((string) ($room['floor'] ?? ''));
            $key = mb_strtolower($name, 'UTF-8');
            $floors[$key]['name'] = $name;
            $floors[$key]['rooms'][] = $i;
        }
        if (count($floors) < 2) {
            return $poses;
        }
        $order = array_keys($floors);
        usort($order, static function (string $a, string $b) use ($floors): int {
            $rankA = $floors[$a]['name'] === '' ? -1000 : FloorGroups::floorRank($floors[$a]['name']);
            $rankB = $floors[$b]['name'] === '' ? -1000 : FloorGroups::floorRank($floors[$b]['name']);
            return $rankA <=> $rankB;
        });

        $baseY = 0.0;
        foreach ($order as $key) {
            $minX = INF;
            $minZ = INF;
            $tallest = 0.0;
            foreach ($floors[$key]['rooms'] as $i) {
                foreach ($rooms[$i]['outline_m'] ?? [] as $p) {
                    if (!is_array($p) || count($p) < 2) {
                        continue;
                    }
                    [$wx, $wz] = RoomFusionSolver::transformPoint($poses[$i], (float) $p[0], (float) $p[1]);
                    $minX = min($minX, $wx);
                    $minZ = min($minZ, $wz);
                }
                $height = $rooms[$i]['height_m'] ?? null;
                $tallest = max($tallest, is_numeric($height) && (float) $height > 0 ? (float) $height : self::DEFAULT_HEIGHT_M);
            }
            $shiftX = is_finite($minX) ? $minX : 0.0;
            $shiftZ = is_finite($minZ) ? $minZ : 0.0;
            foreach ($floors[$key]['rooms'] as $i) {
                $poses[$i]['originX'] -= $shiftX;
                $poses[$i]['originZ'] -= $shiftZ;
                $poses[$i]['baseY'] = $baseY;
            }
            $baseY += $tallest + self::FLOOR_STACK_GAP_M;
        }
        return $poses;
    }

    private static function appendRoomTextured(
        array $room,
        array $pose,
        array $roomEdgeTiers,
        array $roomPhotos,
        callable $photoLoader,
        bool $isOverlap,
        array &$flat,
        array &$texturedWalls
    ): void {
        $outline = $room['outline_m'] ?? null;
        if (!is_array($outline) || count($outline) < 3) {
            return;
        }
        $outline = array_map(static fn ($p) => [(float) $p[0], (float) $p[1]], $outline);
        $height = isset($room['height_m']) && is_numeric($room['height_m']) && (float) $room['height_m'] > 0
            ? (float) $room['height_m']
            : self::DEFAULT_HEIGHT_M;
        $openings = is_array($room['openings'] ?? null) ? $room['openings'] : [];
        $headingDeg = isset($room['heading_deg']) && is_numeric($room['heading_deg'])
            ? (float) $room['heading_deg']
            : null;

        $photosWithBytes = [];
        if ($headingDeg !== null) {
            foreach ($roomPhotos as $photo) {
                $url = $photo['url'] ?? null;
                if (!is_string($url) || $url === '') {
                    continue;
                }
                $bytes = $photoLoader($url);
                if (!is_string($bytes) || $bytes === '') {
                    continue;
                }
                $imageInfo = @getimagesizefromstring($bytes);
                $mime = is_array($imageInfo) ? ($imageInfo['mime'] ?? null) : null;
                if (!in_array($mime, ['image/jpeg', 'image/png'], true)) {
                    continue;
                }
                [$bytes, $mime] = self::capTextureSize($bytes, $mime, (int) $imageInfo[0], (int) $imageInfo[1]);
                $photosWithBytes[] = [
                    'photo_id' => (string) ($photo['photo_id'] ?? ''),
                    'room_id' => (string) ($photo['room_id'] ?? ''),
                    'position_m' => is_array($photo['position_m'] ?? null) ? $photo['position_m'] : [0.0, 0.0],
                    'heading_deg' => is_numeric($photo['heading_deg'] ?? null) ? (float) $photo['heading_deg'] : null,
                    'imageBytes' => $bytes,
                    'imageMime' => $mime,
                ];
            }
        }

        $floorColor = $isOverlap ? self::OVERLAP_COLOR : self::FLOOR_COLOR;
        $wallColor = $isOverlap ? self::OVERLAP_COLOR : self::WALL_COLOR;
        self::appendFloorToBucket($outline, $pose, $floorColor, $flat);
        self::appendWallsTextured($outline, $pose, $roomEdgeTiers, $height, $openings, $headingDeg, $photosWithBytes, $isOverlap, $wallColor, $flat, $texturedWalls);
    }

    private static function posePoint(array $pose, float $x, float $y, float $z): array
    {
        [$wx, $wz] = RoomFusionSolver::transformPoint($pose, $x, $z);
        return [$wx, $y + (float) ($pose['baseY'] ?? 0.0), $wz];
    }

    private static function poseNormal(array $pose, float $nx, float $ny, float $nz): array
    {
        $cos = cos($pose['rotationRad']);
        $sin = sin($pose['rotationRad']);
        return [$nx * $cos - $nz * $sin, $ny, $nx * $sin + $nz * $cos];
    }

    private static function appendFloorToBucket(array $outline, array $pose, array $floorColor, array &$flat): void
    {
        $triangles = self::triangulate($outline);
        if ($triangles === []) {
            return;
        }
        $base = intdiv(count($flat['positions']), 3);
        foreach ($outline as $p) {
            [$wx, $wy, $wz] = self::posePoint($pose, $p[0], 0.0, $p[1]);
            $flat['positions'][] = $wx;
            $flat['positions'][] = $wy;
            $flat['positions'][] = $wz;
            $flat['normals'][] = 0.0;
            $flat['normals'][] = 1.0;
            $flat['normals'][] = 0.0;
            if (array_key_exists('colors', $flat)) {
                foreach ($floorColor as $col) {
                    $flat['colors'][] = $col;
                }
            }
        }
        foreach ($triangles as $tri) {
            $flat['indices'][] = $base + $tri[0];
            $flat['indices'][] = $base + $tri[1];
            $flat['indices'][] = $base + $tri[2];
        }
    }

    private static function appendWallsTextured(
        array $outline,
        array $pose,
        array $roomEdgeTiers,
        float $height,
        array $openings,
        ?float $headingDeg,
        array $photosWithBytes,
        bool $isOverlap,
        array $wallColor,
        array &$flat,
        array &$texturedWalls
    ): void {
        $n = count($outline);
        $signed = self::signedArea($outline);
        $inward = $signed >= 0 ? 1.0 : -1.0;
        for ($i = 0; $i < $n; $i++) {
            if (FloorPlanPalette::isOpenEdge($roomEdgeTiers, $i)) {
                continue;
            }
            $a = $outline[$i];
            $b = $outline[($i + 1) % $n];
            $dx = $b[0] - $a[0];
            $dz = $b[1] - $a[1];
            $len = sqrt($dx * $dx + $dz * $dz);
            if ($len < 1e-6) {
                continue;
            }
            $ux = $dx / $len;
            $uz = $dz / $len;
            $nx = -$uz * $inward;
            $nz = $ux * $inward;

            $interior = isset($roomEdgeTiers[$i]);
            $innerHalf = FloorPlanPalette::wallThicknessM(false, $interior) / 2;
            $seamGap = $roomEdgeTiers[$i] ?? null;
            $outerHalf = is_float($seamGap) ? max($innerHalf, $seamGap / 2 + self::SEAM_OVERLAP_M) : $innerHalf;

            $wallPhoto = null;
            if (!$isOverlap && $headingDeg !== null && $photosWithBytes !== []) {
                $projectable = array_values(array_filter(
                    $photosWithBytes,
                    static fn (array $p): bool => $p['heading_deg'] !== null
                ));
                if ($projectable !== []) {
                    $wallPhoto = WallTextureProjection::pickWallPhoto(
                        $a,
                        $b,
                        [$nx, $nz],
                        $headingDeg,
                        $height,
                        $projectable
                    );
                }
            }

            $at = static fn (float $t): array => [$a[0] + $ux * $t, $a[1] + $uz * $t];
            $spans = self::openingSpans($a, $len, $ux, $uz, $height, $openings);
            $cursor = 0.0;
            $pieces = [];
            foreach ($spans as $span) {
                if ($span['t0'] > $cursor + 1e-6) {
                    $pieces[] = [$cursor, $span['t0'], 0.0, $height];
                }
                if ($span['y0'] > 1e-4) {
                    $pieces[] = [$span['t0'], $span['t1'], 0.0, $span['y0']];
                }
                if ($span['y1'] < $height - 1e-4) {
                    $pieces[] = [$span['t0'], $span['t1'], $span['y1'], $height];
                }
                $cursor = max($cursor, $span['t1']);
            }
            if ($cursor < $len - 1e-6) {
                $pieces[] = [$cursor, $len, 0.0, $height];
            }
            foreach ($pieces as [$t0, $t1, $y0, $y1]) {
                $startT = $t0 <= 1e-6 ? -$innerHalf : $t0;
                $endT = $t1 >= $len - 1e-6 ? $len + $innerHalf : $t1;
                self::appendWallBoxToBuckets(
                    $at($startT), $at($endT), $ux, $uz, $nx, $nz, $innerHalf, $outerHalf, $y0, $y1, $pose,
                    $wallPhoto, $headingDeg, $wallColor, $flat, $texturedWalls
                );
            }
            $frameInner = $innerHalf + self::FRAME_EXTRA_DEPTH_M;
            $frameOuter = $outerHalf + self::FRAME_EXTRA_DEPTH_M;
            foreach ($spans as $span) {
                $post = min(self::FRAME_POST_M, ($span['t1'] - $span['t0']) / 4, ($span['y1'] - $span['y0']) / 4);
                if ($post <= 0) {
                    continue;
                }
                $color = $span['color'];
                $bars = [
                    [$span['t0'], $span['t0'] + $post, $span['y0'], $span['y1']],
                    [$span['t1'] - $post, $span['t1'], $span['y0'], $span['y1']],
                    [$span['t0'], $span['t1'], $span['y1'] - $post, $span['y1']],
                ];
                if ($span['y0'] > 1e-4) {
                    $bars[] = [$span['t0'], $span['t1'], $span['y0'], $span['y0'] + $post];
                }
                foreach ($bars as [$t0, $t1, $y0, $y1]) {
                    self::appendWallBoxToBuckets(
                        $at($t0), $at($t1), $ux, $uz, $nx, $nz, $frameInner, $frameOuter, $y0, $y1, $pose,
                        null, null, $color, $flat, $texturedWalls
                    );
                }
            }
        }
    }

    private static function openingSpans(array $a, float $len, float $ux, float $uz, float $height, array $openings): array
    {
        $spans = [];
        foreach ($openings as $opening) {
            $pos = $opening['position_m'] ?? null;
            if (!is_array($pos) || count($pos) < 2) {
                continue;
            }
            $px = (float) $pos[0];
            $pz = (float) $pos[1];
            $t = ($px - $a[0]) * $ux + ($pz - $a[1]) * $uz;
            $perp = abs(($px - $a[0]) * $uz - ($pz - $a[1]) * $ux);
            if ($perp > self::MAX_OPENING_WALL_DISTANCE_M || $t < -0.3 || $t > $len + 0.3) {
                continue;
            }
            $category = (string) ($opening['category'] ?? 'opening');
            $rawWidth = $opening['width_m'] ?? null;
            if (is_numeric($rawWidth) && (float) $rawWidth >= 0.2 && (float) $rawWidth <= 6.0) {
                $width = (float) $rawWidth;
            } else {
                $width = match ($category) {
                    'door' => 0.9,
                    'window' => 1.2,
                    default => 0.8,
                };
            }
            $t0 = max(0.0, $t - $width / 2);
            $t1 = min($len, $t + $width / 2);
            if ($t1 - $t0 < 1e-3) {
                continue;
            }
            if ($category === 'door') {
                [$y0, $y1, $color] = [0.0, min(self::DOOR_HEIGHT_M, $height), self::DOOR_COLOR];
            } elseif ($category === 'window') {
                $sill = min(self::WINDOW_SILL_M, $height - 0.1);
                [$y0, $y1, $color] = [$sill, min($sill + self::WINDOW_HEIGHT_M, $height), self::WINDOW_COLOR];
            } else {
                [$y0, $y1, $color] = [0.0, min(self::OTHER_OPENING_HEIGHT_M, $height), self::OTHER_OPENING_COLOR];
            }
            if ($y1 - $y0 < 1e-3) {
                continue;
            }
            $spans[] = ['t0' => $t0, 't1' => $t1, 'y0' => $y0, 'y1' => $y1, 'color' => $color];
        }
        usort($spans, static fn (array $x, array $y) => $x['t0'] <=> $y['t0']);
        $merged = [];
        foreach ($spans as $span) {
            $last = $merged === [] ? null : $merged[count($merged) - 1];
            if ($last !== null && $span['t0'] < $last['t1']) {
                $merged[count($merged) - 1] = [
                    't0' => $last['t0'],
                    't1' => max($last['t1'], $span['t1']),
                    'y0' => min($last['y0'], $span['y0']),
                    'y1' => max($last['y1'], $span['y1']),
                    'color' => $last['color'],
                ];
            } else {
                $merged[] = $span;
            }
        }
        return $merged;
    }

    private static function appendWallBoxToBuckets(
        array $a,
        array $b,
        float $ux,
        float $uz,
        float $nx,
        float $nz,
        float $innerHalf,
        float $outerHalf,
        float $y0,
        float $y1,
        array $pose,
        ?array $wallPhoto,
        ?float $headingDeg,
        array $wallColor,
        array &$flat,
        array &$texturedWalls
    ): void {
        $iA0 = self::posePoint($pose, $a[0] + $nx * $innerHalf, $y0, $a[1] + $nz * $innerHalf);
        $iB0 = self::posePoint($pose, $b[0] + $nx * $innerHalf, $y0, $b[1] + $nz * $innerHalf);
        $iAh = self::posePoint($pose, $a[0] + $nx * $innerHalf, $y1, $a[1] + $nz * $innerHalf);
        $iBh = self::posePoint($pose, $b[0] + $nx * $innerHalf, $y1, $b[1] + $nz * $innerHalf);
        $oA0 = self::posePoint($pose, $a[0] - $nx * $outerHalf, $y0, $a[1] - $nz * $outerHalf);
        $oB0 = self::posePoint($pose, $b[0] - $nx * $outerHalf, $y0, $b[1] - $nz * $outerHalf);
        $oAh = self::posePoint($pose, $a[0] - $nx * $outerHalf, $y1, $a[1] - $nz * $outerHalf);
        $oBh = self::posePoint($pose, $b[0] - $nx * $outerHalf, $y1, $b[1] - $nz * $outerHalf);

        $inwardNormal = self::poseNormal($pose, $nx, 0.0, $nz);
        $outwardNormal = self::poseNormal($pose, -$nx, 0.0, -$nz);
        $startNormal = self::poseNormal($pose, -$ux, 0.0, -$uz);
        $endNormal = self::poseNormal($pose, $ux, 0.0, $uz);

        $uvs = null;
        if ($wallPhoto !== null && $headingDeg !== null) {
            $localA0 = [$a[0] + $nx * $innerHalf, $y0, $a[1] + $nz * $innerHalf];
            $localB0 = [$b[0] + $nx * $innerHalf, $y0, $b[1] + $nz * $innerHalf];
            $localBh = [$b[0] + $nx * $innerHalf, $y1, $b[1] + $nz * $innerHalf];
            $localAh = [$a[0] + $nx * $innerHalf, $y1, $a[1] + $nz * $innerHalf];
            $uvs = self::wallFaceUvs($wallPhoto, $headingDeg, [$localA0, $localB0, $localBh, $localAh]);
        }

        if ($uvs !== null) {
            $photoId = (string) ($wallPhoto['photo_id'] ?? '');
            $bucketIndex = null;
            if ($photoId !== '') {
                foreach ($texturedWalls as $index => $existing) {
                    if (($existing['photoId'] ?? '') === $photoId) {
                        $bucketIndex = $index;
                        break;
                    }
                }
            }
            if ($bucketIndex === null) {
                $texturedWalls[] = [
                    'positions' => [],
                    'normals' => [],
                    'uvs' => [],
                    'indices' => [],
                    'imageBytes' => $wallPhoto['imageBytes'],
                    'imageMime' => $wallPhoto['imageMime'],
                    'photoId' => $photoId,
                ];
                $bucketIndex = count($texturedWalls) - 1;
            }
            self::appendQuadToBucket($texturedWalls[$bucketIndex], [$iA0, $iB0, $iBh, $iAh], $inwardNormal, $wallColor, $uvs);
        } else {
            self::appendQuadToBucket($flat, [$iA0, $iB0, $iBh, $iAh], $inwardNormal, $wallColor, null);
        }

        self::appendQuadToBucket($flat, [$oA0, $oB0, $oBh, $oAh], $outwardNormal, $wallColor, null);
        self::appendQuadToBucket($flat, [$iA0, $oA0, $oB0, $iB0], [0.0, -1.0, 0.0], $wallColor, null);
        self::appendQuadToBucket($flat, [$iAh, $oAh, $oBh, $iBh], [0.0, 1.0, 0.0], $wallColor, null);
        self::appendQuadToBucket($flat, [$iA0, $oA0, $oAh, $iAh], $startNormal, $wallColor, null);
        self::appendQuadToBucket($flat, [$iB0, $oB0, $oBh, $iBh], $endNormal, $wallColor, null);
    }

    private static function wallFaceUvs(array $photo, float $roomHeadingDeg, array $corners): ?array
    {
        $photoHeading = $photo['heading_deg'] ?? null;
        if (!is_numeric($photoHeading)) {
            return null;
        }
        $uvs = [];
        foreach ($corners as $c) {
            $uv = WallTextureProjection::projectPointRaw($photo, $roomHeadingDeg, $c[0], $c[1], $c[2]);
            if ($uv === null) {
                return null;
            }
            $uvs[] = [
                max(0.0, min(1.0, $uv[0])),
                max(0.0, min(1.0, $uv[1])),
            ];
        }
        return $uvs;
    }

    private static function appendQuadToBucket(
        array &$bucket,
        array $corners,
        array $normal,
        array $color,
        ?array $uvs
    ): void {
        $base = intdiv(count($bucket['positions']), 3);
        for ($i = 0; $i < 4; $i++) {
            $c = $corners[$i];
            $bucket['positions'][] = $c[0];
            $bucket['positions'][] = $c[1];
            $bucket['positions'][] = $c[2];
            $bucket['normals'][] = $normal[0];
            $bucket['normals'][] = $normal[1];
            $bucket['normals'][] = $normal[2];
            if (array_key_exists('colors', $bucket)) {
                foreach ($color as $col) {
                    $bucket['colors'][] = $col;
                }
            }
            if (array_key_exists('uvs', $bucket)) {
                $uv = $uvs[$i] ?? [0.0, 0.0];
                $bucket['uvs'][] = $uv[0];
                $bucket['uvs'][] = $uv[1];
            }
        }
        $bucket['indices'][] = $base;
        $bucket['indices'][] = $base + 1;
        $bucket['indices'][] = $base + 2;
        $bucket['indices'][] = $base;
        $bucket['indices'][] = $base + 2;
        $bucket['indices'][] = $base + 3;
    }

    private static function packGlbMulti(array $flat, array $texturedWalls, array $roomPoses = []): string
    {
        $bin = '';
        $bufferViews = [];
        $accessors = [];
        $images = [];
        $textures = [];
        $materials = [];
        $primitives = [];
        $samplers = [[
            'magFilter' => 9729,
            'minFilter' => 9987,
            'wrapS' => 33071,
            'wrapT' => 33071,
        ]];

        if ($flat['positions'] !== []) {
            $flatAcc = self::appendBucketAccessors($flat, false, $bin, $bufferViews, $accessors);
            $materials[] = [
                'name' => 'flat',
                'pbrMetallicRoughness' => [
                    'baseColorFactor' => [1.0, 1.0, 1.0, 1.0],
                    'metallicFactor' => 0.0,
                    'roughnessFactor' => 0.9,
                ],
                'doubleSided' => false,
            ];
            $primitives[] = [
                'attributes' => [
                    'POSITION' => $flatAcc['pos'],
                    'NORMAL' => $flatAcc['nrm'],
                    'COLOR_0' => $flatAcc['col'],
                ],
                'indices' => $flatAcc['idx'],
                'mode' => 4,
                'material' => count($materials) - 1,
            ];
        }

        $textureByPhoto = [];
        foreach ($texturedWalls as $bucket) {
            if ($bucket['positions'] === []) {
                continue;
            }
            $photoId = (string) ($bucket['photoId'] ?? '');
            if ($photoId !== '' && isset($textureByPhoto[$photoId])) {
                $textureIndex = $textureByPhoto[$photoId];
            } else {
                $imageBytes = (string) $bucket['imageBytes'];
                $imageLength = strlen($imageBytes);
                $alignedImageLength = self::align4($imageLength);
                $pad = $alignedImageLength - $imageLength;
                $binPad = (4 - (strlen($bin) % 4)) % 4;
                $bin .= str_repeat("\0", $binPad);
                $imageOffset = strlen($bin);
                $bin .= $imageBytes;
                $bin .= str_repeat("\0", $pad);
                $imageViewIndex = count($bufferViews);
                $bufferViews[] = [
                    'buffer' => 0,
                    'byteOffset' => $imageOffset,
                    'byteLength' => $alignedImageLength,
                ];
                $imageIndex = count($images);
                $images[] = [
                    'bufferView' => $imageViewIndex,
                    'mimeType' => (string) $bucket['imageMime'],
                ];
                $textureIndex = count($textures);
                $textures[] = [
                    'sampler' => 0,
                    'source' => $imageIndex,
                ];
                if ($photoId !== '') {
                    $textureByPhoto[$photoId] = $textureIndex;
                }
            }

            $texAcc = self::appendBucketAccessors($bucket, true, $bin, $bufferViews, $accessors);
            $materials[] = [
                'name' => 'textured-' . (string) ($bucket['photoId'] ?? 'wall'),
                'pbrMetallicRoughness' => [
                    'baseColorFactor' => [1.0, 1.0, 1.0, 1.0],
                    'baseColorTexture' => ['index' => $textureIndex],
                    'metallicFactor' => 0.0,
                    'roughnessFactor' => 0.9,
                ],
                'doubleSided' => false,
            ];
            $primitives[] = [
                'attributes' => [
                    'POSITION' => $texAcc['pos'],
                    'NORMAL' => $texAcc['nrm'],
                    'TEXCOORD_0' => $texAcc['uv'],
                ],
                'indices' => $texAcc['idx'],
                'mode' => 4,
                'material' => count($materials) - 1,
            ];
        }

        if ($primitives === []) {
            throw new \InvalidArgumentException('The captured rooms produced no usable 3D geometry.');
        }

        $binPad = (4 - (strlen($bin) % 4)) % 4;
        $bin .= str_repeat("\0", $binPad);

        $gltf = [
            'asset' => ['version' => '2.0', 'generator' => 'Vuuro Scan'],
            'scene' => 0,
            'scenes' => [$roomPoses === [] ? ['nodes' => [0]] : ['nodes' => [0], 'extras' => ['room_poses' => $roomPoses]]],
            'nodes' => [['mesh' => 0]],
            'meshes' => [['primitives' => $primitives]],
            'accessors' => $accessors,
            'bufferViews' => $bufferViews,
            'buffers' => [['byteLength' => strlen($bin)]],
            'materials' => $materials,
        ];
        if ($images !== []) {
            $gltf['images'] = $images;
            $gltf['textures'] = $textures;
            $gltf['samplers'] = $samplers;
        }

        $json = json_encode($gltf, JSON_UNESCAPED_SLASHES);
        $jsonPad = (4 - (strlen($json) % 4)) % 4;
        $json .= str_repeat(' ', $jsonPad);

        $jsonLen = strlen($json);
        $binLen = strlen($bin);
        $totalLen = 12 + 8 + $jsonLen + 8 + $binLen;

        $glb = pack('V3', 0x46546C67, 2, $totalLen);
        $glb .= pack('V2', $jsonLen, 0x4E4F534A) . $json;
        $glb .= pack('V2', $binLen, 0x004E4942) . $bin;
        return $glb;
    }

    private static function appendBucketAccessors(
        array $bucket,
        bool $isTextured,
        string &$bin,
        array &$bufferViews,
        array &$accessors
    ): array {
        $vertexCount = intdiv(count($bucket['positions']), 3);
        $minPos = [INF, INF, INF];
        $maxPos = [-INF, -INF, -INF];
        for ($i = 0; $i < count($bucket['positions']); $i += 3) {
            for ($k = 0; $k < 3; $k++) {
                $v = (float) $bucket['positions'][$i + $k];
                if ($v < $minPos[$k]) { $minPos[$k] = $v; }
                if ($v > $maxPos[$k]) { $maxPos[$k] = $v; }
            }
        }

        $posData = pack('f*', ...$bucket['positions']);
        $binPad = (4 - (strlen($bin) % 4)) % 4;
        $bin .= str_repeat("\0", $binPad);
        $posOffset = strlen($bin);
        $bin .= $posData;
        $posViewIndex = count($bufferViews);
        $bufferViews[] = [
            'buffer' => 0,
            'byteOffset' => $posOffset,
            'byteLength' => strlen($posData),
            'target' => 34962,
        ];
        $posAcc = count($accessors);
        $accessors[] = [
            'bufferView' => $posViewIndex,
            'componentType' => 5126,
            'count' => $vertexCount,
            'type' => 'VEC3',
            'min' => $minPos,
            'max' => $maxPos,
        ];

        $nrmData = pack('f*', ...$bucket['normals']);
        $binPad = (4 - (strlen($bin) % 4)) % 4;
        $bin .= str_repeat("\0", $binPad);
        $nrmOffset = strlen($bin);
        $bin .= $nrmData;
        $nrmViewIndex = count($bufferViews);
        $bufferViews[] = [
            'buffer' => 0,
            'byteOffset' => $nrmOffset,
            'byteLength' => strlen($nrmData),
            'target' => 34962,
        ];
        $nrmAcc = count($accessors);
        $accessors[] = [
            'bufferView' => $nrmViewIndex,
            'componentType' => 5126,
            'count' => $vertexCount,
            'type' => 'VEC3',
        ];

        $colAcc = null;
        $uvAcc = null;
        if ($isTextured) {
            $uvData = pack('f*', ...$bucket['uvs']);
            $binPad = (4 - (strlen($bin) % 4)) % 4;
            $bin .= str_repeat("\0", $binPad);
            $uvOffset = strlen($bin);
            $bin .= $uvData;
            $uvViewIndex = count($bufferViews);
            $bufferViews[] = [
                'buffer' => 0,
                'byteOffset' => $uvOffset,
                'byteLength' => strlen($uvData),
                'target' => 34962,
            ];
            $uvAcc = count($accessors);
            $accessors[] = [
                'bufferView' => $uvViewIndex,
                'componentType' => 5126,
                'count' => $vertexCount,
                'type' => 'VEC2',
            ];
        } else {
            $colData = pack('f*', ...$bucket['colors']);
            $binPad = (4 - (strlen($bin) % 4)) % 4;
            $bin .= str_repeat("\0", $binPad);
            $colOffset = strlen($bin);
            $bin .= $colData;
            $colViewIndex = count($bufferViews);
            $bufferViews[] = [
                'buffer' => 0,
                'byteOffset' => $colOffset,
                'byteLength' => strlen($colData),
                'target' => 34962,
            ];
            $colAcc = count($accessors);
            $accessors[] = [
                'bufferView' => $colViewIndex,
                'componentType' => 5126,
                'count' => $vertexCount,
                'type' => 'VEC4',
            ];
        }

        $idxData = pack('V*', ...$bucket['indices']);
        $binPad = (4 - (strlen($bin) % 4)) % 4;
        $bin .= str_repeat("\0", $binPad);
        $idxOffset = strlen($bin);
        $bin .= $idxData;
        $idxViewIndex = count($bufferViews);
        $bufferViews[] = [
            'buffer' => 0,
            'byteOffset' => $idxOffset,
            'byteLength' => strlen($idxData),
            'target' => 34963,
        ];
        $idxAcc = count($accessors);
        $accessors[] = [
            'bufferView' => $idxViewIndex,
            'componentType' => 5125,
            'count' => count($bucket['indices']),
            'type' => 'SCALAR',
        ];

        return [
            'pos' => $posAcc,
            'nrm' => $nrmAcc,
            'col' => $colAcc,
            'uv' => $uvAcc,
            'idx' => $idxAcc,
        ];
    }

    private static function placements(array $rooms): array
    {
        $allHaveOrigin = true;
        foreach ($rooms as $room) {
            if (!isset($room['structure_origin_m'])
                || !is_array($room['structure_origin_m'])
                || count($room['structure_origin_m']) < 2) {
                $allHaveOrigin = false;
                break;
            }
        }
        $placements = [];
        if ($allHaveOrigin) {
            foreach ($rooms as $i => $room) {
                $placements[$i] = [(float) $room['structure_origin_m'][0], (float) $room['structure_origin_m'][1]];
            }
            return $placements;
        }
        $cursorX = 0.0;
        foreach ($rooms as $i => $room) {
            $outline = $room['outline_m'] ?? [];
            if (!is_array($outline) || $outline === []) {
                $placements[$i] = [$cursorX, 0.0];
                continue;
            }
            $xs = array_map(static fn ($p) => (float) $p[0], $outline);
            $width = max($xs) - min($xs);
            $placements[$i] = [$cursorX, 0.0];
            $cursorX += $width + 0.4;
        }
        return $placements;
    }

    private static function appendRoom(array $room, array $placement, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $outline = $room['outline_m'] ?? null;
        if (!is_array($outline) || count($outline) < 3) {
            return;
        }
        $outline = array_map(static fn ($p) => [(float) $p[0], (float) $p[1]], $outline);
        [$ox, $oz] = $placement;
        $height = isset($room['height_m']) && is_numeric($room['height_m']) && (float) $room['height_m'] > 0
            ? (float) $room['height_m']
            : self::DEFAULT_HEIGHT_M;
        $openings = is_array($room['openings'] ?? null) ? $room['openings'] : [];
        self::appendFloor($outline, $ox, $oz, $positions, $normals, $colors, $indices);
        self::appendWalls($outline, $ox, $oz, $height, $openings, $positions, $normals, $colors, $indices);
    }

    private static function appendFloor(array $outline, float $ox, float $oz, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $triangles = self::triangulate($outline);
        if ($triangles === []) {
            return;
        }
        $base = intdiv(count($positions), 3);
        foreach ($outline as $p) {
            $positions[] = $p[0] + $ox;
            $positions[] = 0.0;
            $positions[] = $p[1] + $oz;
            $normals[] = 0.0;
            $normals[] = 1.0;
            $normals[] = 0.0;
            foreach (self::FLOOR_COLOR as $c) {
                $colors[] = $c;
            }
        }
        foreach ($triangles as $tri) {
            $indices[] = $base + $tri[0];
            $indices[] = $base + $tri[1];
            $indices[] = $base + $tri[2];
        }
    }

    private static function appendWalls(array $outline, float $ox, float $oz, float $height, array $openings, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $n = count($outline);
        $signed = self::signedArea($outline);
        $inward = $signed >= 0 ? 1.0 : -1.0;
        for ($i = 0; $i < $n; $i++) {
            $a = $outline[$i];
            $b = $outline[($i + 1) % $n];
            $dx = $b[0] - $a[0];
            $dz = $b[1] - $a[1];
            $len = sqrt($dx * $dx + $dz * $dz);
            if ($len < 1e-6) {
                continue;
            }
            $ux = $dx / $len;
            $uz = $dz / $len;
            $nx = -$uz * $inward;
            $nz = $ux * $inward;
            foreach (self::wallSegments($a, $len, $ux, $uz, $openings) as $seg) {
                $pa = [$a[0] + $ux * $seg[0], $a[1] + $uz * $seg[0]];
                $pb = [$a[0] + $ux * $seg[1], $a[1] + $uz * $seg[1]];
                self::appendWallBox($pa, $pb, $ux, $uz, $nx, $nz, $height, $ox, $oz, $positions, $normals, $colors, $indices);
            }
        }
    }

    private static function wallSegments(array $a, float $len, float $ux, float $uz, array $openings): array
    {
        $spans = [];
        foreach ($openings as $opening) {
            $pos = $opening['position_m'] ?? null;
            if (!is_array($pos) || count($pos) < 2) {
                continue;
            }
            $px = (float) $pos[0];
            $pz = (float) $pos[1];
            $t = ($px - $a[0]) * $ux + ($pz - $a[1]) * $uz;
            $perp = abs(($px - $a[0]) * $uz - ($pz - $a[1]) * $ux);
            if ($perp > self::MAX_OPENING_WALL_DISTANCE_M) {
                continue;
            }
            if ($t < -0.3 || $t > $len + 0.3) {
                continue;
            }
            $category = (string) ($opening['category'] ?? 'opening');
            $rawWidth = $opening['width_m'] ?? null;
            if (is_numeric($rawWidth) && (float) $rawWidth >= 0.2 && (float) $rawWidth <= 6.0) {
                $width = (float) $rawWidth;
            } else {
                $width = match ($category) {
                    'door' => 0.9,
                    'window' => 1.2,
                    default => 0.8,
                };
            }
            $spans[] = [max(0.0, $t - $width / 2), min($len, $t + $width / 2)];
        }
        if ($spans === []) {
            return [[0.0, $len]];
        }
        usort($spans, static fn (array $x, array $y) => $x[0] <=> $y[0]);
        $merged = [];
        foreach ($spans as $span) {
            if ($merged === [] || $span[0] > $merged[count($merged) - 1][1] + 1e-6) {
                $merged[] = $span;
            } else {
                $last = array_pop($merged);
                $merged[] = [$last[0], max($last[1], $span[1])];
            }
        }
        $result = [];
        $cursor = 0.0;
        foreach ($merged as $span) {
            if ($span[0] > $cursor + 1e-6) {
                $result[] = [$cursor, $span[0]];
            }
            $cursor = max($cursor, $span[1]);
        }
        if ($cursor < $len - 1e-6) {
            $result[] = [$cursor, $len];
        }
        return $result;
    }

    private static function appendWallBox(array $a, array $b, float $ux, float $uz, float $nx, float $nz, float $height, float $ox, float $oz, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $half = self::WALL_THICKNESS_M / 2;
        $iA0 = [$a[0] + $nx * $half + $ox, 0.0, $a[1] + $nz * $half + $oz];
        $iB0 = [$b[0] + $nx * $half + $ox, 0.0, $b[1] + $nz * $half + $oz];
        $iAh = [$a[0] + $nx * $half + $ox, $height, $a[1] + $nz * $half + $oz];
        $iBh = [$b[0] + $nx * $half + $ox, $height, $b[1] + $nz * $half + $oz];
        $oA0 = [$a[0] - $nx * $half + $ox, 0.0, $a[1] - $nz * $half + $oz];
        $oB0 = [$b[0] - $nx * $half + $ox, 0.0, $b[1] - $nz * $half + $oz];
        $oAh = [$a[0] - $nx * $half + $ox, $height, $a[1] - $nz * $half + $oz];
        $oBh = [$b[0] - $nx * $half + $ox, $height, $b[1] - $nz * $half + $oz];
        self::appendQuad($iA0, $iB0, $iBh, $iAh, [$nx, 0.0, $nz], $positions, $normals, $colors, $indices);
        self::appendQuad($oA0, $oB0, $oBh, $oAh, [-$nx, 0.0, -$nz], $positions, $normals, $colors, $indices);
        self::appendQuad($iA0, $oA0, $oB0, $iB0, [0.0, -1.0, 0.0], $positions, $normals, $colors, $indices);
        self::appendQuad($iAh, $oAh, $oBh, $iBh, [0.0, 1.0, 0.0], $positions, $normals, $colors, $indices);
        self::appendQuad($iA0, $oA0, $oAh, $iAh, [-$ux, 0.0, -$uz], $positions, $normals, $colors, $indices);
        self::appendQuad($iB0, $oB0, $oBh, $iBh, [$ux, 0.0, $uz], $positions, $normals, $colors, $indices);
    }

    private static function appendQuad(array $p0, array $p1, array $p2, array $p3, array $normal, array &$positions, array &$normals, array &$colors, array &$indices): void
    {
        $base = intdiv(count($positions), 3);
        foreach ([$p0, $p1, $p2, $p3] as $p) {
            $positions[] = $p[0];
            $positions[] = $p[1];
            $positions[] = $p[2];
            $normals[] = $normal[0];
            $normals[] = $normal[1];
            $normals[] = $normal[2];
            foreach (self::WALL_COLOR as $c) {
                $colors[] = $c;
            }
        }
        $indices[] = $base;
        $indices[] = $base + 1;
        $indices[] = $base + 2;
        $indices[] = $base;
        $indices[] = $base + 2;
        $indices[] = $base + 3;
    }

    private static function triangulate(array $polygon): array
    {
        if (count($polygon) < 3) {
            return [];
        }
        if (self::signedArea($polygon) < 0) {
            $polygon = array_reverse($polygon);
        }
        $indices = range(0, count($polygon) - 1);
        $triangles = [];
        $guard = 0;
        while (count($indices) > 3 && $guard < 10000) {
            $guard++;
            $found = false;
            $m = count($indices);
            for ($i = 0; $i < $m; $i++) {
                $iPrev = $indices[($i - 1 + $m) % $m];
                $iCurr = $indices[$i];
                $iNext = $indices[($i + 1) % $m];
                $a = $polygon[$iPrev];
                $b = $polygon[$iCurr];
                $c = $polygon[$iNext];
                $cross = ($b[0] - $a[0]) * ($c[1] - $a[1]) - ($b[1] - $a[1]) * ($c[0] - $a[0]);
                if ($cross <= 1e-9) {
                    continue;
                }
                $isEar = true;
                foreach ($indices as $j) {
                    if ($j === $iPrev || $j === $iCurr || $j === $iNext) {
                        continue;
                    }
                    if (self::pointInTriangle($polygon[$j], $a, $b, $c)) {
                        $isEar = false;
                        break;
                    }
                }
                if ($isEar) {
                    $triangles[] = [$iPrev, $iCurr, $iNext];
                    array_splice($indices, $i, 1);
                    $found = true;
                    break;
                }
            }
            if (!$found) {
                break;
            }
        }
        if (count($indices) === 3) {
            $triangles[] = $indices;
        }
        return $triangles;
    }

    private static function signedArea(array $polygon): float
    {
        $sum = 0.0;
        $n = count($polygon);
        for ($i = 0; $i < $n; $i++) {
            $sum += $polygon[$i][0] * $polygon[($i + 1) % $n][1]
                - $polygon[($i + 1) % $n][0] * $polygon[$i][1];
        }
        return $sum / 2.0;
    }

    private static function pointInTriangle(array $p, array $a, array $b, array $c): bool
    {
        $d1 = ($b[0] - $a[0]) * ($p[1] - $a[1]) - ($b[1] - $a[1]) * ($p[0] - $a[0]);
        $d2 = ($c[0] - $b[0]) * ($p[1] - $b[1]) - ($c[1] - $b[1]) * ($p[0] - $b[0]);
        $d3 = ($a[0] - $c[0]) * ($p[1] - $c[1]) - ($a[1] - $c[1]) * ($p[0] - $c[0]);
        $hasNeg = $d1 < 0 || $d2 < 0 || $d3 < 0;
        $hasPos = $d1 > 0 || $d2 > 0 || $d3 > 0;
        return !($hasNeg && $hasPos);
    }

    private static function align4(int $n): int
    {
        return ($n + 3) & ~3;
    }

    private static function packGlb(array $positions, array $normals, array $colors, array $indices): string
    {
        $vertexCount = intdiv(count($positions), 3);
        $positionsData = pack('f*', ...$positions);
        $normalsData = pack('f*', ...$normals);
        $colorsData = pack('f*', ...$colors);
        $indicesData = pack('V*', ...$indices);

        $posLen = strlen($positionsData);
        $nrmLen = strlen($normalsData);
        $colLen = strlen($colorsData);
        $idxLen = strlen($indicesData);

        $posOffset = 0;
        $nrmOffset = self::align4($posOffset + $posLen);
        $colOffset = self::align4($nrmOffset + $nrmLen);
        $idxOffset = self::align4($colOffset + $colLen);
        $binLen = self::align4($idxOffset + $idxLen);

        $bin = str_pad($positionsData, $nrmOffset, "\0");
        $bin .= str_pad($normalsData, $colOffset - $nrmOffset, "\0");
        $bin .= str_pad($colorsData, $idxOffset - $colOffset, "\0");
        $bin .= str_pad($indicesData, $binLen - $idxOffset, "\0");

        $minPos = [INF, INF, INF];
        $maxPos = [-INF, -INF, -INF];
        for ($i = 0; $i < count($positions); $i += 3) {
            for ($k = 0; $k < 3; $k++) {
                $v = (float) $positions[$i + $k];
                if ($v < $minPos[$k]) $minPos[$k] = $v;
                if ($v > $maxPos[$k]) $maxPos[$k] = $v;
            }
        }

        $gltf = [
            'asset' => ['version' => '2.0', 'generator' => 'Vuuro Scan'],
            'scene' => 0,
            'scenes' => [['nodes' => [0]]],
            'nodes' => [['mesh' => 0]],
            'meshes' => [[
                'primitives' => [[
                    'attributes' => ['POSITION' => 0, 'NORMAL' => 1, 'COLOR_0' => 2],
                    'indices' => 3,
                    'mode' => 4,
                ]],
            ]],
            'accessors' => [
                ['bufferView' => 0, 'componentType' => 5126, 'count' => $vertexCount, 'type' => 'VEC3', 'min' => $minPos, 'max' => $maxPos],
                ['bufferView' => 1, 'componentType' => 5126, 'count' => $vertexCount, 'type' => 'VEC3'],
                ['bufferView' => 2, 'componentType' => 5126, 'count' => $vertexCount, 'type' => 'VEC4'],
                ['bufferView' => 3, 'componentType' => 5125, 'count' => count($indices), 'type' => 'SCALAR'],
            ],
            'bufferViews' => [
                ['buffer' => 0, 'byteOffset' => $posOffset, 'byteLength' => $posLen, 'target' => 34962],
                ['buffer' => 0, 'byteOffset' => $nrmOffset, 'byteLength' => $nrmLen, 'target' => 34962],
                ['buffer' => 0, 'byteOffset' => $colOffset, 'byteLength' => $colLen, 'target' => 34962],
                ['buffer' => 0, 'byteOffset' => $idxOffset, 'byteLength' => $idxLen, 'target' => 34963],
            ],
            'buffers' => [['byteLength' => $binLen]],
        ];

        $json = json_encode($gltf, JSON_UNESCAPED_SLASHES);
        $jsonPad = self::align4(strlen($json)) - strlen($json);
        $json .= str_repeat(' ', $jsonPad);
        $binPad = self::align4(strlen($bin)) - strlen($bin);
        $bin .= str_repeat("\0", $binPad);

        $jsonLen = strlen($json);
        $finalBinLen = strlen($bin);
        $totalLen = 12 + 8 + $jsonLen + 8 + $finalBinLen;

        $glb = pack('V3', 0x46546C67, 2, $totalLen);
        $glb .= pack('V2', $jsonLen, 0x4E4F534A) . $json;
        $glb .= pack('V2', $finalBinLen, 0x004E4942) . $bin;
        return $glb;
    }
}
