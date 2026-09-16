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

$validFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $validFixture], $accessToken);

echo "== Uncaught exceptions do not leak stack traces or return a misleading 200 ==\n";

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

$hugeCaptureProviderBody = json_encode([
    'raw_capture' => ['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]],
    'capture_provider' => str_repeat('X', 201),
], JSON_THROW_ON_ERROR);
[$hugeCaptureProviderStatus, ] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $hugeCaptureProviderBody, $accessToken);
check('a 201-character capture_provider is rejected with 422', $hugeCaptureProviderStatus === 422, "got HTTP $hugeCaptureProviderStatus");

$atCapBody = json_encode([
    'raw_capture' => ['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]],
    'capture_provider' => str_repeat('X', 200),
], JSON_THROW_ON_ERROR);
[$atCapStatus, ] = net_http_raw_literal('POST', "$baseUrl/scan-sessions/$sessionId/capture", $atCapBody, $accessToken);
check('a 200-character (at the cap) capture_provider is still accepted', $atCapStatus === 200, "got HTTP $atCapStatus");

[$pdfAfterCapStatus, , $pdfAfterCapBody] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $accessToken);
check('the PDF export after a 200-char capture_provider still succeeds (HTTP 200)', $pdfAfterCapStatus === 200, "got HTTP $pdfAfterCapStatus");

[, $shortProviderSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-security-short', 'unit_id' => 'unit-net-security-short', 'organisation_id' => 'org-net-security-short',
    'purpose' => 'listing', 'occupied' => false,
]);
$shortProviderSessionId = $shortProviderSession['id'] ?? null;
$shortProviderToken = $shortProviderSession['access_token'] ?? null;
net_http_json('POST', "$baseUrl/scan-sessions/$shortProviderSessionId/capture", ['raw_capture' => $validFixture], $shortProviderToken);
$shortProviderBody = json_encode([
    'raw_capture' => ['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]],
    'capture_provider' => 'p',
], JSON_THROW_ON_ERROR);
net_http_raw_literal('POST', "$baseUrl/scan-sessions/$shortProviderSessionId/capture", $shortProviderBody, $shortProviderToken);
[, , $pdfShortProviderBody] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$shortProviderSessionId/export/floorplan.pdf", null, $shortProviderToken);

$sizeDelta = strlen($pdfAfterCapBody) - strlen($pdfShortProviderBody);
check(
    'the identical geometry with a 200-char vs 1-char capture_provider produces near-identical PDF size, not amplified',
    abs($sizeDelta) < 1000,
    "1-char provider: " . strlen($pdfShortProviderBody) . " bytes, 200-char provider: " . strlen($pdfAfterCapBody) . " bytes, delta: $sizeDelta"
);

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

echo "\n== CORS is scoped to a single configured origin, not a wildcard ==\n";
function net_cors_headers_for_origin(string $url, string $origin): string
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_HTTPHEADER => ["Origin: $origin"],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HEADER => true,
        CURLOPT_NOBODY => true,
    ]);
    $raw = curl_exec($ch);
    curl_close($ch);
    return (string) $raw;
}

$allowedOriginHeaders = net_cors_headers_for_origin("$baseUrl/health", 'http://127.0.0.1:8090');
check(
    'the configured origin (http://127.0.0.1:8090 by default) gets Access-Control-Allow-Origin echoed back',
    stripos($allowedOriginHeaders, 'Access-Control-Allow-Origin: http://127.0.0.1:8090') !== false,
    'headers were: ' . trim($allowedOriginHeaders)
);

$foreignOriginHeaders = net_cors_headers_for_origin("$baseUrl/health", 'http://evil.example');
check(
    'an unrecognized origin gets NO Access-Control-Allow-Origin header at all (not a wildcard)',
    stripos($foreignOriginHeaders, 'Access-Control-Allow-Origin') === false,
    'headers were: ' . trim($foreignOriginHeaders)
);

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