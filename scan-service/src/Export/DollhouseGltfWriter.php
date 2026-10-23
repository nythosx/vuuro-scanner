<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class DollhouseGltfWriter
{
    private const WALL_THICKNESS_M = 0.20;
    private const DEFAULT_HEIGHT_M = 2.4;
    private const FLOOR_COLOR = [0.90, 0.86, 0.78, 1.0];
    private const WALL_COLOR = [0.95, 0.94, 0.92, 1.0];
    private const OVERLAP_COLOR = [0.84, 0.27, 0.24, 1.0];
    private const MAX_OPENING_WALL_DISTANCE_M = 0.6;
    private const MAX_TRIANGLES = 150000;
    private const MAX_TEXTURE_EDGE_PX = 1600;

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
        $placements = self::placements($rooms);

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
            self::appendRoomTextured($room, $placements[$i], $roomPhotos, $photoLoader, $isOverlap, $flat, $texturedWalls);

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

        return self::packGlbMulti($flat, $texturedWalls);
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

    private static function appendRoomTextured(
        array $room,
        array $placement,
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
        [$ox, $oz] = $placement;
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
        self::appendFloorToBucket($outline, $ox, $oz, $floorColor, $flat);
        self::appendWallsTextured($outline, $ox, $oz, $height, $openings, $headingDeg, $photosWithBytes, $isOverlap, $wallColor, $flat, $texturedWalls);
    }

    private static function appendFloorToBucket(array $outline, float $ox, float $oz, array $floorColor, array &$flat): void
    {
        $triangles = self::triangulate($outline);
        if ($triangles === []) {
            return;
        }
        $base = intdiv(count($flat['positions']), 3);
        foreach ($outline as $p) {
            $flat['positions'][] = $p[0] + $ox;
            $flat['positions'][] = 0.0;
            $flat['positions'][] = $p[1] + $oz;
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
        float $ox,
        float $oz,
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

            foreach (self::wallSegments($a, $len, $ux, $uz, $openings) as $seg) {
                $pa = [$a[0] + $ux * $seg[0], $a[1] + $uz * $seg[0]];
                $pb = [$a[0] + $ux * $seg[1], $a[1] + $uz * $seg[1]];
                self::appendWallBoxToBuckets(
                    $pa, $pb, $ux, $uz, $nx, $nz, $height, $ox, $oz,
                    $wallPhoto, $headingDeg, $wallColor, $flat, $texturedWalls
                );
            }
        }
    }

    private static function appendWallBoxToBuckets(
        array $a,
        array $b,
        float $ux,
        float $uz,
        float $nx,
        float $nz,
        float $height,
        float $ox,
        float $oz,
        ?array $wallPhoto,
        ?float $headingDeg,
        array $wallColor,
        array &$flat,
        array &$texturedWalls
    ): void {
        $half = self::WALL_THICKNESS_M / 2;
        $iA0 = [$a[0] + $nx * $half + $ox, 0.0, $a[1] + $nz * $half + $oz];
        $iB0 = [$b[0] + $nx * $half + $ox, 0.0, $b[1] + $nz * $half + $oz];
        $iAh = [$a[0] + $nx * $half + $ox, $height, $a[1] + $nz * $half + $oz];
        $iBh = [$b[0] + $nx * $half + $ox, $height, $b[1] + $nz * $half + $oz];
        $oA0 = [$a[0] - $nx * $half + $ox, 0.0, $a[1] - $nz * $half + $oz];
        $oB0 = [$b[0] - $nx * $half + $ox, 0.0, $b[1] - $nz * $half + $oz];
        $oAh = [$a[0] - $nx * $half + $ox, $height, $a[1] - $nz * $half + $oz];
        $oBh = [$b[0] - $nx * $half + $ox, $height, $b[1] - $nz * $half + $oz];

        $uvs = null;
        if ($wallPhoto !== null && $headingDeg !== null) {
            $localA0 = [$a[0] + $nx * $half, 0.0, $a[1] + $nz * $half];
            $localB0 = [$b[0] + $nx * $half, 0.0, $b[1] + $nz * $half];
            $localBh = [$b[0] + $nx * $half, $height, $b[1] + $nz * $half];
            $localAh = [$a[0] + $nx * $half, $height, $a[1] + $nz * $half];
            $uvs = self::wallFaceUvs($wallPhoto, $headingDeg, [$localA0, $localB0, $localBh, $localAh]);
        }

        if ($uvs !== null) {
            $bucket = [
                'positions' => [],
                'normals' => [],
                'uvs' => [],
                'indices' => [],
                'imageBytes' => $wallPhoto['imageBytes'],
                'imageMime' => $wallPhoto['imageMime'],
                'photoId' => $wallPhoto['photo_id'] ?? '',
            ];
            self::appendQuadToBucket($bucket, [$iA0, $iB0, $iBh, $iAh], [$nx, 0.0, $nz], $wallColor, $uvs);
            $texturedWalls[] = $bucket;
        } else {
            self::appendQuadToBucket($flat, [$iA0, $iB0, $iBh, $iAh], [$nx, 0.0, $nz], $wallColor, null);
        }

        self::appendQuadToBucket($flat, [$oA0, $oB0, $oBh, $oAh], [-$nx, 0.0, -$nz], $wallColor, null);
        self::appendQuadToBucket($flat, [$iA0, $oA0, $oB0, $iB0], [0.0, -1.0, 0.0], $wallColor, null);
        self::appendQuadToBucket($flat, [$iAh, $oAh, $oBh, $iBh], [0.0, 1.0, 0.0], $wallColor, null);
        self::appendQuadToBucket($flat, [$iA0, $oA0, $oAh, $iAh], [-$ux, 0.0, -$uz], $wallColor, null);
        self::appendQuadToBucket($flat, [$iB0, $oB0, $oBh, $iBh], [$ux, 0.0, $uz], $wallColor, null);
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

    private static function packGlbMulti(array $flat, array $texturedWalls): string
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
            'scenes' => [['nodes' => [0]]],
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
