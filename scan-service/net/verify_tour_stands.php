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
        $failures[] = "$label - $detail";
        echo "  [FAIL] $label - $detail\n";
    }
}

function capture_room(string $baseUrl, string $sessionId, string $token, array $rawCapture): array
{
    return net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $rawCapture], $token);
}

function upload_photo(string $baseUrl, string $sessionId, string $token, string $roomId, float $x, float $z, float $heading, string $key): int
{
    $tmp = tempnam(sys_get_temp_dir(), 'tour_stand_') . '.jpg';
    $img = imagecreatetruecolor(32, 32);
    imagefilledrectangle($img, 0, 0, 32, 32, imagecolorallocate($img, 100, 150, 200));
    imagejpeg($img, $tmp, 85);
    imagedestroy($img);

    $ch = curl_init("$baseUrl/scan-sessions/$sessionId/photos-360");
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ["X-Scan-Access-Token: $token", "Idempotency-Key: $key"],
        CURLOPT_POSTFIELDS => [
            'photo' => new \CURLFile($tmp, 'image/jpeg', 'photo.jpg'),
            'room_id' => $roomId,
            'position_x' => (string) $x,
            'position_z' => (string) $z,
            'heading_deg' => (string) $heading,
        ],
        CURLOPT_CONNECTTIMEOUT_MS => 3000,
        CURLOPT_TIMEOUT => 30,
    ]);
    $raw = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    @unlink($tmp);
    return $status;
}

function room_capture(string $floorId, array $origin, array $doorLocal): array
{
    return [
        'story' => 0,
        'structure_origin_m' => $origin,
        'capture_group_id' => 'g-walk',
        'floors' => [[
            'identifier' => $floorId,
            'category' => 'floor',
            'confidence' => 'high',
            'polygonCorners' => [
                [0.0, 0.0, 0.0],
                [4.0, 0.0, 0.0],
                [4.0, 0.0, 4.0],
                [0.0, 0.0, 4.0],
            ],
        ]],
        'walls' => [
            ['identifier' => 'w-' . $floorId . '-1', 'category' => 'wall', 'confidence' => 'high', 'dimensions' => [4.0, 2.6, 0.1]],
            ['identifier' => 'w-' . $floorId . '-2', 'category' => 'wall', 'confidence' => 'high', 'dimensions' => [4.0, 2.6, 0.1]],
            ['identifier' => 'w-' . $floorId . '-3', 'category' => 'wall', 'confidence' => 'high', 'dimensions' => [4.0, 2.6, 0.1]],
            ['identifier' => 'w-' . $floorId . '-4', 'category' => 'wall', 'confidence' => 'high', 'dimensions' => [4.0, 2.6, 0.1]],
        ],
        'doors' => [[
            'identifier' => 'door-' . $floorId,
            'category' => 'door',
            'confidence' => 'high',
            'dimensions' => [0.9, 2.05, 0.1],
            'polygonCorners' => [
                [$doorLocal[0] - 0.45, 0.0, $doorLocal[1]],
                [$doorLocal[0] + 0.45, 0.0, $doorLocal[1]],
                [$doorLocal[0] + 0.45, 2.05, $doorLocal[1]],
                [$doorLocal[0] - 0.45, 2.05, $doorLocal[1]],
            ],
        ]],
        'windows' => [],
        'openings' => [],
        'objects' => [],
    ];
}

