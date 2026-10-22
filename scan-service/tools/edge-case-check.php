<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\DollhouseGltfWriter;
use VuuroScan\Export\FusionOverlapDetector;
use VuuroScan\Export\WallTextureProjection;

$failures = 0;
$checks = 0;

function check(string $label, callable $fn): void {
    global $checks, $failures;
    $checks++;
    try {
        $fn();
        echo "  [PASS] $label\n";
    } catch (\Throwable $e) {
        $failures++;
        echo "  [FAIL] $label\n         " . get_class($e) . ': ' . $e->getMessage() . "\n";
    }
}
function eq(mixed $expected, mixed $actual, string $what = ''): void {
    if ($expected !== $actual) {
        throw new \RuntimeException(($what !== '' ? "$what: " : '')
            . 'expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
    }
}
function isNull(mixed $v, string $what): void {
    if ($v !== null) throw new \RuntimeException("$what: expected null, got " . var_export($v, true));
}
function notNull(mixed $v, string $what): void {
    if ($v === null) throw new \RuntimeException("$what: expected non-null");
}
function throws(callable $fn, string $what): void {
    try { $fn(); } catch (\Throwable) { return; }
    throw new \RuntimeException("$what: expected an exception");
}

function makeJpeg(int $w, int $h): string {
    $img = imagecreatetruecolor($w, $h);
    $fill = imagecolorallocate($img, 200, 100, 50);
    imagefilledrectangle($img, 0, 0, $w, $h, $fill);
    ob_start();
    imagejpeg($img, null, 85);
    $bytes = (string) ob_get_clean();
    imagedestroy($img);
    return $bytes;
}

function glbImages(string $glb): array {
    if (unpack('V', substr($glb, 0, 4))[1] !== 0x46546C67) {
        throw new \RuntimeException('not a GLB');
    }
    $total = unpack('V', substr($glb, 8, 4))[1];
    $offset = 12; $json = null; $bin = null;
    while ($offset + 8 <= $total) {
        $len  = unpack('V', substr($glb, $offset, 4))[1];
        $type = unpack('V', substr($glb, $offset + 4, 4))[1];
        $data = substr($glb, $offset + 8, $len);
        if ($type === 0x4E4F534A) $json = $data;
        elseif ($type === 0x004E4942) $bin = $data;
        $offset += 8 + $len;
    }
    if ($json === null || $bin === null) throw new \RuntimeException('GLB missing chunk');
    $gltf = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
    $images = [];
    foreach ($gltf['images'] ?? [] as $img) {
        $view = $gltf['bufferViews'][$img['bufferView']];
        $bytes = substr($bin, $view['byteOffset'], $view['byteLength']);
        $info = @getimagesizefromstring($bytes);
        $images[] = [
            'mime'   => $img['mimeType'] ?? '',
            'width'  => is_array($info) ? (int) $info[0] : 0,
            'height' => is_array($info) ? (int) $info[1] : 0,
        ];
    }
    return $images;
}

function roomPlan(string $id = 'room-1'): array {
    return [
        'room_id' => $id,
        'outline_m' => [[0,0],[4,0],[4,3],[0,3]],
        'height_m' => 2.6,
        'heading_deg' => 0.0,
        'openings' => [],
        'floor_area_m2' => 12.0,
    ];
}

function photo360(array $position = [2.0, 2.0], float $heading = 180.0, string $url = 'test://p.jpg'): array {
    return [
        'photo_id' => 'p1',
        'room_id' => 'room-1',
        'url' => $url,
        'position_m' => $position,
        'heading_deg' => $heading,
    ];
}

function overlapRoom(string $id, array $outline, array $origin = [0, 0]): array {
    return ['room_id' => $id, 'outline_m' => $outline, 'structure_origin_m' => $origin];
}

echo "\n== 1. WallTextureProjection ==\n";

$wallA = [0, 0]; $wallB = [4, 0]; $inward = [0, 1];

check('no photos -> null', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, []), 'no photos'));

check('photo missing position_m -> skipped', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, [['heading_deg' => 180.0]]), 'missing position'));

check('photo missing heading_deg -> skipped', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, [['position_m' => [2, 2]]]), 'missing heading'));

check('NAN heading -> skipped, no crash', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [['position_m' => [2, 2], 'heading_deg' => NAN]]), 'NAN heading'));

