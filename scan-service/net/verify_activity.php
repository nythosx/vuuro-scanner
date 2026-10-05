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

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

function make_session(string $baseUrl, string $org): array
{
    [, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-activity',
        'unit_id' => 'unit-net-activity',
        'organisation_id' => $org,
        'purpose' => 'listing',
        'occupied' => false,
        'floor' => 'Ground',
    ]);
    return $session;
}

echo "== POST /scan-sessions/activity returns last-capture dates for authorised sessions only ==\n";

$sessionA = make_session($baseUrl, 'org-net-activity-a');
$idA = $sessionA['id'] ?? null;
$tokenA = $sessionA['access_token'] ?? null;
check('session A created', $idA !== null && $tokenA !== null);
[, $planA] = net_http_json('POST', "$baseUrl/scan-sessions/$idA/capture", ['raw_capture' => $fixture, 'floor' => 'Ground'], $tokenA);
check('session A captured a room', ($planA['rooms'][0]['room_id'] ?? null) !== null);

$sessionB = make_session($baseUrl, 'org-net-activity-b');
$idB = $sessionB['id'] ?? null;
$tokenB = $sessionB['access_token'] ?? null;
check('session B created', $idB !== null && $tokenB !== null);
[, $planB] = net_http_json('POST', "$baseUrl/scan-sessions/$idB/capture", ['raw_capture' => $fixture, 'floor' => 'Ground'], $tokenB);
check('session B captured a room', ($planB['rooms'][0]['room_id'] ?? null) !== null);

[$status, $body] = net_http_json('POST', "$baseUrl/scan-sessions/activity", [
    'sessions' => [
        ['id' => $idA, 'token' => $tokenA],
        ['id' => $idB, 'token' => 'not-the-right-token'],
        ['id' => 'no-such-session-id', 'token' => 'whatever'],
    ],
]);
check('activity returns HTTP 200', $status === 200, "got HTTP $status");
$returnedIds = array_column($body['sessions'] ?? [], 'id');
check('only the authorised session is returned', $returnedIds === [$idA], json_encode($returnedIds));
$entryA = $body['sessions'][0] ?? null;
check('the returned entry carries captured_at', is_string($entryA['captured_at'] ?? null) && $entryA['captured_at'] !== '', json_encode($entryA));
check(
    'captured_at is not before the session was created',
    strtotime((string) $entryA['captured_at']) >= strtotime((string) $sessionA['created_at']),
    'captured_at=' . ($entryA['captured_at'] ?? 'null') . ' created_at=' . ($sessionA['created_at'] ?? 'null')
);

$roomsA = $entryA['rooms'] ?? null;
check('the returned entry lists its rooms', is_array($roomsA) && count($roomsA) === count($planA['rooms'] ?? []), json_encode($roomsA));
check(
    'each listed room carries label, floor and area',
    is_array($roomsA) && $roomsA !== [] && is_string($roomsA[0]['label'] ?? null) && ($roomsA[0]['floor'] ?? null) === 'Ground' && abs((float) ($roomsA[0]['floor_area_m2'] ?? 0) - (float) ($planA['rooms'][0]['floor_area_m2'] ?? -1)) < 0.001,
    json_encode($roomsA[0] ?? null)
);

[, $planA2] = net_http_json('POST', "$baseUrl/scan-sessions/$idA/capture", ['raw_capture' => $fixture, 'floor' => 'First'], $tokenA);
[, $body2] = net_http_json('POST', "$baseUrl/scan-sessions/activity", ['sessions' => [['id' => $idA, 'token' => $tokenA]]]);
$roomsA2 = $body2['sessions'][0]['rooms'] ?? [];
check('a later capture shows up in the room list', count($roomsA2) === count($planA2['rooms'] ?? []) && count($roomsA2) === count($roomsA ?? []) + 1, json_encode(array_column($roomsA2, 'floor')));
check('the new room keeps its own floor', in_array('First', array_column($roomsA2, 'floor'), true), json_encode(array_column($roomsA2, 'floor')));

echo "\n== /scan-sessions/activity is a real route, never treated as a session id ==\n";
[$getStatus] = net_http_json('GET', "$baseUrl/scan-sessions/activity", null, $tokenA);
check('GET on the activity path is not a session lookup (no such session id)', $getStatus !== 200, "got HTTP $getStatus");

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
