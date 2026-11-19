<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$failures = [];
$checks = 0;

function check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label — $detail";
        echo "  [FAIL] $label — $detail\n";
    }
}

function model_glb(int $padBytes): string
{
    $bin = pack('g*', 0, 0, 0, 1, 0, 0, 0, 1, 0) . str_repeat("\0", $padBytes);
    $gltf = [
        'asset' => ['version' => '2.0'],
        'buffers' => [['byteLength' => strlen($bin)]],
        'bufferViews' => [['buffer' => 0, 'byteOffset' => 0, 'byteLength' => 36]],
        'accessors' => [['bufferView' => 0, 'componentType' => 5126, 'count' => 3, 'type' => 'VEC3']],
        'meshes' => [['primitives' => [['attributes' => ['POSITION' => 0]]]]],
    ];
    $json = json_encode($gltf);
    $json .= str_repeat(' ', (4 - strlen($json) % 4) % 4);
    $bin .= str_repeat("\0", (4 - strlen($bin) % 4) % 4);
    $body = pack('VV', strlen($json), 0x4E4F534A) . $json . pack('VV', strlen($bin), 0x004E4942) . $bin;
    return pack('VVV', 0x46546C67, 2, 12 + strlen($body)) . $body;
}

function send_chunk(string $baseUrl, string $sessionId, ?string $token, int $offset, int $total, string $bytes): array
{
    [$status, , $raw] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/lidar-model/chunks", $bytes, $token, [
        'X-Upload-Offset' => (string) $offset,
        'X-Upload-Total' => (string) $total,
    ]);
    $decoded = json_decode($raw, true);
    return [$status, is_array($decoded) ? $decoded : []];
}

