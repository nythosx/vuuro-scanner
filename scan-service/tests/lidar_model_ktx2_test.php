<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\LidarModelKtx2;
use VuuroScan\Export\LidarModelStore;

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

$positions = pack('g*', 0, 0, 0, 1, 0, 0, 0, 1, 0);
$photo = "\xFF\xD8fake-jpeg\xFF\xD9";
$bin = $positions . $photo . str_repeat("\0", (4 - strlen($photo) % 4) % 4) . pack('g*', 0, 0, 1, 0, 0, 1);
$photoOffset = strlen($positions);
$uvOffset = $photoOffset + strlen($photo) + (4 - strlen($photo) % 4) % 4;
$model = LidarModelKtx2::pack(json_encode([
    'asset' => ['version' => '2.0'],
    'buffers' => [['byteLength' => strlen($bin)]],
    'bufferViews' => [
        ['buffer' => 0, 'byteOffset' => 0, 'byteLength' => strlen($positions)],
        ['buffer' => 0, 'byteOffset' => $photoOffset, 'byteLength' => strlen($photo)],
        ['buffer' => 0, 'byteOffset' => $uvOffset, 'byteLength' => 24],
    ],
    'accessors' => [
        ['bufferView' => 0, 'componentType' => 5126, 'count' => 3, 'type' => 'VEC3'],
        ['bufferView' => 2, 'componentType' => 5126, 'count' => 3, 'type' => 'VEC2'],
    ],
    'images' => [['bufferView' => 1, 'mimeType' => 'image/jpeg']],
    'samplers' => [['magFilter' => 9729]],
    'textures' => [['sampler' => 0, 'source' => 0]],
    'materials' => [['pbrMetallicRoughness' => ['baseColorTexture' => ['index' => 0]]]],
    'meshes' => [['primitives' => [['attributes' => ['POSITION' => 0, 'TEXCOORD_0' => 1], 'material' => 0]]]],
]), $bin);

check('the test model is a usable GLB', LidarModelStore::glbProblem((function (string $data): string {
    $path = tempnam(sys_get_temp_dir(), 'ktx2');
    file_put_contents($path, $data);
    return $path;
})($model)), null);

$seen = [];
$result = LidarModelKtx2::rewrite($model, function (string $bytes, string $mime) use (&$seen): array {
    $seen[] = [$bytes, $mime];
    return ['ok' => true, 'data' => "\xABKTX 20\xBB" . 'compressed'];
});
check('the rewrite succeeds', $result['ok'], true);
check('the encoder got the photo bytes', $seen, [[$photo, 'image/jpeg']]);
check('one photo was compressed', $result['images'], 1);
$parsed = LidarModelKtx2::parse($result['data']);
$json = $parsed['json'];
check('the photo is now KTX2', $json['images'][0]['mimeType'], 'image/ktx2');
check('the texture points to the photo through the basisu extension', $json['textures'][0]['extensions']['KHR_texture_basisu']['source'], 0);
check('the texture no longer has a plain source', array_key_exists('source', $json['textures'][0]), false);
check('the sampler stays', $json['textures'][0]['sampler'], 0);
check('the extension is used', $json['extensionsUsed'], ['KHR_texture_basisu']);
check('the extension is required', $json['extensionsRequired'], ['KHR_texture_basisu']);
$views = $json['bufferViews'];
check('the photo view holds the compressed bytes', substr($parsed['bin'], $views[1]['byteOffset'], $views[1]['byteLength']), "\xABKTX 20\xBB" . 'compressed');
check('the positions are unchanged', substr($parsed['bin'], $views[0]['byteOffset'], $views[0]['byteLength']), $positions);
check('the photo positions are unchanged', substr($parsed['bin'], $views[2]['byteOffset'], $views[2]['byteLength']), pack('g*', 0, 0, 1, 0, 0, 1));
check('every view starts on a 4 byte boundary', array_values(array_filter($views, fn (array $view): bool => $view['byteOffset'] % 4 !== 0)), []);
check('the buffer length matches the data', $json['buffers'][0]['byteLength'], strlen($parsed['bin']));

