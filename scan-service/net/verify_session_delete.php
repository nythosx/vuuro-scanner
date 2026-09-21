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

function base_payload(): array
{
    return [
        'property_id' => 'prop-net-delete',
        'unit_id' => 'unit-net-delete',
        'organisation_id' => 'org-net-delete',
        'purpose' => 'listing',
        'occupied' => false,
    ];
}

echo "== DELETE removes a real session ==\n";

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$sessionId = $session['id'] ?? null;
$token = $session['access_token'] ?? null;
check('session created', $sessionId !== null && $token !== null);

if ($sessionId !== null && $token !== null) {
    [$beforeStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $token);
    check('session is reachable before delete (HTTP 200)', $beforeStatus === 200, "got HTTP $beforeStatus");

    $rawCapture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true);
    [$captureStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $rawCapture], $token);
    check('a room was captured before delete (HTTP 200)', $captureStatus === 200, "got HTTP $captureStatus");

    [$deleteStatus, $deleteBody] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId", null, $token);
    check('delete succeeds (HTTP 200)', $deleteStatus === 200, "got HTTP $deleteStatus");
    check('delete response confirms deletion', ($deleteBody['deleted'] ?? null) === true);

    [$afterStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $token);
    check('the same token no longer authenticates after delete (HTTP 401)', $afterStatus === 401, "got HTTP $afterStatus");

    [$secondDeleteStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId", null, $token);
    check('a second delete attempt is also rejected (HTTP 401), not a crash', $secondDeleteStatus === 401, "got HTTP $secondDeleteStatus");
}

echo "\n== DELETE is authenticated like every other session route ==\n";

[$otherCreateStatus, $otherSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$otherId = $otherSession['id'] ?? null;
check('second session created for the wrong-token case', $otherId !== null, "got HTTP $otherCreateStatus: " . json_encode($otherSession));

if ($otherId !== null) {
    [$wrongTokenStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$otherId", null, 'not-the-real-token');
    check('delete with the wrong token is rejected (HTTP 401)', $wrongTokenStatus === 401, "got HTTP $wrongTokenStatus");

    [$stillThereStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$otherId", null, $otherSession['access_token']);
    check('the session survives a rejected delete attempt', $stillThereStatus === 200, "got HTTP $stillThereStatus");
}

echo "\n";
echo count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    echo "\nNET VERDICT: RED\n";
    foreach ($failures as $failure) {
        echo " - $failure\n";
    }
    exit(1);
}
echo "\nNET VERDICT: GREEN\n";
