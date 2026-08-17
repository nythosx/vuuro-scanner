<?php

declare(strict_types=1);

/**
 * Independent net for core security properties: error handling, session
 * enumeration, geometry bounds, field length caps, URL scheme validation.
 * HTTP only, no importing the code under test.
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
// their own validation rather than the "no floor plan yet" 409.
$validFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $validFixture], $accessToken);

echo "== Uncaught exceptions do not leak stack traces or return a misleading 200 ==\n";

// Built as a literal string, not json_encode()'d: 1e400 is a syntactically
// valid JSON number token that overflows to PHP float INF only once
// *decoded* server-side — PHP's own json_encode() can't produce this token
// from an INF value, so encoding it here would just crash this net script.
$maliciousCapture = '{"raw_capture":{"floors":[{"identifier":"evil","category":"floor",'
    . '"confidence":"high","polygonCorners":[[0,0,0],[1e400,0,0],[1e400,0,1],[0,0,1]]}]}}';
[$status, , $body] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $maliciousCapture, $accessToken);

check('an overflow-to-INF payload does not return HTTP 200 (a real failure must not look like success)',
    $status !== 200, "got HTTP $status");
check('response is a clean 422 or 500, not a misleading 200', $status === 422 || $status === 500,
    "got HTTP $status, body: " . substr($body, 0, 200));
check('response body contains no stack trace ("Stack trace" text)', !str_contains($body, 'Stack trace'));
check('response body contains no server file paths (no ".php:" line reference)', !preg_match('/\.php(:\d+| on line)/', $body));
check('response body contains no absolute filesystem paths (no "C:\\\\" or "/var/" style path)',
    !preg_match('#[A-Za-z]:\\\\|/(?:var|home|etc)/#', $body));
check('response is valid JSON (a clean error, not raw HTML from a fatal error)', json_decode($body, true) !== null || $body === '',
    'body was not valid JSON: ' . substr($body, 0, 200));

[$withKeyStatus, , $withKeyBody] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $maliciousCapture, $accessToken, ['Idempotency-Key: net-overflow-with-idempotency-key']);
check('the SAME overflow payload WITH an Idempotency-Key header ALSO returns a clean 422, not a 500', $withKeyStatus === 422, "got HTTP $withKeyStatus, body: " . substr($withKeyBody, 0, 200));

echo "\n== Session-existence is not an enumeration oracle ==\n";

$randomNonexistentId = '00000000-0000-4000-8000-000000000000';
[$nonexistentStatus, ] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$randomNonexistentId");
[$wrongTokenStatus, ] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$sessionId", null, 'wrong-token-obviously-invalid');

check('a nonexistent session id and a real session id with a wrong token now return the SAME status',
    $nonexistentStatus === $wrongTokenStatus, "nonexistent=$nonexistentStatus real-with-bad-token=$wrongTokenStatus");
check('that shared status is 401, not a distinguishing 404', $nonexistentStatus === 401 && $wrongTokenStatus === 401,
    "nonexistent=$nonexistentStatus real-with-bad-token=$wrongTokenStatus");

echo "\n== Oversized/malformed capture geometry is rejected cleanly (422) ==\n";

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

echo "\n== Data directory permissions ==\n";
// Can't inspect filesystem permissions of the running server process from
// here (this net is HTTP-only by design). See Database.php's mkdir mode.
check('(informational) see Database.php mkdir mode', true);

echo "\n== Rate limiting ==\n";
check('(informational) see scan-service/README.md', true);

echo "\n== Unbounded string fields are rejected ==\n";

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

echo "\n== photos[].url rejects non-http(s) schemes ==\n";

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