$failed = LidarModelKtx2::rewrite($model, fn (): array => ['ok' => false, 'message' => 'encoder crashed']);
check('a failed photo fails the whole rewrite', $failed['ok'], false);
check('the failure names the reason', str_contains($failed['message'], 'encoder crashed'), true);
check('a broken file is refused', LidarModelKtx2::rewrite('nope', fn (): array => ['ok' => true, 'data' => 'x'])['ok'], false);

$root = sys_get_temp_dir() . '/lidar_model_ktx2_test_' . bin2hex(random_bytes(4));
$store = new LidarModelStore($root);
$session = '11111111-2222-3333-4444-555555555555';
$store->appendChunk($session, 0, strlen($model), $model);
$store->complete($session, strlen($model), hash('sha256', $model), []);
check('no compressed model before it is built', $store->ktx2Path($session), null);
$calls = 0;
$fake = function () use (&$calls): array {
    $calls++;
    return ['ok' => true, 'data' => 'ktx2-bytes'];
};
$built = $store->buildKtx2($session, '/missing/toktx', $fake);
check('the compressed model is built', $built['ok'], true);
check('the compressed model is stored', $store->ktx2Path($session) !== null, true);
check('the status says done', $store->ktx2Status($session)['state'] ?? null, 'done');
$again = $store->buildKtx2($session, '/missing/toktx', $fake);
check('building again for the same model does no work', [$again['ok'], $calls], [true, 1]);
$store->appendChunk($session, 0, strlen($model), $model);
$store->complete($session, strlen($model), hash('sha256', $model), []);
check('a new upload drops the old compressed model', $store->ktx2Path($session), null);
check('a new upload drops the old status', $store->ktx2Status($session), null);
$bad = $store->buildKtx2($session, '/missing/toktx', fn (): array => ['ok' => false, 'message' => 'no luck']);
check('a failed build keeps no compressed model', $store->ktx2Path($session), null);
check('a failed build says why', $store->ktx2Status($session)['state'] ?? null, 'failed');
$store->deleteSession($session);
check('delete removes the folder with the compressed files', is_dir($root . '/' . $session), false);
@rmdir($root);

check('without toktx installed there is no encoder', getenv('SCAN_SERVICE_TOKTX') === false && !is_file('/usr/bin/toktx') && !is_file('/usr/local/bin/toktx') ? LidarModelKtx2::encoder() : null, null);

if (DIRECTORY_SEPARATOR === '/' && function_exists('imagecreatetruecolor')) {
    $work = sys_get_temp_dir() . '/lidar_model_ktx2_tool_' . bin2hex(random_bytes(4));
    mkdir($work);
    $tool = $work . '/toktx';
    file_put_contents($tool, "#!/bin/sh\nfor a; do prev=\$last; last=\$a; done\ncp \"\$last\" \"\$prev\"\n");
    chmod($tool, 0755);
    $odd = imagecreatetruecolor(10, 7);
    ob_start();
    imagejpeg($odd, null, 90);
    $jpeg = (string) ob_get_clean();
    $encoded = LidarModelKtx2::encodeImage($tool, $jpeg, $work);
    check('the encoder tool runs', $encoded['ok'], true);
    $sent = @imagecreatefromstring((string) ($encoded['data'] ?? ''));
    check('the photo given to the encoder is a multiple of 4 pixels', $sent === false ? null : [imagesx($sent), imagesy($sent)], [8, 4]);
    file_put_contents($tool, "#!/bin/sh\necho broken >&2\nexit 3\n");
    $broken = LidarModelKtx2::encodeImage($tool, $jpeg, $work);
    check('an encoder error is reported', [$broken['ok'], str_contains($broken['message'] ?? '', 'code 3')], [false, true]);
    check('no temporary files stay behind', array_values(array_diff(scandir($work), ['.', '..', 'toktx'])), []);
    unlink($tool);
    rmdir($work);
}

echo "\n$failures failure(s)\n";
exit($failures === 0 ? 0 : 1);
