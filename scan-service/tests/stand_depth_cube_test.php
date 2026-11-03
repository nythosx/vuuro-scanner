<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\StandDepthCube;
use VuuroScan\Export\StandSkybox;
use VuuroScan\Export\StandSkyboxStore;

$failures = 0;

function check(string $label, bool $ok, string $detail = ''): void
{
    global $failures;
    if ($ok) {
        echo "PASS $label\n";
    } else {
        fwrite(STDERR, "FAIL $label" . ($detail !== '' ? "\n  $detail" : '') . "\n");
        $failures++;
    }
}

const ROOM_MIN = [0.0, 0.0, 0.0];
const ROOM_MAX = [4.0, 2.5, 3.0];
const TABLE_MIN = [2.5, 0.0, 1.0];
const TABLE_MAX = [3.2, 0.75, 2.0];
const DEPTH_W = 256;
const DEPTH_H = 192;
const DEPTH_K = [193.0, 193.0, 128.0, 96.0];
const PHOTO_W = 128;
const PHOTO_H = 96;
const PHOTO_K = [96.5, 96.5, 64.0, 48.0];

function cameraTransform(float $yawDeg, float $pitchDeg, array $pos, bool $portrait): array
{
    $y = deg2rad($yawDeg);
    $p = deg2rad($pitchDeg);
    $f = [sin($y) * cos($p), sin($p), -cos($y) * cos($p)];
    $r = [cos($y), 0.0, sin($y)];
    $u = [$r[1] * $f[2] - $r[2] * $f[1], $r[2] * $f[0] - $r[0] * $f[2], $r[0] * $f[1] - $r[1] * $f[0]];
    $c0 = $portrait ? $u : $r;
    $c1 = $portrait ? [-$r[0], -$r[1], -$r[2]] : $u;
    $c2 = [-$f[0], -$f[1], -$f[2]];
    return [$c0[0], $c0[1], $c0[2], 0.0, $c1[0], $c1[1], $c1[2], 0.0, $c2[0], $c2[1], $c2[2], 0.0, $pos[0], $pos[1], $pos[2], 1.0];
}

function exitRoom(array $o, array $d): float
{
    $t = INF;
    for ($a = 0; $a < 3; $a++) {
        if ($d[$a] > 1e-12) {
            $t = min($t, (ROOM_MAX[$a] - $o[$a]) / $d[$a]);
        } elseif ($d[$a] < -1e-12) {
            $t = min($t, (ROOM_MIN[$a] - $o[$a]) / $d[$a]);
        }
    }
    return $t;
}

function hitTable(array $o, array $d): float
{
    $t0 = 0.0;
    $t1 = INF;
    for ($a = 0; $a < 3; $a++) {
        if (abs($d[$a]) < 1e-12) {
            if ($o[$a] < TABLE_MIN[$a] || $o[$a] > TABLE_MAX[$a]) {
                return INF;
            }
            continue;
        }
        $ta = (TABLE_MIN[$a] - $o[$a]) / $d[$a];
        $tb = (TABLE_MAX[$a] - $o[$a]) / $d[$a];
        $t0 = max($t0, min($ta, $tb));
        $t1 = min($t1, max($ta, $tb));
    }
    return $t0 <= $t1 ? $t0 : INF;
}

function syntheticDepth(array $m, bool $withTable = true): string
{
    [$fx, $fy, $cx, $cy] = DEPTH_K;
    $o = [$m[12], $m[13], $m[14]];
    $out = [];
    for ($v = 0; $v < DEPTH_H; $v++) {
        $b = -($v + 0.5 - $cy) / $fy;
        for ($u = 0; $u < DEPTH_W; $u++) {
            $a = ($u + 0.5 - $cx) / $fx;
            $d = [
                $m[0] * $a + $m[4] * $b - $m[8],
                $m[1] * $a + $m[5] * $b - $m[9],
                $m[2] * $a + $m[6] * $b - $m[10],
            ];
            $t = exitRoom($o, $d);
            if ($withTable) {
                $t = min($t, hitTable($o, $d));
            }
            $out[] = $t > 0 && $t < 5.0 ? (int) round($t * 1000) : 0;
        }
    }
    return pack('v*', ...$out);
}

