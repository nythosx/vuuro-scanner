<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

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

function glb(array $gltf, string $bin = ''): string
{
    $json = json_encode($gltf);
    $json .= str_repeat(' ', (4 - strlen($json) % 4) % 4);
    $bin .= str_repeat("\0", (4 - strlen($bin) % 4) % 4);
    $body = pack('VV', strlen($json), 0x4E4F534A) . $json;
    if ($bin !== '') {
        $body .= pack('VV', strlen($bin), 0x004E4942) . $bin;
    }
    return pack('VVV', 0x46546C67, 2, 12 + strlen($body)) . $body;
}

$root = sys_get_temp_dir() . '/lidar_model_store_test_' . bin2hex(random_bytes(4));
$store = new LidarModelStore($root);
$session = '11111111-2222-3333-4444-555555555555';

$model = glb([
    'asset' => ['version' => '2.0'],
    'buffers' => [['byteLength' => 36]],
    'bufferViews' => [['buffer' => 0, 'byteOffset' => 0, 'byteLength' => 36]],
    'accessors' => [['bufferView' => 0, 'componentType' => 5126, 'count' => 3, 'type' => 'VEC3']],
    'meshes' => [['primitives' => [['attributes' => ['POSITION' => 0]]]]],
], pack('g*', 0, 0, 0, 1, 0, 0, 0, 1, 0));
$total = strlen($model);
$half = intdiv($total, 2);

check('nothing received at first', $store->receivedBytes($session), 0);
check('no model at first', $store->modelPath($session), null);

$first = $store->appendChunk($session, 0, $total, substr($model, 0, $half));
check('first chunk accepted', $first, ['ok' => true, 'received_bytes' => $half]);
check('received bytes after the first chunk', $store->receivedBytes($session), $half);

$wrong = $store->appendChunk($session, $half + 5, $total, substr($model, $half));
check('a chunk at the wrong offset is refused', $wrong['status'] ?? null, 409);
check('the refusal says how much the server has', $wrong['received_bytes'] ?? null, $half);

$early = $store->complete($session, $total, hash('sha256', $model), []);
check('completing before all bytes arrived is refused', $early['code'] ?? null, 'upload_incomplete');

$past = $store->appendChunk($session, $half, $half + 1, substr($model, $half));
check('a chunk past the total is refused', $past['code'] ?? null, 'chunk_past_total');

$second = $store->appendChunk($session, $half, $total, substr($model, $half));
check('second chunk accepted', $second['received_bytes'] ?? null, $total);

$bad = $store->complete($session, $total, str_repeat('0', 64), []);
check('a wrong checksum is refused', $bad['code'] ?? null, 'checksum_mismatch');
check('a wrong checksum drops the partial upload', $store->receivedBytes($session), 0);

$store->appendChunk($session, 0, $total, $model);
$done = $store->complete($session, $total, hash('sha256', $model), ['triangles' => 1, 'photos' => 0, 'capture' => '2026-11-19']);
check('a full upload is stored', $done['ok'] ?? null, true);
check('the stored model has the uploaded bytes', file_get_contents((string) $store->modelPath($session)), $model);
check('the meta keeps the triangle count', $store->meta($session)['triangles'] ?? null, 1);
check('the meta keeps the checksum', $store->meta($session)['sha256'] ?? null, hash('sha256', $model));

$restart = $store->appendChunk($session, 0, $total, substr($model, 0, $half));
check('a new upload can start while a model is stored', $restart['ok'] ?? null, true);
check('the old model stays until the new one completes', file_get_contents((string) $store->modelPath($session)), $model);

$notGlb = 'hello world, this is not a model';
$store->appendChunk($session, 0, strlen($notGlb), $notGlb);
$refused = $store->complete($session, strlen($notGlb), hash('sha256', $notGlb), []);
check('a file that is not GLB is refused', $refused['code'] ?? null, 'invalid_glb');
check('the refused file does not replace the stored model', file_get_contents((string) $store->modelPath($session)), $model);

$noMesh = glb(['asset' => ['version' => '2.0']]);
$path = $root . '/no-mesh.glb';
file_put_contents($path, $noMesh);
check('a GLB with no meshes is refused', LidarModelStore::glbProblem($path), 'it has no meshes');
$cut = substr($model, 0, $total - 4);
file_put_contents($path, $cut);
check('a cut-off GLB is refused', LidarModelStore::glbProblem($path), 'its length field does not match the file size');
file_put_contents($path, $model);
check('the test model itself is fine', LidarModelStore::glbProblem($path), null);
unlink($path);

check('a too large total is refused', $store->appendChunk($session, 0, LidarModelStore::MAX_BYTES + 1, 'x')['status'] ?? null, 413);
check('an empty chunk is refused', $store->appendChunk($session, 0, 10, '')['code'] ?? null, 'bad_chunk');

$store->deleteSession($session);
check('delete removes the model', $store->modelPath($session), null);
check('delete removes the meta', $store->meta($session), null);
check('delete removes the folder', is_dir($root . '/' . $session), false);

$traversal = new LidarModelStore($root);
$traversal->appendChunk('../escape', 0, 3, 'abc');
check('a session id cannot leave the storage folder', is_file(dirname($root) . '/escape/model.part'), false);
$traversal->deleteSession('../escape');
@rmdir($root);

echo "\n$failures failure(s)\n";
exit($failures === 0 ? 0 : 1);
