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

function photo_360_upload(
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
    return [$status, is_array($decoded) ? $decoded : [], (string) $raw];
}

echo "== Setup ==\n";
[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-360', 'unit_id' => 'unit-net-360', 'organisation_id' => 'org-net-360',
    'purpose' => 'listing', 'occupied' => false, 'floor' => 'Ground',
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
check('session id and token returned', is_string($sessionId) && is_string($accessToken));

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
[$captureStatus, $floorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('a room was captured', $captureStatus === 200 && count($floorPlan['rooms'] ?? []) === 1);
$roomId = $floorPlan['rooms'][0]['room_id'] ?? null;
check('room_id present', is_string($roomId));

$tmpImage = tempnam(sys_get_temp_dir(), 'photo360_') . '.jpg';
$img = imagecreatetruecolor(64, 64);
imagefilledrectangle($img, 0, 0, 64, 64, imagecolorallocate($img, 100, 150, 200));
imagejpeg($img, $tmpImage, 90);
imagedestroy($img);

$fields = [
    'room_id' => $roomId,
    'position_x' => '1.25',
    'position_z' => '2.5',
    'heading_deg' => '90.0',
];

echo "\n== Happy path ==\n";
[$uploadStatus, $uploadBody, $uploadRaw] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', $fields, $accessToken, 'key-360-1'
);
check('upload returns HTTP 201', $uploadStatus === 201, "got HTTP $uploadStatus, body: " . substr($uploadRaw, 0, 300));
check('response has a photo_id', is_string($uploadBody['photo_id'] ?? null), json_encode($uploadBody));
check('response carries the room_id we sent', ($uploadBody['room_id'] ?? null) === $roomId);
check('response carries the position we sent', ($uploadBody['position_m'] ?? null) === [1.25, 2.5]);
check('response carries the heading we sent', ($uploadBody['heading_deg'] ?? null) === 90.0);
check('response has a url', is_string($uploadBody['url'] ?? null));
check('response has captured_at', is_string($uploadBody['captured_at'] ?? null));
$photoId = $uploadBody['photo_id'] ?? null;

echo "\n== Idempotency ==\n";
[$retryStatus, $retryBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', $fields, $accessToken, 'key-360-1'
);
check('retry with the same Idempotency-Key returns HTTP 200 (not 201)', $retryStatus === 200, "got HTTP $retryStatus");
check('retry returns the SAME photo_id', ($retryBody['photo_id'] ?? null) === $photoId);

[$secondStatus, $secondBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', $fields, $accessToken, 'key-360-2'
);
check('a fresh Idempotency-Key stores a new photo (HTTP 201)', $secondStatus === 201, "got HTTP $secondStatus");
check('the second photo has a different photo_id', ($secondBody['photo_id'] ?? null) !== $photoId);
check('a photo sent without zoom is stored at 1x', ($uploadBody['zoom'] ?? null) === 1.0, json_encode($uploadBody));

[$zoomStatus, $zoomBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', array_merge($fields, ['zoom' => '1.500']), $accessToken, 'key-360-zoom'
);
check('a zoomed photo keeps its zoom', $zoomStatus === 201 && ($zoomBody['zoom'] ?? null) === 1.5, "got HTTP $zoomStatus: " . json_encode($zoomBody));

[$badZoomStatus, $badZoomBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', array_merge($fields, ['zoom' => '3']), $accessToken, 'key-360-bad-zoom'
);
check('zoom above 2x is rejected with 422 invalid_zoom',
    $badZoomStatus === 422 && ($badZoomBody['error'] ?? null) === 'invalid_zoom',
    "got HTTP $badZoomStatus: " . json_encode($badZoomBody));

echo "\n== Missing / malformed fields ==\n";
[$noKeyStatus, $noKeyBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', $fields, $accessToken, ''
);
check('missing Idempotency-Key is rejected with 422 missing_idempotency_key',
    $noKeyStatus === 422 && ($noKeyBody['error'] ?? null) === 'missing_idempotency_key',
    "got HTTP $noKeyStatus: " . json_encode($noKeyBody));

[$noRoomStatus, $noRoomBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg',
    array_merge($fields, ['room_id' => 'not-a-real-room']),
    $accessToken, 'key-360-bad-room'
);
check('unknown room_id is rejected with 422 unknown_room_id',
    $noRoomStatus === 422 && ($noRoomBody['error'] ?? null) === 'unknown_room_id',
    "got HTTP $noRoomStatus: " . json_encode($noRoomBody));

[$badPosStatus, $badPosBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg',
    array_merge($fields, ['position_x' => 'not-a-number']),
    $accessToken, 'key-360-bad-pos'
);
check('non-numeric position_x is rejected with 422',
    $badPosStatus === 422, "got HTTP $badPosStatus: " . json_encode($badPosBody));

[$badHeadingStatus, $badHeadingBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg',
    array_merge($fields, ['heading_deg' => '400']),
    $accessToken, 'key-360-bad-heading'
);
check('heading_deg >= 360 is rejected with 422 invalid_heading',
    $badHeadingStatus === 422 && ($badHeadingBody['error'] ?? null) === 'invalid_heading',
    "got HTTP $badHeadingStatus: " . json_encode($badHeadingBody));

$tmpTxt = tempnam(sys_get_temp_dir(), 'photo360_') . '.txt';
file_put_contents($tmpTxt, 'definitely not an image');
[$badTypeStatus, $badTypeBody] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpTxt, 'image/jpeg', $fields, $accessToken, 'key-360-bad-type'
);
check('unsupported MIME type is rejected with 422 unsupported_photo_type',
    $badTypeStatus === 422 && ($badTypeBody['error'] ?? null) === 'unsupported_photo_type',
    "got HTTP $badTypeStatus: " . json_encode($badTypeBody));

echo "\n== Access ==\n";
[$noAuthStatus] = photo_360_upload(
    "$baseUrl/scan-sessions/$sessionId/photos-360",
    $tmpImage, 'image/jpeg', $fields, 'wrong-token', 'key-360-no-auth'
);
check('wrong access token returns 401', $noAuthStatus === 401, "got HTTP $noAuthStatus");

unlink($tmpImage);
unlink($tmpTxt);

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
