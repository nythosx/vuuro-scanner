<?php

declare(strict_types=1);

/**
 * Independent net for multi-room stitching and photos/notes attachment.
 * Same rules as net/verify_capture_geometry.php — HTTP only, no adapter/repository
 * imports, expected values re-derived independently.
 *
 * Usage: php net/verify_multiroom_and_attachments.php [base_url]
 */

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

function approx(float $a, float $b, float $tolerance = 0.01): bool
{
    return abs($a - $b) <= $tolerance;
}

function shoelace_area(array $xz): float
{
    $total = 0.0;
    $n = count($xz);
    for ($i = 0; $i < $n; $i++) {
        $j = ($i + 1) % $n;
        $total += ($xz[$i][0] * $xz[$j][1]) - ($xz[$j][0] * $xz[$i][1]);
    }
    return abs($total) / 2.0;
}

function to_xz(array $corners3d): array
{
    return array_map(static fn ($p) => [(float) $p[0], (float) $p[2]], $corners3d);
}

echo "== Multi-room: two sequential single-room captures stitch into one FloorPlan ==\n";

$fixtureA = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$fixtureB = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$wantAreaA = shoelace_area(to_xz($fixtureA['floors'][0]['polygonCorners']));
$wantAreaB = shoelace_area(to_xz($fixtureB['floors'][0]['polygonCorners']));

[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-p2',
    'unit_id' => 'unit-net-p2',
    'organisation_id' => 'org-net-p2',
    'purpose' => 'listing',
    'occupied' => false,
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
if ($sessionId === null || $accessToken === null) {
    fwrite(STDERR, "Cannot continue without a session id/access_token.\n");
    exit(1);
}

[, $afterFirst] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixtureA], $accessToken);
check('first capture produced exactly 1 room', count($afterFirst['rooms'] ?? []) === 1, 'got ' . count($afterFirst['rooms'] ?? []));
check('first room area matches independent shoelace calc',
    approx((float) ($afterFirst['rooms'][0]['floor_area_m2'] ?? -1), $wantAreaA),
    'got ' . ($afterFirst['rooms'][0]['floor_area_m2'] ?? 'null') . " expected " . round($wantAreaA, 4));
$firstRoomIdAfterFirstCapture = $afterFirst['rooms'][0]['room_id'] ?? null;

[, $afterSecond] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixtureB], $accessToken);
check('second capture brings the session to exactly 2 rooms (stitched, not overwritten)',
    count($afterSecond['rooms'] ?? []) === 2, 'got ' . count($afterSecond['rooms'] ?? []));

check('room 1 from the first capture is untouched by the second capture',
    ($afterSecond['rooms'][0]['room_id'] ?? null) === $firstRoomIdAfterFirstCapture
        && approx((float) ($afterSecond['rooms'][0]['floor_area_m2'] ?? -1), $wantAreaA),
    'first room changed after a second, unrelated capture');

check('room 2 area matches independent shoelace calc for the L-shaped fixture',
    approx((float) ($afterSecond['rooms'][1]['floor_area_m2'] ?? -1), $wantAreaB),
    'got ' . ($afterSecond['rooms'][1]['floor_area_m2'] ?? 'null') . " expected " . round($wantAreaB, 4));

check('room_id is unique across both rooms in the session',
    ($afterSecond['rooms'][0]['room_id'] ?? 'a') !== ($afterSecond['rooms'][1]['room_id'] ?? 'b'));

[$getStatus, $refetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('GET after two captures still returns 2 rooms', count($refetched['rooms'] ?? []) === 2, 'got ' . count($refetched['rooms'] ?? []));
check('GET result matches the second capture response exactly', $refetched === $afterSecond);

echo "\n== Photos and notes attach to the same unit package ==\n";

[$photoStatus, $withPhoto] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", [
    'url' => 'https://example.invalid/net-test-photo.jpg',
    'caption' => 'Net test photo',
], $accessToken);
check('photo attach returns HTTP 201', $photoStatus === 201, "got HTTP $photoStatus");
check('photo is appended, not replacing rooms', count($withPhoto['photos'] ?? []) === 1 && count($withPhoto['rooms'] ?? []) === 2);

[$noteStatus, $withNote] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", [
    'text' => 'Net test note',
], $accessToken);
check('note attach returns HTTP 201', $noteStatus === 201, "got HTTP $noteStatus");
check('note is appended, rooms and the earlier photo both survive',
    count($withNote['notes'] ?? []) === 1 && count($withNote['photos'] ?? []) === 1 && count($withNote['rooms'] ?? []) === 2);

echo "\n== Photo uploads: real image bytes, not just a URL string ==\n";

$testImagePath = tempnam(sys_get_temp_dir(), 'net_photo_') . '.png';
$testImage = imagecreatetruecolor(4, 4);
imagefill($testImage, 0, 0, imagecolorallocate($testImage, 255, 0, 0));
imagepng($testImage, $testImagePath);
imagedestroy($testImage);
$expectedBytes = (string) file_get_contents($testImagePath);

[$uploadStatus, $uploadBody] = net_http_multipart_upload("$baseUrl/scan-sessions/$sessionId/photo-uploads", $testImagePath, 'image/png', $accessToken);
check('photo upload returns HTTP 201', $uploadStatus === 201, "got HTTP $uploadStatus");
$uploadedUrl = $uploadBody['url'] ?? null;
check('upload response includes a url', is_string($uploadedUrl), 'got ' . json_encode($uploadBody));

