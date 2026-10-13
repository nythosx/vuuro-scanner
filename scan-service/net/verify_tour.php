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

echo "== Setup ==\n";
[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-tour', 'unit_id' => 'unit-net-tour', 'organisation_id' => 'org-net-tour',
    'purpose' => 'listing', 'occupied' => false, 'floor' => 'Ground',
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
check('session id and token returned', is_string($sessionId) && is_string($accessToken));

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
[$captureStatus, $floorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('a room was captured', $captureStatus === 200);
$roomId = $floorPlan['rooms'][0]['room_id'] ?? null;
check('room_id present', is_string($roomId));

echo "\n== tour.json shape (header token) ==\n";
[$status, $tourBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json", null, $accessToken);
check('GET tour.json with the header token returns HTTP 200', $status === 200, "got HTTP $status");
check('payload has session_id', ($tourBody['session_id'] ?? null) === $sessionId);
check('payload has property_id', ($tourBody['property_id'] ?? null) === 'prop-net-tour');
check('payload has unit_id', ($tourBody['unit_id'] ?? null) === 'unit-net-tour');
check('payload has organisation_id', ($tourBody['organisation_id'] ?? null) === 'org-net-tour');
check('payload has viewer_url as a string', is_string($tourBody['viewer_url'] ?? null));
check('viewer_url points at /tour/{session_id}', str_contains((string) ($tourBody['viewer_url'] ?? ''), "/tour/{$sessionId}"));
check('payload has plan_image_url as a string', is_string($tourBody['plan_image_url'] ?? null));
check('payload has dollhouse_glb_url explicitly null', array_key_exists('dollhouse_glb_url', $tourBody) && $tourBody['dollhouse_glb_url'] === null);
check('payload has a rooms array with one room', is_array($tourBody['rooms'] ?? null) && count($tourBody['rooms']) === 1);
check('rooms[0].room_id matches the captured room', ($tourBody['rooms'][0]['room_id'] ?? null) === $roomId);
check('rooms[0].photos is empty when none uploaded', ($tourBody['rooms'][0]['photos'] ?? null) === []);
check('rooms[0] carries the outline for the 3D viewer', is_array($tourBody['rooms'][0]['outline_m'] ?? null) && count($tourBody['rooms'][0]['outline_m']) >= 3);

echo "\n== tour.json accepts ?token= as well as the header ==\n";
[$queryStatus, $queryBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json?token=" . rawurlencode($accessToken));
check('GET tour.json with ?token= returns HTTP 200', $queryStatus === 200, "got HTTP $queryStatus");
check('the query-token response has the same session_id', ($queryBody['session_id'] ?? null) === $sessionId);

echo "\n== tour.json rejects missing / wrong tokens ==\n";
[$noTokenStatus] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json");
check('GET tour.json with no token returns 401', $noTokenStatus === 401, "got HTTP $noTokenStatus");
[$wrongTokenStatus] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json", null, 'not-a-real-token');
check('GET tour.json with the wrong token returns 401', $wrongTokenStatus === 401, "got HTTP $wrongTokenStatus");

echo "\n== tour.json on a session with no floor plan ==\n";
[, $emptySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-tour-empty', 'unit_id' => 'unit-net-tour-empty', 'organisation_id' => 'org-net-tour',
    'purpose' => 'listing', 'occupied' => false, 'floor' => 'Ground',
]);
[$emptyStatus, $emptyBody] = net_http_json('GET', "$baseUrl/scan-sessions/{$emptySession['id']}/tour.json", null, $emptySession['access_token']);
check('tour.json on a session with no rooms returns 404 no_floor_plan_yet',
    $emptyStatus === 404 && ($emptyBody['error'] ?? null) === 'no_floor_plan_yet',
    "got HTTP $emptyStatus: " . json_encode($emptyBody));

echo "\n== plan_image_url is reachable from the viewer ==\n";
$planUrl = (string) ($tourBody['plan_image_url'] ?? '');
$join = str_contains($planUrl, '?') ? '&' : '?';
[$planStatus, $planContentType, $planBytes] = net_http_raw('GET', $planUrl . $join . 'token=' . rawurlencode($accessToken), null, null);
check('plan_image_url with ?token= returns HTTP 200', $planStatus === 200, "got HTTP $planStatus");
check('plan_image_url serves a real PNG', str_starts_with($planBytes, "\x89PNG"), 'content-type was: ' . $planContentType);

echo "\n== Static tour shell ==\n";
[$shellStatus, $shellContentType, $shellBody] = net_http_raw('GET', "$baseUrl/tour/$sessionId", null, null);
check('GET /tour/{id} returns HTTP 200', $shellStatus === 200, "got HTTP $shellStatus");
check('GET /tour/{id} is served as text/html', stripos($shellContentType, 'text/html') !== false, "content-type was: $shellContentType");
check('GET /tour/{id} returns the viewer shell (references /tour/tour.js)', str_contains($shellBody, '/tour/tour.js'));
check('GET /tour/{id} has a Vuuro Scan header', str_contains($shellBody, 'Vuuro Scan'));

echo "\n== Static tour assets ==\n";
[$jsStatus, $jsContentType, $jsBody] = net_http_raw('GET', "$baseUrl/tour/tour.js", null, null);
check('GET /tour/tour.js returns HTTP 200', $jsStatus === 200, "got HTTP $jsStatus");
check('GET /tour/tour.js is JavaScript', stripos($jsContentType, 'javascript') !== false, "content-type was: $jsContentType");
check('GET /tour/tour.js has real content', strlen($jsBody) > 200, 'body length: ' . strlen($jsBody));

[$cssStatus, $cssContentType] = net_http_raw('GET', "$baseUrl/tour/tour.css", null, null);
check('GET /tour/tour.css returns HTTP 200', $cssStatus === 200, "got HTTP $cssStatus");
check('GET /tour/tour.css is CSS', stripos($cssContentType, 'text/css') !== false, "content-type was: $cssContentType");

[$missingStatus] = net_http_raw('GET', "$baseUrl/tour/does-not-exist.js", null, null);
check('GET /tour/does-not-exist.js returns HTTP 404', $missingStatus === 404, "got HTTP $missingStatus");

echo "\n== tour.json rooms[].photos[] shape ==\n";

$shapePhotoPath = tempnam(sys_get_temp_dir(), 'tour_shape_photo_') . '.jpg';
$shapePhotoImg = imagecreatetruecolor(48, 48);
imagefilledrectangle($shapePhotoImg, 0, 0, 48, 48, imagecolorallocate($shapePhotoImg, 120, 160, 200));
imagejpeg($shapePhotoImg, $shapePhotoPath, 90);
imagedestroy($shapePhotoImg);

$shapeUpload = curl_init("$baseUrl/scan-sessions/$sessionId/photos-360");
curl_setopt_array($shapeUpload, [
    CURLOPT_POST => true,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => [
        "X-Scan-Access-Token: $accessToken",
        "Idempotency-Key: tour-shape-photo-1",
    ],
    CURLOPT_POSTFIELDS => [
        'photo' => new \CURLFile($shapePhotoPath, 'image/jpeg', basename($shapePhotoPath)),
        'room_id' => (string) $roomId,
        'position_x' => '1.25',
        'position_z' => '2.5',
        'heading_deg' => '90.0',
    ],
    CURLOPT_CONNECTTIMEOUT_MS => 3000,
    CURLOPT_TIMEOUT => 30,
]);
$shapeUploadRaw = curl_exec($shapeUpload);
$shapeUploadStatus = (int) curl_getinfo($shapeUpload, CURLINFO_HTTP_CODE);
curl_close($shapeUpload);
@unlink($shapePhotoPath);

check('a tour photo uploads for the shape check (HTTP 201)', $shapeUploadStatus === 201, "got HTTP $shapeUploadStatus: " . substr((string) $shapeUploadRaw, 0, 200));

if ($shapeUploadStatus === 201) {
    [$shapeStatus, $shapeBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json", null, $accessToken);
    check('tour.json is still HTTP 200 with a photo present', $shapeStatus === 200, "got HTTP $shapeStatus");

    $shapeRoom = null;
    foreach ($shapeBody['rooms'] ?? [] as $shapeCandidate) {
        if (is_array($shapeCandidate) && ($shapeCandidate['room_id'] ?? null) === $roomId) {
            $shapeRoom = $shapeCandidate;
            break;
        }
    }
    check('the room that owns the photo is present in rooms[]', $shapeRoom !== null);

    $shapePhotos = $shapeRoom !== null && is_array($shapeRoom['photos'] ?? null) ? $shapeRoom['photos'] : null;
    check('the owning room carries a non-empty photos[]', is_array($shapePhotos) && count($shapePhotos) === 1, json_encode($shapePhotos));

    if (is_array($shapePhotos) && $shapePhotos !== []) {
        $shapeEntry = $shapePhotos[0];
        $shapePhotoId = $shapeEntry['photo_id'] ?? null;
        $shapePhotoUrl = $shapeEntry['url'] ?? null;
        $shapePhotoPos = $shapeEntry['position_m'] ?? null;
        $shapePhotoHeading = $shapeEntry['heading_deg'] ?? null;

        check(
            'photos[].photo_id is a non-empty string',
            is_string($shapePhotoId) && $shapePhotoId !== '',
            json_encode($shapePhotoId)
        );
        check(
            'photos[].url is a non-empty string the viewer can load',
            is_string($shapePhotoUrl) && $shapePhotoUrl !== '',
            json_encode($shapePhotoUrl)
        );
        check(
            'photos[].position_m is a 2-element array of finite numbers',
            is_array($shapePhotoPos)
                && count($shapePhotoPos) === 2
                && is_numeric($shapePhotoPos[0])
                && is_numeric($shapePhotoPos[1])
                && is_finite((float) $shapePhotoPos[0])
                && is_finite((float) $shapePhotoPos[1]),
            json_encode($shapePhotoPos)
        );
        check(
            'photos[].heading_deg is a finite number in [0, 360)',
            is_numeric($shapePhotoHeading)
                && is_finite((float) $shapePhotoHeading)
                && (float) $shapePhotoHeading >= 0
                && (float) $shapePhotoHeading < 360,
            json_encode($shapePhotoHeading)
        );

        if (is_string($shapePhotoUrl) && $shapePhotoUrl !== '') {
            $shapeJoin = str_contains($shapePhotoUrl, '?') ? '&' : '?';
            [$shapeFetchStatus] = net_http_raw('GET', $shapePhotoUrl . $shapeJoin . 'token=' . rawurlencode($accessToken));
            check(
                'photos[].url is fetchable with a ?token= query parameter (the browser <img src> path)',
                $shapeFetchStatus === 200,
                "got HTTP $shapeFetchStatus"
            );

            [$shapeNoTokenStatus] = net_http_raw('GET', $shapePhotoUrl);
            check(
                'photos[].url with no token at all is still refused (regression guard)',
                $shapeNoTokenStatus === 401,
                "got HTTP $shapeNoTokenStatus"
            );
        }
    }

    $otherRooms = 0;
    foreach ($shapeBody['rooms'] ?? [] as $otherCandidate) {
        if (!is_array($otherCandidate)) {
            continue;
        }
        if (($otherCandidate['room_id'] ?? null) !== $roomId && !empty($otherCandidate['photos'])) {
            $otherRooms++;
        }
    }
    check('photos[] entries are scoped to their own room only', $otherRooms === 0, "got $otherRooms other room(s) with photos");
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