check('non-numeric position -> skipped, no crash', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [['position_m' => ['x', 'y'], 'heading_deg' => 180.0]]), 'non-numeric position'));

check('head-on photo -> wall picked', fn () => notNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [photo360([2, 2], 180)]), 'head-on'));

check('looking away -> null', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [photo360([2, 2], 0)]), 'looking away'));

check('perpendicular -> null', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [photo360([2, 2], 90)]), 'perpendicular'));

// The 60-degree heading filter (dot <= -0.5) and the 60-degree horizontal FOV
// combine to give an effective "wall midpoint picked" boundary of ~30 degrees
// off-perpendicular: beyond that, a wall long enough to satisfy
// MAX_WALL_LENGTH_PER_SPAN has a midpoint that projects outside the frame,
// so the FOV filter rejects before the heading filter can be isolated. Test
// the effective boundary instead.
check('29 degrees off-perpendicular -> wall picked', fn () => notNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [photo360([2, 2.5], 209)]), '29 degrees'));

check('31 degrees off-perpendicular -> rejected (wall midpoint out of FOV)', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [photo360([2, 2.5], 211)]), '31 degrees'));

check('61 degrees off (dot > -0.5) -> skipped', fn () => isNull(
    WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5,
        [photo360([2, 2], 241)]), '61 degrees'));

check('multiple photos: head-on wins', function () use ($wallA, $wallB, $inward) {
    $best = WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, [
        photo360([2, 2], 90), photo360([2, 2], 180),
    ]);
    notNull($best, 'best-match');
    eq(180.0, $best['heading_deg'], 'best should be the head-on one');
});

check('projectPoint behind camera -> null', fn () => isNull(
    WallTextureProjection::projectPointRaw(photo360([0, 0], 0), 0.0, 0.0, 1.5, -5.0), 'behind'));

check('projectPoint closer than MIN_DEPTH -> null', fn () => isNull(
    WallTextureProjection::projectPointRaw(photo360([0, 0], 0), 0.0, 0.0, 1.5, 0.05), 'too close'));

check('projectPoint outside FOV -> null', fn () => isNull(
    WallTextureProjection::projectPoint(photo360([0, 0], 0), 0.0, -50.0, 1.5, 5.0), 'outside FOV'));

check('projectPoint at frame centre -> u=0.5', function () {
    $uv = WallTextureProjection::projectPoint(photo360([0, 0], 0), 0.0, 0.0, 1.5, 5.0);
    notNull($uv, 'in-frame');
    eq(0.5, round($uv[0], 6), 'u centre');
});

echo "\n== 2. FusionOverlapDetector ==\n";

check('empty rooms -> []', fn () => eq([], FusionOverlapDetector::detect([])));
check('single room -> []', fn () => eq([], FusionOverlapDetector::detect([
    overlapRoom('r1', [[0,0],[4,0],[4,3],[0,3]]),
])));
check('two non-overlapping -> []', fn () => eq([], FusionOverlapDetector::detect([
    overlapRoom('r1', [[0,0],[4,0],[4,3],[0,3]]),
    overlapRoom('r2', [[5,0],[9,0],[9,3],[5,3]]),
])));