if (is_string($uploadedUrl)) {
    $ch = curl_init($uploadedUrl);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ["X-Scan-Access-Token: $accessToken"],
    ]);
    $fetchedBytes = (string) curl_exec($ch);
    $fetchStatus = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    check('the uploaded photo can be fetched back (HTTP 200)', $fetchStatus === 200, "got HTTP $fetchStatus");
    check('the fetched bytes are byte-identical to what was uploaded — not re-encoded, not a placeholder', $fetchedBytes === $expectedBytes);

    [$fetchNoTokenStatus, ] = net_http_json('GET', $uploadedUrl);
    check('fetching an uploaded photo with no access token is rejected (HTTP 401), same ACL as everything else', $fetchNoTokenStatus === 401, "got HTTP $fetchNoTokenStatus");

    [$attachUploadedStatus, $withUploadedPhoto] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", [
        'url' => $uploadedUrl,
        'caption' => 'Net test uploaded photo',
    ], $accessToken);
    check('the uploaded photo\'s own url attaches via the existing /photos endpoint unchanged (HTTP 201)', $attachUploadedStatus === 201, "got HTTP $attachUploadedStatus");
    check('attaching it does not disturb the rooms already captured', count($withUploadedPhoto['rooms'] ?? []) === 2);
}

$textFilePath = tempnam(sys_get_temp_dir(), 'net_photo_') . '.txt';
file_put_contents($textFilePath, 'not an image');
[$wrongTypeStatus, $wrongTypeBody] = net_http_multipart_upload("$baseUrl/scan-sessions/$sessionId/photo-uploads", $textFilePath, 'text/plain', $accessToken);
check('uploading a non-image file is rejected (HTTP 422), regardless of the claimed Content-Type', $wrongTypeStatus === 422, "got HTTP $wrongTypeStatus");
check('the rejection names the specific error', ($wrongTypeBody['error'] ?? null) === 'unsupported_photo_type', 'got ' . ($wrongTypeBody['error'] ?? 'null'));
unlink($textFilePath);
unlink($testImagePath);

[$fetchNonexistentStatus, $fetchNonexistentBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/photo-uploads/00000000-0000-0000-0000-000000000000.png", null, $accessToken);
check('fetching an uploaded-photo url that was never actually uploaded is a clean 404, not a 500', $fetchNonexistentStatus === 404, "got HTTP $fetchNonexistentStatus");
check('the 404 names the specific error', ($fetchNonexistentBody['error'] ?? null) === 'photo_not_found', 'got ' . ($fetchNonexistentBody['error'] ?? 'null'));

echo "\n== room_id on a photo/note must reference a real room in THIS session ==\n";

$realRoomId = $afterSecond['rooms'][0]['room_id'] ?? null;
check('setup: a real room_id exists to test against', $realRoomId !== null);

[$bogusRoomIdStatus, $bogusRoomIdBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", [
    'text' => 'net test: bogus room_id',
    'room_id' => 'room-that-does-not-exist',
], $accessToken);
check('a note with a room_id that matches no room in this session is rejected (HTTP 422)', $bogusRoomIdStatus === 422, "got HTTP $bogusRoomIdStatus");
check('the rejection names the specific error, not a generic one', ($bogusRoomIdBody['error'] ?? null) === 'unknown_room_id', 'got ' . ($bogusRoomIdBody['error'] ?? 'null'));

if ($realRoomId !== null) {
    [$realRoomIdStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", [
        'text' => 'net test: real room_id',
        'room_id' => $realRoomId,
    ], $accessToken);
    check('a note with a room_id that DOES match a real room in this session still succeeds (HTTP 201)', $realRoomIdStatus === 201, "got HTTP $realRoomIdStatus");
}

// room_id must stay optional, not become required.
[$noRoomIdStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", [
    'text' => 'net test: no room_id at all',
], $accessToken);
check('a note with NO room_id at all still succeeds (HTTP 201) — this fix must not make room_id required', $noRoomIdStatus === 201, "got HTTP $noRoomIdStatus");

[$bogusRoomIdPhotoStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", [
    'url' => 'https://example.invalid/net-test-bogus-room.jpg',
    'room_id' => 'room-that-does-not-exist',
], $accessToken);
check('a photo with a bogus room_id is ALSO rejected (HTTP 422), not just notes', $bogusRoomIdPhotoStatus === 422, "got HTTP $bogusRoomIdPhotoStatus");

echo "\n== Adversarial: photos/notes must not attach before any capture exists ==\n";

[$emptyCreateStatus, $emptySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-p2-empty',
    'unit_id' => 'unit-net-p2-empty',
    'organisation_id' => 'org-net-p2-empty',
    'purpose' => 'listing',
    'occupied' => false,
]);
check('empty session created for the negative case', $emptyCreateStatus === 201);
$emptySessionId = $emptySession['id'] ?? null;
$emptySessionToken = $emptySession['access_token'] ?? null;

if ($emptySessionId !== null) {
    [$photoOnEmptyStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$emptySessionId/photos", ['url' => 'https://example.invalid/x.jpg'], $emptySessionToken);
    check('attaching a photo before any capture is rejected (HTTP 409)', $photoOnEmptyStatus === 409, "got HTTP $photoOnEmptyStatus");

    [$noteOnEmptyStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$emptySessionId/notes", ['text' => 'orphan note'], $emptySessionToken);
    check('attaching a note before any capture is rejected (HTTP 409)', $noteOnEmptyStatus === 409, "got HTTP $noteOnEmptyStatus");
}

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
