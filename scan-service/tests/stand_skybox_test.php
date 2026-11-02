<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\StandSkybox;
use VuuroScan\Export\StandSkyboxStore;

$failures = 0;

function check(string $label, mixed $actual, mixed $expected): void
{
    global $failures;
    if ($actual !== $expected) {
        fwrite(STDERR, "FAIL $label\n  expected: " . var_export($expected, true) . "\n  actual:   " . var_export($actual, true) . "\n");
        $failures++;
    } else {
        echo "PASS $label\n";
    }
}

function near(array $a, array $b, float $eps = 1e-6): bool
{
    foreach ($a as $i => $v) {
        if (abs($v - $b[$i]) > $eps) {
            return false;
        }
    }
    return true;
}

function solidJpeg(int $w, int $h, int $rgb): string
{
    $im = imagecreatetruecolor($w, $h);
    imagefill($im, 0, 0, $rgb);
    ob_start();
    imagejpeg($im, null, 95);
    return (string) ob_get_clean();
}

function facing(string $id, float $heading, string $url = ''): array
{
    return [
        'photo_id' => $id,
        'url' => $url,
        'heading_deg' => $heading,
        'pitch_deg' => 0,
        'zoom' => 1,
        'camera_transform' => null,
        'intrinsics' => [32.0, 32.0, 32.0, 32.0],
    ];
}

function centre(string $jpeg): array
{
    $im = imagecreatefromstring($jpeg);
    $c = imagecolorat($im, intdiv(imagesx($im), 2), intdiv(imagesy($im), 2));
    return [($c >> 16) & 255, ($c >> 8) & 255, $c & 255];
}

function close(array $rgb, array $want, int $tol): bool
{
    for ($i = 0; $i < 3; $i++) {
        if (abs($rgb[$i] - $want[$i]) > $tol) {
            return false;
        }
    }
    return true;
}

echo "== Face bases are right-handed and match the viewer ==\n";
foreach (StandSkybox::FACES as $face) {
    $b = StandSkybox::faceBasis($face);
    $r = $b['right'];
    $u = $b['up'];
    $cross = [$r[1] * $u[2] - $r[2] * $u[1], $r[2] * $u[0] - $r[0] * $u[2], $r[0] * $u[1] - $r[1] * $u[0]];
    check("face {$face}: right x up = -fwd", near($cross, array_map(static fn (float $v): float => -$v, $b['fwd'])), true);
}

echo "\n== Pose matches the viewer for a scan camera transform ==\n";
$pose = StandSkybox::pose(['camera_transform' => [0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 4.5, 1.4, 2.2, 1]]);
check('landscape camera looks north', near($pose['fwd'], [0.0, 0.0, -1.0]), true);
check('landscape camera right is east', near($pose['right'], [1.0, 0.0, 0.0]), true);
check('landscape camera up is up', near($pose['up'], [0.0, 1.0, 0.0]), true);
$east = StandSkybox::pose(['heading_deg' => 90, 'pitch_deg' => 0]);
check('heading 90 looks east', near($east['fwd'], [1.0, 0.0, 0.0]), true);

echo "\n== Frame from intrinsics ==\n";
$frame = StandSkybox::frame(['intrinsics' => [32.0, 32.0, 32.0, 32.0]], 64, 64);
check('square 90 degree frame', near(array_values($frame), [-1.0, 1.0, 1.0, -1.0]), true);
$scaled = StandSkybox::frame(['intrinsics' => [32.0, 32.0, 32.0, 32.0]], 128, 128);
check('intrinsics rescale to the stored image size', near(array_values($scaled), [-1.0, 1.0, 1.0, -1.0]), true);

echo "\n== Stitching puts each photo on its own face ==\n";
$warm = 0xC86432;
$sky = StandSkybox::render([
    ['photo' => facing('n', 0), 'bytes' => solidJpeg(64, 64, $warm)],
    ['photo' => facing('s', 180), 'bytes' => solidJpeg(64, 64, $warm)],
], 64);
check('six faces', array_keys($sky['faces']), StandSkybox::FACES);
check('front face shows the north photo', close(centre($sky['faces']['f']), [200, 100, 50], 8), true);
check('back face shows the south photo', close(centre($sky['faces']['b']), [200, 100, 50], 8), true);
check('uncovered ceiling is filled, not black', array_sum(centre($sky['faces']['u'])) > 150, true);
check('face size follows photo resolution', StandSkybox::faceSize([['photo' => facing('n', 0), 'width' => 64, 'height' => 64]]), StandSkybox::MIN_FACE_PX);

