<?php

declare(strict_types=1);

/**
 * Independent net that re-runs the exact exploits found during the manual
 * security review (see the ReportFindings output from that session) against
 * the live HTTP API, and confirms each is now closed. Same rules as the
 * other net scripts: HTTP only, no importing the fixed code.
 *
 * Usage: php net/verify_security_fixes.php [base_url]
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

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-security',
    'unit_id' => 'unit-net-security',
    'organisation_id' => 'org-net-security',
    'purpose' => 'listing',
    'occupied' => false,
]);
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
if ($sessionId === null || $accessToken === null) {
    fwrite(STDERR, "Could not create a session — cannot continue.\n");
    exit(1);
}

// A legitimate capture first, so the photos[]/notes[] checks below exercise
// their own validation (422/201) rather than tripping the unrelated
// "no floor plan yet" 409 that photos/notes correctly return before any
// capture exists.
$validFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $validFixture], $accessToken);

echo "== Finding 1: uncaught exception no longer leaks stack traces / returns misleading 200 ==\n";

// Built as a literal string, not json_encode()'d: 1e400 is a syntactically
// valid JSON number token (this is what a real attacker would send on the
// wire) that overflows to PHP float INF only once *decoded* server-side —
// PHP's own json_encode() can't produce this token from an INF value in
// the first place, so encoding it here would just crash this net script.
$maliciousCapture = '{"raw_capture":{"floors":[{"identifier":"evil","category":"floor",'
    . '"confidence":"high","polygonCorners":[[0,0,0],[1e400,0,0],[1e400,0,1],[0,0,1]]}]}}';
[$status, , $body] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $maliciousCapture, $accessToken);

check('the previously-crashing payload no longer returns HTTP 200 (a real failure must not look like success)',
    $status !== 200, "got HTTP $status");
check('response is not the misleading 200 exactly reproduced during the review', $status === 422 || $status === 500,
    "got HTTP $status, body: " . substr($body, 0, 200));
check('response body contains no stack trace ("Stack trace" text)', !str_contains($body, 'Stack trace'));
check('response body contains no server file paths (no ".php:" line reference)', !preg_match('/\.php(:\d+| on line)/', $body));
check('response body contains no absolute filesystem paths (no "C:\\\\" or "/var/" style path)',
    !preg_match('#[A-Za-z]:\\\\|/(?:var|home|etc)/#', $body));
check('response is valid JSON (a clean error, not raw HTML from a fatal error)', json_decode($body, true) !== null || $body === '',
    'body was not valid JSON: ' . substr($body, 0, 200));

// Full-functionality scan finding, adjacent to Finding 1 above: the same
// overflow-to-INF payload, sent WITH an Idempotency-Key header (this
// project's own README recommends every real client send one on capture),
// used to bypass this fix entirely and crash with a raw 500 instead of the
// clean 422 the identical payload gets without the header. Root cause:
// public/index.php's idempotencyFingerprint() ran json_encode(...,
// JSON_THROW_ON_ERROR) on the raw, not-yet-validated raw_capture BEFORE
// RoomPlanSimulatorAdapter's own overflow check ever ran — JSON_THROW_ON_ERROR
// throws an uncaught JsonException on INF/NaN ("Inf and NaN cannot be JSON
// encoded"). Fixed by falling back to serialize() (no such restriction) only
// when json_encode() can't represent the value. This must return the exact
// same clean 422 as the header-less case above, not a 500.
[$withKeyStatus, , $withKeyBody] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $maliciousCapture, $accessToken, ['Idempotency-Key: net-overflow-with-idempotency-key']);
check('the SAME overflow payload WITH an Idempotency-Key header ALSO returns a clean 422, not a 500', $withKeyStatus === 422, "got HTTP $withKeyStatus, body: " . substr($withKeyBody, 0, 200));

echo "\n== Finding 2: session-existence enumeration oracle closed ==\n";

$randomNonexistentId = '00000000-0000-4000-8000-000000000000';
[$nonexistentStatus, ] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$randomNonexistentId");
[$wrongTokenStatus, ] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$sessionId", null, 'wrong-token-obviously-invalid');

check('a nonexistent session id and a real session id with a wrong token now return the SAME status',
    $nonexistentStatus === $wrongTokenStatus, "nonexistent=$nonexistentStatus real-with-bad-token=$wrongTokenStatus");
check('that shared status is 401, not a distinguishing 404', $nonexistentStatus === 401 && $wrongTokenStatus === 401,
    "nonexistent=$nonexistentStatus real-with-bad-token=$wrongTokenStatus");

echo "\n== Finding 3: oversized/malformed capture geometry rejected cleanly (422), not left to crash ==\n";

$hugeButFiniteCapture = json_encode([
    'raw_capture' => [
        'floors' => [[
            'identifier' => 'huge',
            'category' => 'floor',
            'confidence' => 'high',
            'polygonCorners' => [[0, 0, 0], [50000, 0, 0], [50000, 0, 1], [0, 0, 1]],
        ]],
    ],
], JSON_THROW_ON_ERROR);
[$hugeStatus, , $hugeBody] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $hugeButFiniteCapture, $accessToken);
check('a 50000m coordinate is rejected with a clean 422, not accepted', $hugeStatus === 422, "got HTTP $hugeStatus, body: " . substr($hugeBody, 0, 200));

echo "\n== Finding 4: data directory is no longer created world-writable ==\n";
// Can't inspect filesystem permissions of the running server process from
// here (this net is HTTP-only by design, like the others) — this is
// covered by direct inspection during the fix, not re-verified over HTTP.
check('(informational) see Database.php — mkdir mode changed from 0777 to 0750', true);

echo "\n== Finding 5: still no rate limiting (accepted trade-off, not re-tested here) ==\n";
check('(informational) unchanged by design for this local-dev-only slice — see scan-service/README.md', true);

echo "\n== Finding 6: unbounded string fields now rejected ==\n";

$hugePropertyId = str_repeat('a', 201);
[$hugeFieldStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => $hugePropertyId,
    'unit_id' => 'u',
    'organisation_id' => 'o',
    'purpose' => 'listing',
    'occupied' => false,
]);
check('a 201-character property_id is rejected with 422', $hugeFieldStatus === 422, "got HTTP $hugeFieldStatus");

$hugeNoteText = str_repeat('n', 5001);
[$hugeNoteStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => $hugeNoteText], $accessToken);
check('a 5001-character note text is rejected with 422', $hugeNoteStatus === 422, "got HTTP $hugeNoteStatus");

echo "\n== Finding 7: photos[].url rejects non-http(s) schemes ==\n";

[$jsUrlStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'javascript:alert(1)'], $accessToken);
check('a javascript: URL is rejected with 422', $jsUrlStatus === 422, "got HTTP $jsUrlStatus");

[$dataUrlStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'data:text/html,<script>alert(1)</script>'], $accessToken);
check('a data: URL is rejected with 422', $dataUrlStatus === 422, "got HTTP $dataUrlStatus");

[$validUrlStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.invalid/photo.jpg'], $accessToken);
check('a legitimate https:// URL is still accepted', $validUrlStatus === 201, "got HTTP $validUrlStatus");

echo "\n== Defense-in-depth: X-Content-Type-Options header present ==\n";

[, $responseHeaders] = net_http_headers('GET', "$baseUrl/scan-sessions/$sessionId", $accessToken);
check('response includes X-Content-Type-Options: nosniff', stripos($responseHeaders, 'X-Content-Type-Options: nosniff') !== false,
    "headers were: " . trim($responseHeaders));

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
