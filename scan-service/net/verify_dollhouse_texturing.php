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

function dollhouse_tex_photo_360_upload(
    string $url,
    string $filePath,
    string $mimeType,
    array $fields,
    string $accessToken,
    string $idempotencyKey
): array {
    $ch = curl_init($url);
    $postFields = ['photo' => new \CURLFile($filePath, $mimeType, basename($filePath))];
    foreach ($fields as $name => $value) {
        $postFields[$name] = $value;
    }
    $headers = [];
    if ($accessToken !== '') {
        $headers[] = "X-Scan-Access-Token: $accessToken";
    }
    if ($idempotencyKey !== '') {
        $headers[] = "Idempotency-Key: $idempotencyKey";
    }
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_POSTFIELDS => $postFields,
        CURLOPT_CONNECTTIMEOUT_MS => 3000,
        CURLOPT_TIMEOUT => 30,
    ]);
    $raw = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    $decoded = json_decode((string) $raw, true);
    return [$status, is_array($decoded) ? $decoded : []];
}

function dollhouse_tex_glb_json(string $glb): ?array
{
    if (strlen($glb) < 12) {
        return null;
    }
    $totalLen = unpack('V', substr($glb, 8, 4))[1];
    $offset = 12;
    while ($offset + 8 <= $totalLen) {
        $len = unpack('V', substr($glb, $offset, 4))[1];
        $type = unpack('V', substr($glb, $offset + 4, 4))[1];
        if ($type === 0x4E4F534A) {
            $decoded = json_decode(substr($glb, $offset + 8, $len), true);
            return is_array($decoded) ? $decoded : null;
        }
        $offset += 8 + $len;
    }
    return null;
}

echo "== Setup ==\n";
[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-dollhouse-tex',
    'unit_id' => 'unit-net-dollhouse-tex',
    'organisation_id' => 'org-net-dollhouse-tex',
    'purpose' => 'listing',
    'occupied' => false,
    'floor' => 'Ground',
]);
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
check('session created', is_string($sessionId) && is_string($accessToken));

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_offset_height_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$fixture['heading_deg'] = 0.0;

[, $plan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", [
    'raw_capture' => $fixture,
    'floor' => 'Ground',
], $accessToken);
$roomId = $plan['rooms'][0]['room_id'] ?? null;
check('a room was captured with a known heading', is_string($roomId));

echo "\n== Baseline: no photo yet, GLB has no textures, ETag recorded ==\n";
[$baselineStatus, $baselineType, $baselineBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/dollhouse.glb", null, $accessToken);
check('baseline dollhouse.glb returns HTTP 200', $baselineStatus === 200, "got HTTP $baselineStatus");
check('baseline dollhouse.glb is model/gltf-binary', stripos($baselineType, 'model/gltf-binary') !== false, $baselineType);
$baselineJson = dollhouse_tex_glb_json($baselineBytes);
check('baseline GLB has no images array', is_array($baselineJson) && !isset($baselineJson['images']));
check('baseline GLB has exactly one primitive', is_array($baselineJson) && count($baselineJson['meshes'][0]['primitives'] ?? []) === 1);
[, $baselineHeaders] = net_http_headers('GET', "$baseUrl/scan-sessions/$sessionId/export/dollhouse.glb", $accessToken);
preg_match('/^ETag:\s*(.+)$/mi', $baselineHeaders, $baselineEtagMatch);
$baselineEtag = trim($baselineEtagMatch[1] ?? '');
check('baseline response carries an ETag', $baselineEtag !== '');

echo "\n== Upload a tour photo facing one wall ==\n";
$tmpJpg = tempnam(sys_get_temp_dir(), 'dollhouse_tex_');
$img = imagecreatetruecolor(64, 64);
imagefilledrectangle($img, 0, 0, 64, 64, imagecolorallocate($img, 180, 100, 220));
imagejpeg($img, $tmpJpg, 85);
imagedestroy($img);

[$uploadStatus, $uploadBody] = dollhouse_tex_photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpJpg,
    'image/jpeg',
    [
        'room_id' => $roomId,
        'position_x' => '1.75',
        'position_z' => '0.5',
        'heading_deg' => '0.0',
    ],
    $accessToken,
    'dollhouse-tex-key-1'
);
@unlink($tmpJpg);
check('photo 360 upload accepted (HTTP 201)', $uploadStatus === 201, "got HTTP $uploadStatus " . json_encode($uploadBody));

echo "\n== GLB after the photo: the photographed wall is now textured ==\n";
[$texStatus, $texType, $texBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/dollhouse.glb", null, $accessToken);
check('dollhouse.glb returns HTTP 200 after the photo', $texStatus === 200);
check('dollhouse.glb is still model/gltf-binary', stripos($texType, 'model/gltf-binary') !== false, $texType);
$texJson = dollhouse_tex_glb_json($texBytes);
check('GLB after photo still parses', is_array($texJson));
check('GLB after photo now has an images array', is_array($texJson) && isset($texJson['images']) && count($texJson['images']) === 1);
check('GLB after photo has a flat primitive plus a textured one', is_array($texJson) && count($texJson['meshes'][0]['primitives'] ?? []) === 2);

echo "\n== ETag changes when a tour photo is added (export now reads them) ==\n";
[, $texHeaders] = net_http_headers('GET', "$baseUrl/scan-sessions/$sessionId/export/dollhouse.glb", $accessToken);
preg_match('/^ETag:\s*(.+)$/mi', $texHeaders, $texEtagMatch);
$texEtag = trim($texEtagMatch[1] ?? '');
check('response after photo still carries an ETag', $texEtag !== '');
check('the ETag changes after a tour photo is added', $texEtag !== $baselineEtag);

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nNET VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}
echo "\nNET VERDICT: GREEN\n";
exit(0);