echo "== Setup ==\n";
[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-stands',
    'unit_id' => 'unit-net-stands',
    'organisation_id' => 'org-net-stands',
    'purpose' => 'listing',
    'occupied' => false,
    'floor' => 'Ground',
]);
check('session created', $createStatus === 201, "HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
check('session id and token returned', is_string($sessionId) && is_string($accessToken));

[$capAStatus, $capABody] = capture_room($baseUrl, $sessionId, $accessToken, room_capture('floor-a', [0.0, 0.0], [2.0, 4.0]));
check('room A captured', $capAStatus === 200, "HTTP $capAStatus");
$roomAId = $capABody['rooms'][0]['room_id'] ?? null;
check('room A id present', is_string($roomAId));

[$capBStatus, $capBBody] = capture_room($baseUrl, $sessionId, $accessToken, room_capture('floor-b', [0.0, 4.0], [2.0, 0.0]));
check('room B captured', $capBStatus === 200, "HTTP $capBStatus");
$roomBId = $capBBody['rooms'][1]['room_id'] ?? null;
check('room B id present', is_string($roomBId));

$upA1 = upload_photo($baseUrl, $sessionId, $accessToken, $roomAId, 2.0, 3.5, 0.0, 'key-a1');
$upA2 = upload_photo($baseUrl, $sessionId, $accessToken, $roomAId, 0.5, 0.5, 90.0, 'key-a2');
$upA3 = upload_photo($baseUrl, $sessionId, $accessToken, $roomAId, 2.1, 3.6, 180.0, 'key-a3');
$upB1 = upload_photo($baseUrl, $sessionId, $accessToken, $roomBId, 2.0, 1.5, 270.0, 'key-b1');
check('room A photos uploaded', $upA1 === 201 && $upA2 === 201 && $upA3 === 201, "HTTP $upA1 $upA2 $upA3");
check('room B photo uploaded', $upB1 === 201, "HTTP $upB1");

echo "\n== tour.json shape ==\n";
[$tourStatus, $tourBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/tour.json", null, $accessToken);
check('tour.json returns 200', $tourStatus === 200, "HTTP $tourStatus");
check('features.walkthrough true', ($tourBody['features']['walkthrough'] ?? null) === true);

$roomsById = [];
foreach ($tourBody['rooms'] ?? [] as $roomEntry) {
    $roomsById[$roomEntry['room_id']] = $roomEntry;
}
check('both rooms present', isset($roomsById[$roomAId]) && isset($roomsById[$roomBId]));

$standsA = $roomsById[$roomAId]['stands'] ?? null;
$standsB = $roomsById[$roomBId]['stands'] ?? null;
check('room A has stands array', is_array($standsA));
check('room A has 2 stands', is_array($standsA) && count($standsA) === 2);
check('room B has 1 stand', is_array($standsB) && count($standsB) === 1);

$nearDoorA = null;
foreach (is_array($standsA) ? $standsA : [] as $candidate) {
    foreach ($candidate['neighbours'] ?? [] as $n) {
        if (($n['room_id'] ?? null) === $roomBId) {
            $nearDoorA = $candidate;
            break 2;
        }
    }
}
check('a stand in room A links to room B', $nearDoorA !== null);

$standB = is_array($standsB) && isset($standsB[0]) ? $standsB[0] : null;
check('the B stand has a stand_id', is_string($standB['stand_id'] ?? null));
check('the B stand has exactly 1 photo', count($standB['photo_ids'] ?? []) === 1);

if ($nearDoorA !== null && $standB !== null) {
    check('the A stand has 2 neighbours', count($nearDoorA['neighbours'] ?? []) === 2);

    $aLinksBack = false;
    foreach ($standB['neighbours'] ?? [] as $n) {
        if (($n['stand_id'] ?? null) === $nearDoorA['stand_id']) {
            $aLinksBack = true;
            break;
        }
    }
    check('the B stand links back to the A stand', $aLinksBack);
}

check('tour.json does not leak depth_url', strpos(json_encode($tourBody), 'depth_url') === false);

echo "\n== Single-photo session ==\n";
[$createStatus2, $session2] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-stands-single',
    'unit_id' => 'unit-net-stands-single',
    'organisation_id' => 'org-net-stands',
    'purpose' => 'listing',
    'occupied' => false,
    'floor' => 'Ground',
]);
$session2Id = $session2['id'] ?? null;
$accessToken2 = $session2['access_token'] ?? null;
[, $capSingle] = capture_room($baseUrl, $session2Id, $accessToken2, room_capture('floor-only', [0.0, 0.0], [2.0, 4.0]));
$singleRoomId = $capSingle['rooms'][0]['room_id'] ?? null;
upload_photo($baseUrl, $session2Id, $accessToken2, $singleRoomId, 2.0, 2.0, 0.0, 'key-single');
[$tour2Status, $tour2Body] = net_http_json('GET', "$baseUrl/scan-sessions/$session2Id/tour.json", null, $accessToken2);
check('single-photo session tour.json 200', $tour2Status === 200);
check('single-photo session walkthrough false', ($tour2Body['features']['walkthrough'] ?? null) === false);

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