$threw = false;
try {
    StandSkybox::render([['photo' => facing('n', 0), 'bytes' => solidJpeg(64, 64, $warm)]], 64);
} catch (\InvalidArgumentException) {
    $threw = true;
}
check('one photo is not a 360 spot', $threw, true);

echo "\n== Cache key follows photo content ==\n";
$photos = [facing('n', 0, 'a.jpg'), facing('s', 180, 'b.jpg')];
$k1 = StandSkybox::cacheKey($photos, static fn (string $url): array => [100, 1]);
$k2 = StandSkybox::cacheKey(array_reverse($photos), static fn (string $url): array => [100, 1]);
$k3 = StandSkybox::cacheKey($photos, static fn (string $url): array => [100, 2]);
$moved = $photos;
$moved[0]['heading_deg'] = 10;
check('photo order does not matter', $k1, $k2);
check('a replaced file changes the key', $k1 !== $k3, true);
check('a changed pose changes the key', $k1 !== StandSkybox::cacheKey($moved, static fn (string $url): array => [100, 1]), true);
check('key format', StandSkyboxStore::isKey($k1), true);

echo "\n== Store builds once, serves faces, drops stale builds ==\n";
$root = sys_get_temp_dir() . '/stand_skybox_test_' . bin2hex(random_bytes(4));
$photoDir = $root . '/photos';
mkdir($photoDir, 0775, true);
file_put_contents($photoDir . '/n.jpg', solidJpeg(64, 64, $warm));
file_put_contents($photoDir . '/s.jpg', solidJpeg(64, 64, $warm));
$photoPath = static function (string $url) use ($photoDir): ?string {
    $path = $photoDir . '/' . basename($url);
    return is_file($path) ? $path : null;
};
$store = new StandSkyboxStore($root . '/skybox');
$standPhotos = [facing('n', 0, 'n.jpg'), facing('s', 180, 's.jpg')];
$stands = ['room-a' => [['stand_id' => 'spot-1', 'photo_ids' => ['n', 's']], ['stand_id' => 'spot-2', 'photo_ids' => ['n']]]];
$byRoom = ['room-a' => $standPhotos];

$plan = $store->plan('sess', $stands, $byRoom, $photoPath);
check('one stand pending, single-photo stand skipped', count($plan['pending']), 1);
check('nothing ready yet', $plan['ready'], []);
$item = $plan['pending'][0];
check('build succeeds', $store->build('sess', $item['room_id'], $item['stand_id'], $item['key'], $item['photos'], $photoPath), true);
$plan = $store->plan('sess', $stands, $byRoom, $photoPath);
check('stand is ready after build', isset($plan['ready']['room-a'][0]), true);
check('nothing left to build', $plan['pending'], []);
check('face file served', is_file((string) $store->facePath('sess', $item['key'], 'u')), true);
check('unknown face rejected', $store->facePath('sess', $item['key'], 'x'), null);
check('bad key rejected', $store->facePath('sess', '../../etc', 'f'), null);

$oldKey = $item['key'];
touch($photoDir . '/n.jpg', time() + 60);
clearstatcache();
$plan = $store->plan('sess', $stands, $byRoom, $photoPath);
check('a replaced photo needs a rebuild', count($plan['pending']), 1);
$item = $plan['pending'][0];
$store->build('sess', $item['room_id'], $item['stand_id'], $item['key'], $item['photos'], $photoPath);
check('stale build removed', is_dir($root . '/skybox/sess/' . $oldKey), false);
check('new build kept', $store->ready('sess', $item['key']) !== null, true);

$store->deleteSession('sess');
check('session delete removes skyboxes', is_dir($root . '/skybox/sess'), false);
@unlink($photoDir . '/n.jpg');
@unlink($photoDir . '/s.jpg');
@rmdir($photoDir);
@rmdir($root . '/skybox');
@rmdir($root);

echo "\n";
echo $failures === 0 ? "TEST VERDICT: GREEN\n" : "$failures failure(s)\nTEST VERDICT: RED\n";
exit($failures === 0 ? 0 : 1);
