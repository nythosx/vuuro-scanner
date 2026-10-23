<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$adminApiKey = $argv[2] ?? 'net-test-admin-key';
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

echo "== The app can store a photo step report per session, and admin can read it ==\n";

$suffix = substr(md5((string) microtime(true)), 0, 8);
[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => "prop-net-events-$suffix", 'unit_id' => "unit-net-events-$suffix", 'organisation_id' => "org-net-events-$suffix",
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $session['id'];
$accessToken = $session['access_token'];
$other = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => "prop-net-events-b-$suffix", 'unit_id' => "unit-net-events-b-$suffix", 'organisation_id' => "org-net-events-$suffix",
    'purpose' => 'listing', 'occupied' => false,
])[1];

$report = [
    'kind' => 'photo_step_summary',
    'payload' => [
        'build' => 'abc1234',
        'trigger' => 'after_scan',
        'capture_group_id' => 'walk-1',
        'server_room_count' => 1,
        'pairing' => 'single_room',
        'photos_taken' => 30,
        'photos_uploaded' => 28,
        'photos_failed' => 2,
        'skip_reason' => null,
        'failures' => [['photo_id' => 'p1', 'reason' => 'The request timed out.']],
        'rooms' => [['room_key' => 'r1', 'photos' => 30, 'coverage' => ['overall' => 0.66, 'position' => 0.57, 'walls' => 0.75, 'ready' => false, 'walls_total' => 8, 'walls_covered' => 6]]],
    ],
];

[$noTokenStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/client-events", $report);
check('a report without the access token is rejected (HTTP 401)', $noTokenStatus === 401, "got HTTP $noTokenStatus");

[$otherTokenStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/client-events", $report, $other['access_token']);
check("another session's token cannot write to this session (HTTP 401)", $otherTokenStatus === 401, "got HTTP $otherTokenStatus");

[$postStatus, $postBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/client-events", $report, $accessToken);
check('a valid report is stored (HTTP 201)', $postStatus === 201, "got HTTP $postStatus");
check('the stored report echoes its kind', ($postBody['kind'] ?? null) === 'photo_step_summary');

[$badKindStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/client-events", ['kind' => 'anything', 'payload' => []], $accessToken);
check('an unknown kind is rejected (HTTP 422)', $badKindStatus === 422, "got HTTP $badKindStatus");

[$listPayloadStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/client-events", ['kind' => 'photo_step_summary', 'payload' => [1, 2, 3]], $accessToken);
check('a payload that is a list instead of an object is rejected (HTTP 422)', $listPayloadStatus === 422, "got HTTP $listPayloadStatus");

$huge = ['kind' => 'photo_step_summary', 'payload' => ['blob' => str_repeat('x', 70 * 1024)]];
[$hugeStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/client-events", $huge, $accessToken);
check('a report over 64 KB is rejected (HTTP 413)', $hugeStatus === 413, "got HTTP $hugeStatus");

[$ownReadStatus, $ownRead] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/client-events", null, $accessToken);
check('the session token can read its own reports (HTTP 200)', $ownReadStatus === 200, "got HTTP $ownReadStatus");
$events = $ownRead['client_events'] ?? [];
check('exactly one report was stored', count($events) === 1, 'got ' . count($events));
check('the stored payload round-trips', ($events[0]['payload']['photos_uploaded'] ?? null) === 28 && ($events[0]['payload']['rooms'][0]['coverage']['walls_total'] ?? null) === 8);

[$adminStatus, $adminRead] = net_http_json_ex('GET', "$baseUrl/scan-sessions/$sessionId/client-events", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('admin can read the reports with the admin key (HTTP 200)', $adminStatus === 200, "got HTTP $adminStatus");
check('admin sees the same report', count($adminRead['client_events'] ?? []) === 1);

[$adminWriteStatus, ] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$sessionId/client-events", $report, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('the admin key alone cannot write a report (HTTP 401)', $adminWriteStatus === 401, "got HTTP $adminWriteStatus");

[$deleteStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('the session can be deleted', $deleteStatus === 200 || $deleteStatus === 204, "got HTTP $deleteStatus");
[$afterDeleteStatus, ] = net_http_json_ex('GET', "$baseUrl/scan-sessions/$sessionId/client-events", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('reports are gone with the deleted session', $afterDeleteStatus === 404 || $afterDeleteStatus === 401, "got HTTP $afterDeleteStatus");

net_http_json('DELETE', "$baseUrl/scan-sessions/{$other['id']}", null, $other['access_token']);

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    echo "\nNET VERDICT: RED\n";
    foreach ($failures as $failure) {
        echo " - $failure\n";
    }
    exit(1);
}
echo "\nNET VERDICT: GREEN\n";