function standPhotos(array $center, string $prefix = 'p', bool $withTable = true): array
{
    $poses = [];
    for ($i = 0; $i < 12; $i++) {
        $poses[] = [$i * 30.0, 0.0];
    }
    for ($i = 0; $i < 6; $i++) {
        $poses[] = [$i * 60.0 + 15, 45.0];
        $poses[] = [$i * 60.0 + 15, -45.0];
    }
    $poses[] = [0.0, 80.0];
    $poses[] = [0.0, -80.0];
    $sources = [];
    foreach ($poses as $n => [$yaw, $pitch]) {
        $y = deg2rad($yaw);
        $p = deg2rad($pitch);
        $hold = 0.3;
        $pos = [$center[0] + sin($y) * cos($p) * $hold, $center[1] + sin($p) * $hold * 0.2, $center[2] - cos($y) * cos($p) * $hold];
        $m = cameraTransform($yaw, $pitch, $pos, $n % 2 === 1);
        $photo = [
            'photo_id' => $prefix . $n,
            'url' => "https://example.test/scan-sessions/s/photo-uploads/{$prefix}{$n}.jpg",
            'heading_deg' => $yaw,
            'pitch_deg' => $pitch,
            'zoom' => 1,
            'camera_transform' => $m,
            'intrinsics' => PHOTO_K,
            'has_depth' => true,
            'depth_width' => DEPTH_W,
            'depth_height' => DEPTH_H,
            'depth_intrinsics' => DEPTH_K,
        ];
        $sources[] = ['photo' => $photo, 'bytes' => syntheticDepth($m, $withTable)];
    }
    return $sources;
}

function sampleCube(string $bytes, int $size, array $dir): float
{
    [$px, $py, $pz] = $dir;
    $qx = abs($px);
    $qy = abs($py);
    $qz = abs($pz);
    if ($qx >= $qy && $qx >= $qz) {
        [$f, $s, $t] = $px > 0 ? [1, $pz / $qx, $py / $qx] : [3, -$pz / $qx, $py / $qx];
    } elseif ($qy >= $qz) {
        [$f, $s, $t] = $py > 0 ? [4, $px / $qy, $pz / $qy] : [5, $px / $qy, -$pz / $qy];
    } else {
        [$f, $s, $t] = $pz < 0 ? [0, $px / $qz, $py / $qz] : [2, -$px / $qz, $py / $qz];
    }
    $gx = min($size - 1, max(0, (int) (($s + 1) * $size / 2)));
    $gy = min($size - 1, max(0, (int) ((1 - $t) * $size / 2)));
    $offset = ((($f * $size) + $gy) * $size + $gx) * 2;
    return unpack('v', substr($bytes, $offset, 2))[1] / 1000;
}

function traceHit(array $o, array $d): array
{
    $t = INF;
    $hit = '';
    $names = [['x0', 'x1'], ['floor', 'ceil'], ['z0', 'z1']];
    for ($a = 0; $a < 3; $a++) {
        if ($d[$a] > 1e-12 && ($c = (ROOM_MAX[$a] - $o[$a]) / $d[$a]) < $t) {
            $t = $c;
            $hit = $names[$a][1];
        } elseif ($d[$a] < -1e-12 && ($c = (ROOM_MIN[$a] - $o[$a]) / $d[$a]) < $t) {
            $t = $c;
            $hit = $names[$a][0];
        }
    }
    $table = hitTable($o, $d);
    if ($table < $t) {
        $p = [$o[0] + $d[0] * $table, $o[1] + $d[1] * $table, $o[2] + $d[2] * $table];
        return [$table, abs($p[1] - TABLE_MAX[1]) < 1e-6 ? 'top' : 'side'];
    }
    return [$t, $hit];
}