echo "== Setup ==\n";
[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-lidar', 'unit_id' => 'unit-net-lidar', 'organisation_id' => 'org-net-lidar',
    'purpose' => 'listing', 'occupied' => false, 'floor' => 'Ground',
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = (string) ($session['id'] ?? '');
$accessToken = (string) ($session['access_token'] ?? '');
$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
[$captureStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('a room was captured', $captureStatus === 200, "got HTTP $captureStatus");

echo "\n== Before any upload ==\n";
[$tourStatus, $tourBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json", null, $accessToken);
check('tour.json opens', $tourStatus === 200, "got HTTP $tourStatus");
check('tour.json has no lidar_model yet', array_key_exists('lidar_model', $tourBody) && $tourBody['lidar_model'] === null);
[$missingStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/lidar-model.glb", null, $accessToken);
check('the model download answers 404 before an upload', $missingStatus === 404, "got HTTP $missingStatus");

echo "\n== Chunked upload larger than one request ==\n";
$model = model_glb(9 * 1024 * 1024);
$total = strlen($model);
$chunk = 4 * 1024 * 1024;
[$noTokenStatus] = send_chunk($baseUrl, $sessionId, null, 0, $total, substr($model, 0, $chunk));
check('a chunk without the token is refused', $noTokenStatus === 401, "got HTTP $noTokenStatus");
$viewToken = '';
parse_str((string) parse_url((string) ($tourBody['viewer_url'] ?? ''), PHP_URL_QUERY), $viewerQuery);
$viewToken = (string) ($viewerQuery['token'] ?? '');
[$viewUploadStatus] = send_chunk($baseUrl, $sessionId, $viewToken, 0, $total, substr($model, 0, $chunk));
check('the read-only view token cannot upload a model', $viewUploadStatus === 401, "got HTTP $viewUploadStatus");

$offset = 0;
$allOk = true;
while ($offset < $total) {
    $piece = substr($model, $offset, $chunk);
    [$status, $body] = send_chunk($baseUrl, $sessionId, $accessToken, $offset, $total, $piece);
    if ($status !== 200 || ($body['received_bytes'] ?? null) !== $offset + strlen($piece)) {
        $allOk = false;
        check("chunk at $offset accepted", false, "got HTTP $status");
        break;
    }
    $offset += strlen($piece);
}
check('every chunk was accepted', $allOk);
[$replayStatus, $replayBody] = send_chunk($baseUrl, $sessionId, $accessToken, $chunk, $total, substr($model, $chunk, $chunk));
check('a repeated chunk at an old offset answers 409', $replayStatus === 409, "got HTTP $replayStatus");
check('the 409 says how many bytes the server has', ($replayBody['received_bytes'] ?? null) === $total);

[$badShaStatus, $badShaBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/lidar-model/complete", ['total_bytes' => $total, 'sha256' => str_repeat('a', 64)], $accessToken);
check('a wrong checksum is refused with 422', $badShaStatus === 422 && ($badShaBody['error'] ?? $badShaBody['error_code'] ?? '') !== '', "got HTTP $badShaStatus");

$offset = 0;
while ($offset < $total) {
    $piece = substr($model, $offset, $chunk);
    send_chunk($baseUrl, $sessionId, $accessToken, $offset, $total, $piece);
    $offset += strlen($piece);
}
[$doneStatus, $doneBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/lidar-model/complete", ['total_bytes' => $total, 'sha256' => hash('sha256', $model), 'triangles' => 1, 'photos' => 0], $accessToken);
check('completing the upload answers 201', $doneStatus === 201, "got HTTP $doneStatus: " . json_encode($doneBody));
check('the answer carries the model url', str_contains((string) ($doneBody['lidar_model']['url'] ?? ''), "/scan-sessions/$sessionId/export/lidar-model.glb"));
check('the answer carries the size', ($doneBody['lidar_model']['bytes'] ?? null) === $total);

echo "\n== Download ==\n";
[$getStatus, $getType, $getBody] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/lidar-model.glb", null, $accessToken);
check('the model downloads with the access token', $getStatus === 200, "got HTTP $getStatus");
check('the download is the uploaded file', $getBody === $model, 'got ' . strlen($getBody) . " of $total bytes");
check('the download is served as GLB', str_starts_with($getType, 'model/gltf-binary'), "got $getType");
[$viewGetStatus, , $viewGetBody] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/lidar-model.glb?token=" . rawurlencode($viewToken));
check('the model downloads with the view token from the tour link', $viewGetStatus === 200 && $viewGetBody === $model, "got HTTP $viewGetStatus");
[$wrongGetStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/lidar-model.glb?token=view-0000");
check('a wrong token cannot download the model', $wrongGetStatus === 401, "got HTTP $wrongGetStatus");

[, $tourAfter] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json?token=" . rawurlencode($viewToken));
check('tour.json now lists the model', str_contains((string) ($tourAfter['lidar_model']['url'] ?? ''), '/export/lidar-model.glb'));
check('tour.json gives the triangle count', ($tourAfter['lidar_model']['triangles'] ?? null) === 1);
[, $planAfter] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('the floor plan tour block lists the model', str_contains((string) ($planAfter['tour']['lidar_model']['url'] ?? ''), '/export/lidar-model.glb'));

echo "\n== Not a model ==\n";
$junk = str_repeat('x', 1000);
send_chunk($baseUrl, $sessionId, $accessToken, 0, strlen($junk), $junk);
[$junkStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/lidar-model/complete", ['total_bytes' => strlen($junk), 'sha256' => hash('sha256', $junk)], $accessToken);
check('a file that is not GLB is refused with 422', $junkStatus === 422, "got HTTP $junkStatus");
[, , $stillBody] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/lidar-model.glb", null, $accessToken);
check('the stored model is kept after a refused upload', $stillBody === $model);

echo "\n== Delete ==\n";
[$viewDeleteStatus] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/lidar-model", null, $viewToken);
check('the view token cannot delete the model', $viewDeleteStatus === 401, "got HTTP $viewDeleteStatus");
[$deleteStatus] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/lidar-model", null, $accessToken);
check('the model can be deleted with the access token', $deleteStatus === 200, "got HTTP $deleteStatus");
[$goneStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/lidar-model.glb", null, $accessToken);
check('the model is gone after delete', $goneStatus === 404, "got HTTP $goneStatus");

$offset = 0;
while ($offset < $total) {
    $piece = substr($model, $offset, $chunk);
    send_chunk($baseUrl, $sessionId, $accessToken, $offset, $total, $piece);
    $offset += strlen($piece);
}
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/lidar-model/complete", ['total_bytes' => $total, 'sha256' => hash('sha256', $model)], $accessToken);
[$sessionDeleteStatus] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('the session can be deleted', $sessionDeleteStatus === 200, "got HTTP $sessionDeleteStatus");
check('deleting the session removes its model folder', !is_dir(__DIR__ . '/../data/lidar-model/' . $sessionId));

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
exit($failures === [] ? 0 : 1);
