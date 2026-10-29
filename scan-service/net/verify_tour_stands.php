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

function upload_photo(string $baseUrl, string $sessionId, string $token, string $roomId, float $x, float $z, float $heading, string $key, string $standId = ''): int
{
    $tmp = tempnam(sys_get_temp_dir(), 'tour_stand_') . '.jpg';
    $img = imagecreatetruecolor(32, 32);
    imagefilledrectangle($img, 0, 0, 32, 32, imagecolorallocate($img, 100, 150, 200));
    imagejpeg($img, $tmp, 85);
    imagedestroy($img);

    $ch = curl_init("$baseUrl/scan-sessions/$sessionId/photos-360");
    $fields = [
        'photo' => new \CURLFile($tmp, 'image/jpeg', 'photo.jpg'),
        'room_id' => $roomId,
        'position_x' => (string) $x,
        'position_z' => (string) $z,
        'heading_deg' => (string) $heading,
    ];
    if ($standId !== '') {
        $fields['stand_id'] = $standId;
    }
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ["X-Scan-Access-Token: $token", "Idempotency-Key: $key"],
        CURLOPT_POSTFIELDS => $fields,
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

$upA1 = upload_photo($baseUrl, $sessionId, $accessToken, $roomAId, 2.0, 3.5, 0.0, 'key-a1', 'stand-a-door');
$upA2 = upload_photo($baseUrl, $sessionId, $accessToken, $roomAId, 0.5, 0.5, 90.0, 'key-a2', 'stand-a-far');
$upA3 = upload_photo($baseUrl, $sessionId, $accessToken, $roomAId, 2.1, 3.6, 180.0, 'key-a3', 'stand-a-door');
$upB1 = upload_photo($baseUrl, $sessionId, $accessToken, $roomBId, 2.0, 1.5, 270.0, 'key-b1', 'stand-b');
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

echo "
== Photo tour without stands ==
";
upload_photo($baseUrl, $session2Id, $accessToken2, $singleRoomId, 0.5, 0.5, 90.0, 'key-spread-1');
upload_photo($baseUrl, $session2Id, $accessToken2, $singleRoomId, 3.5, 3.5, 180.0, 'key-spread-2');
[$tour3Status, $tour3Body] = net_http_json('GET', "$baseUrl/scan-sessions/$session2Id/tour.json", null, $accessToken2);
check('photo tour without stand_id tour.json 200', $tour3Status === 200);
check('photo tour without stand_id has several stands', count($tour3Body['rooms'][0]['stands'] ?? []) >= 2);
check('photo tour without stand_id keeps walkthrough false', ($tour3Body['features']['walkthrough'] ?? null) === false);

echo "\n== Tour start view picker ==\n";
[$shellStatus, , $shellBody] = net_http_raw('GET', "$baseUrl/tour/$sessionId", null, null);
$svPos = strpos((string) $shellBody, '/tour/tour-start-view.js');
$tjPos = strpos((string) $shellBody, '/tour/tour.js');
$orderOk = $shellStatus === 200 && $svPos !== false && $tjPos !== false && $svPos < $tjPos;
check('tour shell loads tour-start-view.js before tour.js', $orderOk,
    "status=$shellStatus svPos=" . var_export($svPos, true) . " tjPos=" . var_export($tjPos, true));

[$svJsStatus, , $svJsBody] = net_http_raw('GET', "$baseUrl/tour/tour-start-view.js", null, null);
check('tour-start-view.js is served', $svJsStatus === 200, "got HTTP $svJsStatus");
check('tour-start-view.js contains TourStartView', strpos((string) $svJsBody, 'TourStartView') !== false);

$nodeCheckCmd = PHP_OS_FAMILY === 'Windows' ? 'where node' : 'command -v node';
exec($nodeCheckCmd . ' 2>&1', $nodeLines, $nodeCode);
$nodePath = $nodeCode === 0 && !empty($nodeLines) ? trim((string) $nodeLines[0]) : '';
if ($nodePath === '') {
    echo "  [SKIP] node not found on PATH - skipping pickStartView node assertions\n";
} else {
    $nodeScriptSrc = <<<'NODEJS'
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(src, sandbox);
if (!sandbox.window.TourStartView || typeof sandbox.window.TourStartView.pick !== 'function') {
  console.error('TourStartView.pick is not a function');
  process.exit(1);
}
const pick = sandbox.window.TourStartView.pick;
const allTrue = { walkthrough: true, hasStand: true, hasDollhouse: true, hasPhotos: true };
const allFalse = { walkthrough: false, hasStand: false, hasDollhouse: false, hasPhotos: false };
const cases = [
  ['all', true, allTrue, 'walkthrough'],
  ['all', true, { walkthrough: false, hasStand: false, hasDollhouse: true, hasPhotos: true }, 'dollhouse'],
  ['all', true, { walkthrough: true, hasStand: false, hasDollhouse: false, hasPhotos: true }, 'photos'],
  ['all', true, allFalse, 'plan'],
  ['all', false, allTrue, 'plan'],
  ['dollhouse', false, allFalse, 'plan']
];
let bad = 0;
for (const c of cases) {
  const actual = pick(c[0], c[1], c[2]);
  if (actual !== c[3]) {
    console.error('FAIL ' + JSON.stringify(c) + ' -> ' + actual);
    bad++;
  }
}
process.exit(bad === 0 ? 0 : 1);
NODEJS;
    $nodeScriptPath = tempnam(sys_get_temp_dir(), 'tour_sv_node_') . '.js';
    file_put_contents($nodeScriptPath, $nodeScriptSrc);
    $svJsDisk = __DIR__ . '/../public/tour/tour-start-view.js';
    $proc = proc_open(
        [$nodePath, $nodeScriptPath, $svJsDisk],
        [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    $nodeOut = '';
    $nodeExit = 1;
    if (is_resource($proc)) {
        $nodeOut = (string) stream_get_contents($pipes[1]) . (string) stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $nodeExit = proc_close($proc);
    }
    @unlink($nodeScriptPath);
    check('node: six pickStartView cases pass', $nodeExit === 0, trim($nodeOut));
}

echo "\n== Tour stand deep link ==\n";
[$standsJsStatus, , $standsJsBody] = net_http_raw('GET', "$baseUrl/tour/tour-stands.js", null, null);
check('tour-stands.js is served', $standsJsStatus === 200, "got HTTP $standsJsStatus");
check('tour-stands.js supports initialPhotoIndex', strpos((string) $standsJsBody, 'initialPhotoIndex') !== false);
check('tour-stands.js preloads neighbours', strpos((string) $standsJsBody, 'preloadNeighbours') !== false);

[$tourJsStatus, , $tourJsBody] = net_http_raw('GET', "$baseUrl/tour/tour.js", null, null);
check('tour.js is served', $tourJsStatus === 200, "got HTTP $tourJsStatus");
check('tour.js passes standPhotoIndex to the stand renderer', strpos((string) $tourJsBody, 'standPhotoIndex') !== false);

echo "\n== Tour stand floor filter ==\n";
[$floorsJsStatus, , $floorsJsBody] = net_http_raw('GET', "$baseUrl/tour/tour-stands.js", null, null);
check('tour-stands.js is served (floor filter)', $floorsJsStatus === 200, "got HTTP $floorsJsStatus");
check('tour-stands.js declares tour-stand-floors', strpos((string) $floorsJsBody, 'tour-stand-floors') !== false);
check('tour-stands.js toggles has-stand-floors', strpos((string) $floorsJsBody, 'has-stand-floors') !== false);

[$floorsCssStatus, , $floorsCssBody] = net_http_raw('GET', "$baseUrl/tour/tour.css", null, null);
check('tour.css is served (floor filter)', $floorsCssStatus === 200, "got HTTP $floorsCssStatus");
check('tour.css styles tour-stand-floor-chip', strpos((string) $floorsCssBody, 'tour-stand-floor-chip') !== false);
check('tour.css nudges .tour-toolbar for stand floors', strpos((string) $floorsCssBody, 'is-stand.has-stand-floors') !== false);

echo "\n== Tour guided tour ==\n";
[$gtStatus, , $gtBody] = net_http_raw('GET', "$baseUrl/tour/tour.js", null, null);
check('tour.js is served (guided tour)', $gtStatus === 200, "got HTTP $gtStatus");
check('tour.js declares guidedTourActive', strpos((string) $gtBody, 'guidedTourActive') !== false);
check('tour.js declares guidedTourQueue', strpos((string) $gtBody, 'guidedTourQueue') !== false);
check('tour.js declares scheduleNextGuidedStep', strpos((string) $gtBody, 'scheduleNextGuidedStep') !== false);
check('tour.js declares GUIDED_TOUR_STEP_MS', strpos((string) $gtBody, 'GUIDED_TOUR_STEP_MS') !== false);

[$gsStatus, , $gsBody] = net_http_raw('GET', "$baseUrl/tour/tour-stand-strings.js", null, null);
check('tour-stand-strings.js is served (guided tour)', $gsStatus === 200, "got HTTP $gsStatus");
check('tour-stand-strings.js has tour_play_label', strpos((string) $gsBody, 'tour_play_label') !== false);
check('tour-stand-strings.js has tour_stop_label', strpos((string) $gsBody, 'tour_stop_label') !== false);

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