function shadeAt(array $o, array $d): array
{
    [$t, $hit] = traceHit($o, $d);
    $x = $o[0] + $d[0] * $t;
    $y = $o[1] + $d[1] * $t;
    $z = $o[2] + $d[2] * $t;
    if ($hit === 'floor') {
        return ((int) floor($x * 2) + (int) floor($z * 2)) % 2 === 0 ? [196, 160, 112] : [110, 80, 50];
    }
    if ($hit === 'ceil') {
        return [236, 236, 230];
    }
    if ($hit === 'top') {
        return [200, 40, 40];
    }
    if ($hit === 'side') {
        return [110, 20, 20];
    }
    $c = match ($hit) {
        'x0' => [80, 120, 200],
        'x1' => [90, 180, 110],
        'z0' => [220, 200, 90],
        default => [210, 130, 170],
    };
    $along = $hit === 'x0' || $hit === 'x1' ? $z : $x;
    $stripe = abs($along * 2 - round($along * 2)) < 0.06 || abs($y - 1.0) < 0.03;
    return $stripe ? [(int) ($c[0] * 0.4), (int) ($c[1] * 0.4), (int) ($c[2] * 0.4)] : $c;
}

function photoJpeg(array $m, float $brightness = 1.0): string
{
    [$fx, $fy, $cx, $cy] = PHOTO_K;
    $im = imagecreatetruecolor(PHOTO_W, PHOTO_H);
    $o = [$m[12], $m[13], $m[14]];
    $pose = StandSkybox::pose(['camera_transform' => $m]);
    $f = $pose['fwd'];
    $r = $pose['right'];
    $up = $pose['up'];
    for ($v = 0; $v < PHOTO_H; $v++) {
        $b = -($v + 0.5 - $cy) / $fy;
        for ($u = 0; $u < PHOTO_W; $u++) {
            $a = ($u + 0.5 - $cx) / $fx;
            $c = shadeAt($o, [$f[0] + $r[0] * $a + $up[0] * $b, $f[1] + $r[1] * $a + $up[1] * $b, $f[2] + $r[2] * $a + $up[2] * $b]);
            $c = array_map(static fn (int $ch): int => min(255, (int) round($ch * $brightness)), $c);
            imagesetpixel($im, $u, $v, ($c[0] << 16) | ($c[1] << 8) | $c[2]);
        }
    }
    ob_start();
    imagejpeg($im, null, 95);
    return (string) ob_get_clean();
}

function skyboxError(array $faces, int $size, array $eye): float
{
    $sum = 0.0;
    $n = 0;
    foreach (StandSkybox::FACES as $face) {
        $basis = StandSkybox::faceBasis($face);
        $im = imagecreatefromstring($faces[$face]);
        for ($y = 0; $y < $size; $y += 2) {
            $v = 1 - 2 * ($y + 0.5) / $size;
            for ($x = 0; $x < $size; $x += 2) {
                $s = 2 * ($x + 0.5) / $size - 1;
                $d = [
                    $basis['fwd'][0] + $basis['right'][0] * $s + $basis['up'][0] * $v,
                    $basis['fwd'][1] + $basis['right'][1] * $s + $basis['up'][1] * $v,
                    $basis['fwd'][2] + $basis['right'][2] * $s + $basis['up'][2] * $v,
                ];
                $truth = shadeAt($eye, $d);
                $c = imagecolorat($im, $x, $y);
                $sum += (abs((($c >> 16) & 255) - $truth[0]) + abs((($c >> 8) & 255) - $truth[1]) + abs(($c & 255) - $truth[2])) / 3;
                $n++;
            }
        }
    }
    return $sum / max(1, $n);
}

$eye = [1.5, 1.4, 1.5];
$sources = standPhotos($eye);
$photos = array_map(static fn (array $s): array => $s['photo'], $sources);

echo "== center ==\n";
$center = StandDepthCube::center([1.5, 1.5], $photos);
check('center keeps the stand x/z', $center[0] === 1.5 && $center[2] === 1.5);
check('center height is the median camera height', abs($center[1] - 1.4) < 0.05, 'got ' . $center[1]);
check('center falls back to 1.4 m without poses', StandDepthCube::center([0, 0], [['camera_transform' => null]])[1] === 1.4);