check('~14% overlap -> not flagged', function () {
    $r = FusionOverlapDetector::detect([
        overlapRoom('r1', [[0,0],[10,0],[10,10],[0,10]]),
        overlapRoom('r2', [[8.6,0],[18.6,0],[18.6,10],[8.6,10]]),
    ]);
    eq([], $r, '14%');
});
check('~16% overlap -> both flagged', function () {
    $r = FusionOverlapDetector::detect([
        overlapRoom('r1', [[0,0],[10,0],[10,10],[0,10]]),
        overlapRoom('r2', [[8.4,0],[18.4,0],[18.4,10],[8.4,10]]),
    ]);
    sort($r); eq([0, 1], $r, '16%');
});
check('identical rooms -> both flagged', function () {
    $r = FusionOverlapDetector::detect([
        overlapRoom('r1', [[0,0],[4,0],[4,3],[0,3]]),
        overlapRoom('r2', [[0,0],[4,0],[4,3],[0,3]]),
    ]);
    sort($r); eq([0, 1], $r, 'identical');
});
check('degenerate 2-point outline -> skipped', fn () => eq([], FusionOverlapDetector::detect([
    overlapRoom('r1', [[0,0],[4,0]]),
    overlapRoom('r2', [[0,0],[4,0],[4,3],[0,3]]),
])));
check('collinear 3-point outline -> skipped', fn () => eq([], FusionOverlapDetector::detect([
    overlapRoom('r1', [[0,0],[1,0],[2,0]]),
    overlapRoom('r2', [[0,0],[4,0],[4,3],[0,3]]),
])));
check('A-B and B-C overlap -> all three flagged', function () {
    $r = FusionOverlapDetector::detect([
        overlapRoom('A', [[0,0],[4,0],[4,3],[0,3]]),
        overlapRoom('B', [[3,0],[7,0],[7,3],[3,3]]),
        overlapRoom('C', [[6,0],[10,0],[10,3],[6,3]]),
    ]);
    sort($r); eq([0, 1, 2], $r, 'A-B, B-C');
});
check('L-shaped concave overlap -> flagged', function () {
    $lShape = [[0,0],[6,0],[6,1],[1,1],[1,6],[0,6]];
    $r = FusionOverlapDetector::detect([
        overlapRoom('r1', $lShape),
        overlapRoom('r2', [[0.5,0.5],[6.5,0.5],[6.5,6.5],[0.5,6.5]]),
    ]);
    sort($r); eq([0, 1], $r, 'L-shape');
});

echo "\n== 3. DollhouseGltfWriter ==\n";

$writer = new DollhouseGltfWriter();

check('empty rooms -> throws', fn () => throws(
    fn () => $writer->write(['rooms' => []]), 'empty rooms'));

check('no photos -> flat GLB, zero textures', function () use ($writer) {
    $glb = $writer->write(['rooms' => [roomPlan()]]);
    eq(0, count(glbImages($glb)), 'no textures');
});

check('loader returns null -> photo skipped', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => null);
    eq(0, count(glbImages($glb)), 'null loader');
});

check('loader returns garbage -> photo skipped', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => 'not an image');
    eq(0, count(glbImages($glb)), 'garbage loader');
});

check('800x800 JPEG -> unchanged', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => makeJpeg(800, 800));
    $i = glbImages($glb); eq(1, count($i), 'one texture');
    eq(800, $i[0]['width'], 'width');
    eq(800, $i[0]['height'], 'height');
});

check('1600x1600 JPEG (at cap) -> unchanged', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => makeJpeg(1600, 1600));
    $i = glbImages($glb);
    eq(1600, $i[0]['width'], 'width');
    eq(1600, $i[0]['height'], 'height');
});

check('1601x1601 JPEG (1 past cap) -> downsampled to 1600', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => makeJpeg(1601, 1601));
    $i = glbImages($glb);
    eq(1600, $i[0]['width'], 'width');
    eq(1600, $i[0]['height'], 'height');
});

check('4000x2000 JPEG -> 1600x800 (aspect preserved)', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => makeJpeg(4000, 2000));
    $i = glbImages($glb);
    eq(1600, $i[0]['width'], 'width');
    eq(800, $i[0]['height'], 'height');
});

check('GIF bytes (unsupported) -> photo skipped', function () use ($writer) {
    $img = imagecreatetruecolor(100, 100);
    ob_start(); imagegif($img); $gif = (string) ob_get_clean(); imagedestroy($img);
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360()]],
        fn () => $gif);
    eq(0, count(glbImages($glb)), 'GIF not accepted');
});

check('photo aimed north from 1m at a 4m wall -> no texture', function () use ($writer) {
    $glb = $writer->write(
        ['rooms' => [roomPlan()], 'photos_360' => [photo360([2, 2], 0)]],
        fn () => makeJpeg(800, 800));
    eq(0, count(glbImages($glb)), 'wall too wide for frame');
});

check('room heading_deg null -> flat, no textures', function () use ($writer) {
    $room = roomPlan(); $room['heading_deg'] = null;
    $glb = $writer->write(
        ['rooms' => [$room], 'photos_360' => [photo360()]],
        fn () => makeJpeg(800, 800));
    eq(0, count(glbImages($glb)), 'no heading');
});

echo "\n$failures failure(s) out of $checks check(s).\n";
echo $failures === 0 ? "VERDICT: GREEN\n" : "VERDICT: RED\n";
exit($failures === 0 ? 0 : 1);