echo "== usable ==\n";
check('usable accepts a well-formed photo', StandDepthCube::usable($photos[0], $sources[0]['bytes']));
check('usable rejects a short depth file', !StandDepthCube::usable($photos[0], substr($sources[0]['bytes'], 2)));
check('usable rejects missing depth intrinsics', !StandDepthCube::usable(array_merge($photos[0], ['depth_intrinsics' => null]), $sources[0]['bytes']));

echo "== render ==\n";
$started = microtime(true);
$cube = StandDepthCube::render($sources, $eye);
$elapsed = microtime(true) - $started;
echo sprintf("  rendered %d photos in %.2fs, measured %.3f, coverage %.3f\n", $cube['photos'], $elapsed, $cube['measured'], $cube['coverage']);
$size = $cube['size'];
check('cube is 256 px per face', $size === 256);
check('cube bytes are 6 faces of UInt16', strlen($cube['bytes']) === 6 * $size * $size * 2);
check('all 26 photos were used', $cube['photos'] === 26);
check('coverage is above 95 %', $cube['coverage'] > 0.95, 'got ' . $cube['coverage']);
check('center_m is reported', $cube['center_m'] === [1.5, 1.4, 1.5]);

$cases = [
    'front wall (z=0)' => [[0, 0, -1], 1.5],
    'right wall (x=4)' => [[1, 0, 0], 2.5],
    'back wall (z=3)' => [[0, 0, 1], 1.5],
    'left wall (x=0)' => [[-1, 0, 0], 1.5],
    'ceiling' => [[0, 1, 0], 1.1],
    'floor' => [[0, -1, 0], 1.4],
];
foreach ($cases as $label => [$dir, $expected]) {
    $got = sampleCube($cube['bytes'], $size, $dir);
    check("distance to $label", abs($got - $expected) < 0.03, "expected $expected, got $got");
}

$toTable = [2.85 - 1.5, 0.75 - 1.4, 1.5 - 1.5];
$tableDistance = sqrt($toTable[0] ** 2 + $toTable[1] ** 2 + $toTable[2] ** 2);
$gotTable = sampleCube($cube['bytes'], $size, $toTable);
check('table top is in the cube, not the wall behind it', abs($gotTable - $tableDistance) < 0.05, "expected $tableDistance, got $gotTable");

$diag = [1, -0.4, -1];
$len = sqrt(1 + 0.16 + 1);
$t = min(2.5 / 1, 1.4 / 0.4, 1.5 / 1);
$gotDiag = sampleCube($cube['bytes'], $size, $diag);
check('face corner direction lands on the right surface', abs($gotDiag - $t * $len) < 0.05, 'expected ' . ($t * $len) . ", got $gotDiag");

echo "== holes ==\n";
$blank = array_map(static fn (array $s): array => ['photo' => $s['photo'], 'bytes' => str_repeat("\0", DEPTH_W * DEPTH_H * 2)], $sources);
$empty = StandDepthCube::render($blank, $eye);
check('all-zero depth gives no coverage', $empty['coverage'] === 0.0 && $empty['measured'] === 0.0);
check('a cube below MIN_COVERAGE is not offered', StandSkyboxStore::usableDepth(['depth_version' => StandDepthCube::VERSION, 'depth' => ['size' => 256, 'center_m' => [0, 0, 0], 'coverage' => 0.1]]) === null);
check('a cube from an older version is not offered', StandSkyboxStore::usableDepth(['depth_version' => 'depth-0', 'depth' => ['size' => 256, 'center_m' => [0, 0, 0], 'coverage' => 0.9]]) === null);

echo "== exposure gains ==\n";
$obs = [];
for ($k = 0; $k < 50; $k++) {
    $base = log(80 + $k);
    $obs[] = [[0, $base], [1, $base + log(1.4)], [2, $base]];
}
$solved = StandSkybox::exposureGainsFor($obs, 3);
check('a photo 1.4x brighter gets a gain near 1/1.4 of the others', abs($solved[1] / $solved[0] - 1 / 1.4) < 0.03, json_encode($solved));
check('equal photos keep equal gains', abs($solved[0] - $solved[2]) < 1e-6);
$clamped = StandSkybox::exposureGainsFor([[[0, 0.0], [1, 5.0]]], 2);
check('gains are clamped', min($clamped) >= StandSkybox::GAIN_MIN - 1e-9 && max($clamped) <= StandSkybox::GAIN_MAX + 1e-9);

echo "== hole filling ==\n";
$im = imagecreatetruecolor(64, 64);
imagefill($im, 0, 0, 0x000000);
$mask = str_repeat("\1", 64 * 64);
for ($y = 0; $y < 64; $y++) {
    for ($x = 0; $x < 64; $x++) {
        if ($x < 24 || $y < 8) {
            imagesetpixel($im, $x, $y, $x < 24 ? 0xC04020 : 0x2040C0);
            $mask[$y * 64 + $x] = "\0";
        }
    }
}
StandSkybox::fillHoles($im, 64, $mask);
$near = imagecolorat($im, 25, 40);
$far = imagecolorat($im, 60, 60);
check('a hole next to red is filled with red', (($near >> 16) & 255) > 150 && ($near & 255) < 90, sprintf('%06x', $near));
check('a hole far from the edges is filled with a blend, not black', $far !== 0 && (($far >> 16) & 255) > 40 && ($far & 255) > 40, sprintf('%06x', $far));
check('known pixels are untouched', imagecolorat($im, 10, 40) === 0xC04020);

echo "== stitch quality ==\n";
$jpegs = [];
foreach ($sources as $source) {
    $jpegs[$source['photo']['photo_id']] = photoJpeg($source['photo']['camera_transform']);
}
$stitchSources = array_map(static fn (array $s): array => ['photo' => $s['photo'], 'bytes' => $jpegs[$s['photo']['photo_id']], 'depth' => $s['bytes']], $sources);
$face = 128;
$started = microtime(true);
$withDepth = StandSkybox::render($stitchSources, $face, ['size' => $cube['size'], 'values' => $cube['values'], 'center' => $cube['center_m']]);
$depthSeconds = microtime(true) - $started;
$started = microtime(true);
$withoutDepth = StandSkybox::render($stitchSources, $face, null);
$plainSeconds = microtime(true) - $started;
$errDepth = skyboxError($withDepth['faces'], $face, $eye);
$errPlain = skyboxError($withoutDepth['faces'], $face, $eye);
echo sprintf("  mean colour error: with depth %.1f (%.1fs), rotation only %.1f (%.1fs)\n", $errDepth, $depthSeconds, $errPlain, $plainSeconds);
check('depth-aware stitch is much closer to the true view than rotation-only', $errDepth < $errPlain * 0.6, "depth $errDepth vs plain $errPlain");
check('depth-aware stitch error is small', $errDepth < 12.0, "got $errDepth");
check('equal exposures give gains near 1', min($withDepth['gains']) > 0.93 && max($withDepth['gains']) < 1.07, json_encode($withDepth['gains']));

$bright = $stitchSources;
$bright[5]['bytes'] = photoJpeg($sources[5]['photo']['camera_transform'], 1.35);
$brightResult = StandSkybox::render($bright, 64, ['size' => $cube['size'], 'values' => $cube['values'], 'center' => $cube['center_m']]);
$ratio = $brightResult['gains'][5] / (array_sum($brightResult['gains']) / count($brightResult['gains']));
check('a brighter photo is toned down to match its neighbours', $ratio < 0.85 && $ratio > 0.6, "ratio $ratio");

echo "== store ==\n";
$root = sys_get_temp_dir() . '/vuuro-depth-test-' . bin2hex(random_bytes(4));
$photoDir = $root . '/photos';
mkdir($photoDir, 0775, true);
foreach ($sources as $source) {
    file_put_contents($photoDir . '/' . $source['photo']['photo_id'] . '.jpg', $jpegs[$source['photo']['photo_id']]);
    file_put_contents($photoDir . '/' . $source['photo']['photo_id'] . '.depth', $source['bytes']);
}
$photoPath = static function (string $url) use ($photoDir): ?string {
    $path = $photoDir . '/' . basename((string) parse_url($url, PHP_URL_PATH));
    return is_file($path) ? $path : null;
};
$store = new StandSkyboxStore($root . '/skybox');
$stands = ['r1' => [['stand_id' => 'st1', 'photo_ids' => array_map(static fn (array $p): string => $p['photo_id'], $photos), 'center_m' => [1.5, 1.5]]]];
$byRoom = ['r1' => $photos];

$plan = $store->plan('s', $stands, $byRoom, $photoPath);
check('a new stand is pending with its center', count($plan['pending']) === 1 && $plan['pending'][0]['center_m'] === [1.5, 1.5]);
$key = $plan['pending'][0]['key'];

$legacyStore = new StandSkyboxStore($root . '/skybox-legacy');
check('a build without a center still works', $legacyStore->build('s', 'r1', 'st1', $key, $photos, $photoPath, null));
$legacy = $legacyStore->plan('s', $stands, $byRoom, $photoPath);
check('a skybox built without a center is offered without depth', array_key_exists('depth', $legacy['ready']['r1'][0] ?? []) && $legacy['ready']['r1'][0]['depth'] === null);
check('it is not rebuilt on every tour request', $legacy['pending'] === []);
$legacyStore->deleteSession('s');
@rmdir($root . '/skybox-legacy');

$started = microtime(true);
check('build with depth succeeds', $store->build('s', 'r1', 'st1', $key, $photos, $photoPath, [1.5, 1.5]));
echo sprintf("  store build took %.1fs\n", microtime(true) - $started);
$meta = json_decode((string) file_get_contents($root . '/skybox/s/' . $key . '/meta.json'), true);
check('meta records the stitch version and gains', ($meta['version'] ?? null) === StandSkybox::VERSION && count($meta['gains'] ?? []) === 26);
$after = $store->plan('s', $stands, $byRoom, $photoPath);
$offered = $after['ready']['r1'][0]['depth'] ?? null;
check('nothing left to build', $after['pending'] === []);
check('tour gets depth size and center', is_array($offered) && $offered['size'] === 256 && abs($offered['center_m'][1] - 1.4) < 0.05);
$depthPath = $store->depthPath('s', $key);
check('depth file is stored gzipped', $depthPath !== null && str_ends_with($depthPath, '.gz'));
$raw = $depthPath !== null ? gzdecode((string) file_get_contents($depthPath)) : false;
check('stored depth decodes to the full cube', is_string($raw) && strlen($raw) === 6 * 256 * 256 * 2);
check('stored depth matches the front wall', is_string($raw) && abs(sampleCube($raw, 256, [0, 0, -1]) - 1.5) < 0.03);
check('depthPath rejects a bad key', $store->depthPath('s', '../etc') === null);

$noDepthPhotos = array_map(static fn (array $p): array => array_merge($p, ['has_depth' => false]), $photos);
$fresh = new StandSkyboxStore($root . '/skybox2');
$freshKey = $fresh->keyFor($noDepthPhotos, $photoPath);
check('full build for photos without depth succeeds', $fresh->build('s', 'r1', 'st1', $freshKey, $noDepthPhotos, $photoPath, [1.5, 1.5]));
$freshPlan = $fresh->plan('s', $stands, ['r1' => $noDepthPhotos], $photoPath);
check('photos without depth are not retried', $freshPlan['pending'] === [] && array_key_exists('depth', $freshPlan['ready']['r1'][0] ?? []) && $freshPlan['ready']['r1'][0]['depth'] === null);

$fresh->deleteSession('s');
$store->deleteSession('s');
array_map('unlink', glob($photoDir . '/*') ?: []);
@rmdir($photoDir);
@rmdir($root . '/skybox');
@rmdir($root . '/skybox2');
@rmdir($root);

if ($failures > 0) {
    fwrite(STDERR, "\n$failures failure(s)\n");
    exit(1);
}
echo "\nAll stand depth cube checks passed.\n";
