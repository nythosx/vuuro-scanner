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
        'property_id' => 'prop-net-enterprise',
        'unit_id' => 'unit-net-enterprise',
        'organisation_id' => 'org-net-enterprise',
        'purpose' => 'listing',
        'occupied' => false,
    ];
}

echo "== GET /health ==\n";

[$healthStatus, $healthBody] = net_http_json('GET', "$baseUrl/health");
check('health endpoint returns HTTP 200', $healthStatus === 200, "got HTTP $healthStatus");
check('health body reports status ok', ($healthBody['status'] ?? null) === 'ok');

echo "\n== Token TTL bounds are enforced ==\n";

[$tooShortStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 1]);
check('a 1-second TTL (below the 60s floor) is rejected (HTTP 422)', $tooShortStatus === 422, "got HTTP $tooShortStatus");

[$tooLongStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 999999999]);
check('an absurdly long TTL (above the 1-year ceiling) is rejected (HTTP 422)', $tooLongStatus === 422, "got HTTP $tooLongStatus");

echo "\n== Token TTL boundary values (the edges themselves, not just clearly outside) ==\n";
$oneYearSeconds = 365 * 24 * 60 * 60;

[$exactMinStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 60]);
check('a TTL of exactly 60s (the documented floor) is ACCEPTED, not rejected', $exactMinStatus === 201, "got HTTP $exactMinStatus");

[$justBelowMinStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 59]);
check('a TTL of 59s (one below the floor) is still rejected (HTTP 422)', $justBelowMinStatus === 422, "got HTTP $justBelowMinStatus");

[$exactMaxStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => $oneYearSeconds]);
check('a TTL of exactly 365 days (the documented ceiling) is ACCEPTED, not rejected', $exactMaxStatus === 201, "got HTTP $exactMaxStatus");

[$justAboveMaxStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => $oneYearSeconds + 1]);
check('a TTL of 365 days + 1 second (one above the ceiling) is still rejected (HTTP 422)', $justAboveMaxStatus === 422, "got HTTP $justAboveMaxStatus");

echo "\n== Token rotation: old token dies, new token works ==\n";

[, $rotSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$rotId = $rotSession['id'] ?? null;
$rotOldToken = $rotSession['access_token'] ?? null;
check('session created for the rotation test', $rotId !== null && $rotOldToken !== null);

if ($rotId !== null && $rotOldToken !== null) {
    [$rotateStatus, $rotateBody] = net_http_json('POST', "$baseUrl/scan-sessions/$rotId/rotate-token", [], $rotOldToken);
    check('rotate-token succeeds with the current token (HTTP 200)', $rotateStatus === 200, "got HTTP $rotateStatus");
    $newToken = $rotateBody['access_token'] ?? null;
    check('rotate-token returns a new, different token', is_string($newToken) && $newToken !== '' && $newToken !== $rotOldToken);

    [$oldTokenStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$rotId", null, $rotOldToken);
    check('the OLD token is rejected immediately after rotation (HTTP 401)', $oldTokenStatus === 401, "got HTTP $oldTokenStatus");

    if (is_string($newToken)) {
        [$newTokenStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$rotId", null, $newToken);
        check('the NEW token works right away (HTTP 200)', $newTokenStatus === 200, "got HTTP $newTokenStatus");
    }
}

echo "\n== Token expiry is enforced, not just recorded ==\n";

[, $expSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 60]);
$expId = $expSession['id'] ?? null;
$expToken = $expSession['access_token'] ?? null;
if ($expId !== null && $expToken !== null) {
    [$stillLiveStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$expId", null, $expToken);
    check('a freshly issued 60s-TTL token is still valid seconds later (HTTP 200)', $stillLiveStatus === 200, "got HTTP $stillLiveStatus");
}

echo "\n== Token-expiry grace period: rotate-token recovers an expired token, other routes stay blocked ==\n";

$graceFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

[, $graceSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 60]);
$graceId = $graceSession['id'] ?? null;
$graceOldToken = $graceSession['access_token'] ?? null;
check('session created for the grace-period test', $graceId !== null && $graceOldToken !== null);

if ($graceId !== null && $graceOldToken !== null) {
    sleep(61);

    [$expiredCaptureStatus, $expiredCaptureBody] = net_http_json('POST', "$baseUrl/scan-sessions/$graceId/capture", ['raw_capture' => $graceFixture], $graceOldToken);
    check(
        'a normal action (capture) with an expired token is still hard-blocked within the grace window (HTTP 401)',
        $expiredCaptureStatus === 401 && ($expiredCaptureBody['error'] ?? null) === 'token_expired',
        'got HTTP ' . $expiredCaptureStatus . ' error=' . ($expiredCaptureBody['error'] ?? 'null') . ' — the grace period must NOT widen anything except rotate-token itself'
    );

    [$graceRotateStatus, $graceRotateBody] = net_http_json('POST', "$baseUrl/scan-sessions/$graceId/rotate-token", [], $graceOldToken);
    check(
        'rotate-token itself SUCCEEDS with the expired token, inside the grace window (HTTP 200)',
        $graceRotateStatus === 200,
        "got HTTP $graceRotateStatus — this is the permanent-lockout gap this fix closes"
    );
    $graceNewToken = $graceRotateBody['access_token'] ?? null;
    check('the recovered token is new and different from the expired one', is_string($graceNewToken) && $graceNewToken !== '' && $graceNewToken !== $graceOldToken);

    if (is_string($graceNewToken)) {
        [$postRecoveryStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$graceId", null, $graceNewToken);
        check('the recovered token actually works for a normal request afterward (HTTP 200)', $postRecoveryStatus === 200, "got HTTP $postRecoveryStatus");
    }
}

echo "\n== Capture idempotency: a retried upload must not double the room count ==\n";

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

[, $idemSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$idemId = $idemSession['id'] ?? null;
$idemToken = $idemSession['access_token'] ?? null;
check('session created for the idempotency test', $idemId !== null && $idemToken !== null);

if ($idemId !== null && $idemToken !== null) {
    $key = 'net-idem-key-' . bin2hex(random_bytes(8));

    [$firstStatus, $firstBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$idemId/capture", ['raw_capture' => $fixture], $idemToken, ['Idempotency-Key' => $key]);
    check('first capture with an Idempotency-Key succeeds (HTTP 200)', $firstStatus === 200, "got HTTP $firstStatus");
    $firstRoomCount = count($firstBody['rooms'] ?? []);
    check('first capture produced at least one room', $firstRoomCount > 0);

    [$retryStatus, $retryBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$idemId/capture", ['raw_capture' => $fixture], $idemToken, ['Idempotency-Key' => $key]);
    check('retried capture with the SAME Idempotency-Key succeeds (HTTP 200)', $retryStatus === 200, "got HTTP $retryStatus");
    $retryRoomCount = count($retryBody['rooms'] ?? []);
    check(
        'retried capture does NOT double the room count',
        $retryRoomCount === $firstRoomCount,
        "first call had $firstRoomCount room(s), retry had $retryRoomCount — a retried upload must replay the cached result, not reprocess"
    );

    [$secondRoomStatus, $secondRoomBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$idemId/capture", ['raw_capture' => $fixture], $idemToken, ['Idempotency-Key' => 'net-idem-key-' . bin2hex(random_bytes(8))]);
    check('a second capture with a DIFFERENT key still appends a new room (HTTP 200)', $secondRoomStatus === 200, "got HTTP $secondRoomStatus");
    $secondRoomCount = count($secondRoomBody['rooms'] ?? []);
    check(
        'a genuinely new capture call still grows the room count',
        $secondRoomCount === $firstRoomCount * 2,
        "expected " . ($firstRoomCount * 2) . " rooms after a real second capture, got $secondRoomCount — idempotency must not accidentally suppress legitimate multi-room stitching"
    );
}

echo "\n== Idempotency key REUSED with a different body must not silently replay the wrong result ==\n";

$lshapedFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);

[, $collisionSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$collisionId = $collisionSession['id'] ?? null;
$collisionToken = $collisionSession['access_token'] ?? null;
check('session created for the idempotency-collision test', $collisionId !== null && $collisionToken !== null);

if ($collisionId !== null && $collisionToken !== null) {
    $sharedKey = 'net-collision-key-' . bin2hex(random_bytes(8));

    [$firstCollisionStatus, $firstCollisionBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$collisionId/capture", ['raw_capture' => $fixture], $collisionToken, ['Idempotency-Key' => $sharedKey]);
    check('first capture under the shared key succeeds (HTTP 200)', $firstCollisionStatus === 200, "got HTTP $firstCollisionStatus");
    $firstCollisionRoomCount = count($firstCollisionBody['rooms'] ?? []);

    [$mismatchStatus, $mismatchBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$collisionId/capture", ['raw_capture' => $lshapedFixture], $collisionToken, ['Idempotency-Key' => $sharedKey]);
    check('reusing the key with a DIFFERENT body is rejected, not replayed (HTTP 409)', $mismatchStatus === 409, "got HTTP $mismatchStatus");
    check('rejection uses the idempotency_key_reused error code', ($mismatchBody['error'] ?? null) === 'idempotency_key_reused', 'got ' . json_encode($mismatchBody));

    [$afterStatus, $afterBody] = net_http_json_ex('GET', "$baseUrl/scan-sessions/$collisionId", null, $collisionToken, []);
    check('session GET succeeds after the rejected collision (HTTP 200)', $afterStatus === 200, "got HTTP $afterStatus");
    $afterRoomCount = count($afterBody['rooms'] ?? []);
    check(
        'room count is untouched by the rejected collision — only the first capture landed',
        $afterRoomCount === $firstCollisionRoomCount,
        "expected $firstCollisionRoomCount room(s) (only the first, accepted capture), got $afterRoomCount"
    );

    [$trueRetryStatus, $trueRetryBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$collisionId/capture", ['raw_capture' => $fixture], $collisionToken, ['Idempotency-Key' => $sharedKey]);
    check('a true retry (same key, same body) after a rejected collision still replays cleanly (HTTP 200)', $trueRetryStatus === 200, "got HTTP $trueRetryStatus");
    check(
        'the true retry still returns the original room count, unaffected by the rejected collision attempt',
        count($trueRetryBody['rooms'] ?? []) === $firstCollisionRoomCount
    );
}

echo "\n== A failed capture releases its Idempotency-Key claim instead of poisoning it ==\n";

$degenerateCapture = ['raw_capture' => ['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [0.001, 0, 0], [0.001, 0, 0.001], [0, 0, 0.001]]]]]];

[, $releaseSameBodySession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$releaseSameBodyId = $releaseSameBodySession['id'] ?? null;
$releaseSameBodyToken = $releaseSameBodySession['access_token'] ?? null;
check('session created for the same-bad-body release test', $releaseSameBodyId !== null && $releaseSameBodyToken !== null);
if ($releaseSameBodyId !== null && $releaseSameBodyToken !== null) {
    $key = 'net-release-samebody-' . bin2hex(random_bytes(8));
    [$firstStatus, ] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$releaseSameBodyId/capture", $degenerateCapture, $releaseSameBodyToken, ['Idempotency-Key' => $key]);
    check('first attempt with a degenerate capture is rejected (HTTP 422)', $firstStatus === 422, "got HTTP $firstStatus");

    [$retryStatus, $retryBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$releaseSameBodyId/capture", $degenerateCapture, $releaseSameBodyToken, ['Idempotency-Key' => $key]);
    check(
        'retrying the SAME key with the SAME still-bad body gets the real 422 again, not a stuck capture_in_progress 409',
        $retryStatus === 422 && ($retryBody['error'] ?? null) === 'unprocessable_capture',
        'got HTTP ' . $retryStatus . ' error=' . ($retryBody['error'] ?? 'none')
    );
}

[, $releaseFixedBodySession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$releaseFixedBodyId = $releaseFixedBodySession['id'] ?? null;
$releaseFixedBodyToken = $releaseFixedBodySession['access_token'] ?? null;
check('session created for the corrected-body release test', $releaseFixedBodyId !== null && $releaseFixedBodyToken !== null);
if ($releaseFixedBodyId !== null && $releaseFixedBodyToken !== null) {
    $key = 'net-release-fixedbody-' . bin2hex(random_bytes(8));
    [$firstStatus, ] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$releaseFixedBodyId/capture", $degenerateCapture, $releaseFixedBodyToken, ['Idempotency-Key' => $key]);
    check('first attempt with a degenerate capture is rejected (HTTP 422)', $firstStatus === 422, "got HTTP $firstStatus");

    [$retryStatus, ] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$releaseFixedBodyId/capture", ['raw_capture' => $fixture], $releaseFixedBodyToken, ['Idempotency-Key' => $key]);
    check(
        'retrying the SAME key with a CORRECTED body succeeds (HTTP 200), not stuck behind idempotency_key_reused',
        $retryStatus === 200,
        "got HTTP $retryStatus"
    );
}

echo "\n== Request body size cap ==\n";

$oversizedPropertyId = str_repeat('a', 9 * 1024 * 1024);
[$oversizedStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'property_id' => $oversizedPropertyId]);
check('a request body over the size cap is rejected (HTTP 413)', $oversizedStatus === 413, "got HTTP $oversizedStatus");

echo "\n== Request body size boundary (the exact byte count itself) ==\n";
$maxBodyBytes = 8 * 1024 * 1024;
$basePayloadForSizing = [...base_payload(), 'property_id' => ''];
$baseLength = strlen(json_encode($basePayloadForSizing, JSON_THROW_ON_ERROR));

$exactPadding = str_repeat('a', $maxBodyBytes - $baseLength);
$exactSizedBody = json_encode([...base_payload(), 'property_id' => $exactPadding], JSON_THROW_ON_ERROR);
check('constructed payload is exactly MAX_REQUEST_BODY_BYTES', strlen($exactSizedBody) === $maxBodyBytes, 'got ' . strlen($exactSizedBody) . ' bytes');
[$exactSizeStatus, ] = net_http_raw_literal('POST', "$baseUrl/scan-sessions", $exactSizedBody);
check(
    'a body of exactly MAX_REQUEST_BODY_BYTES is NOT rejected as 413 (fails later, on the unrelated 200-char field cap, instead)',
    $exactSizeStatus === 422,
    "got HTTP $exactSizeStatus"
);

$overByOnePadding = str_repeat('a', $maxBodyBytes - $baseLength + 1);
$overByOneBody = json_encode([...base_payload(), 'property_id' => $overByOnePadding], JSON_THROW_ON_ERROR);
check('constructed payload is exactly MAX_REQUEST_BODY_BYTES + 1', strlen($overByOneBody) === $maxBodyBytes + 1, 'got ' . strlen($overByOneBody) . ' bytes');
[$overByOneStatus, ] = net_http_raw_literal('POST', "$baseUrl/scan-sessions", $overByOneBody);
check('a body of exactly MAX_REQUEST_BODY_BYTES + 1 IS rejected (HTTP 413)', $overByOneStatus === 413, "got HTTP $overByOneStatus");

echo "\n== Request body size cap cannot be bypassed via chunked Transfer-Encoding ==\n";
$chunkedOversizedBody = json_encode([...base_payload(), 'property_id' => $oversizedPropertyId], JSON_THROW_ON_ERROR);
[$chunkedOversizedStatus, ] = net_http_raw_literal('POST', "$baseUrl/scan-sessions", $chunkedOversizedBody, null, ['Transfer-Encoding' => 'chunked']);
check(
    'the same over-the-cap body sent with chunked Transfer-Encoding (no Content-Length) is STILL rejected (HTTP 413)',
    $chunkedOversizedStatus === 413,
    "got HTTP $chunkedOversizedStatus"
);

echo "\n== Export routes (PNG/PDF) are rate-limited per session ==\n";


[, $exportRateLimitSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-export-throttle']);
$exportRateLimitSessionId = $exportRateLimitSession['id'] ?? null;
$exportRateLimitToken = $exportRateLimitSession['access_token'] ?? null;
check('session created for the export rate-limit test', $exportRateLimitSessionId !== null && $exportRateLimitToken !== null);

if ($exportRateLimitSessionId !== null && $exportRateLimitToken !== null) {
    $sawPngThrottle = false;
    for ($i = 0; $i < 35; $i++) {
        [$status, ] = net_http_raw('GET', "$baseUrl/scan-sessions/$exportRateLimitSessionId/export/floorplan.png", null, $exportRateLimitToken);
        if ($status === 429) {
            $sawPngThrottle = true;
            break;
        }
    }
    check('repeated PNG export calls against one session eventually hit HTTP 429', $sawPngThrottle, 'never saw a 429 across 35 rapid PNG export calls');

    $sawPdfThrottle = false;
    for ($i = 0; $i < 35; $i++) {
        [$status, ] = net_http_raw('GET', "$baseUrl/scan-sessions/$exportRateLimitSessionId/export/floorplan.pdf", null, $exportRateLimitToken);
        if ($status === 429) {
            $sawPdfThrottle = true;
            break;
        }
    }
    check('repeated PDF export calls against the SAME session ALSO eventually hit HTTP 429 (independent bucket, not shared with PNG)', $sawPdfThrottle, 'never saw a 429 across 35 rapid PDF export calls');
}

echo "\n== Capture route is rate-limited per session ==\n";

[, $captureRateLimitSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-capture-throttle']);
$captureRateLimitSessionId = $captureRateLimitSession['id'] ?? null;
$captureRateLimitToken = $captureRateLimitSession['access_token'] ?? null;
check('session created for the capture rate-limit test', $captureRateLimitSessionId !== null && $captureRateLimitToken !== null);

if ($captureRateLimitSessionId !== null && $captureRateLimitToken !== null) {
    $sawCaptureThrottle = false;
    for ($i = 0; $i < 65; $i++) {
        [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions/$captureRateLimitSessionId/capture", ['raw_capture' => $fixture], $captureRateLimitToken);
        if ($status === 429) {
            $sawCaptureThrottle = true;
            break;
        }
    }
    check('repeated capture calls against one session eventually hit HTTP 429', $sawCaptureThrottle, 'never saw a 429 across 65 rapid capture calls');
}

echo "\n== Photos/notes/rotate-token routes are rate-limited per session ==\n";

[, $writeRateLimitSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-write-throttle']);
$writeRateLimitSessionId = $writeRateLimitSession['id'] ?? null;
$writeRateLimitToken = $writeRateLimitSession['access_token'] ?? null;
check('session created for the photos/notes/rotate-token rate-limit test', $writeRateLimitSessionId !== null && $writeRateLimitToken !== null);

if ($writeRateLimitSessionId !== null && $writeRateLimitToken !== null) {
    $sawNoteThrottle = false;
    for ($i = 0; $i < 610; $i++) {
        [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions/$writeRateLimitSessionId/notes", ['text' => "note $i"], $writeRateLimitToken);
        if ($status === 429) {
            $sawNoteThrottle = true;
            break;
        }
    }
    check('repeated note-attach calls against one session eventually hit HTTP 429', $sawNoteThrottle, 'never saw a 429 across 610 rapid note-attach calls');

    $sawPhotoThrottle = false;
    for ($i = 0; $i < 65; $i++) {
        [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions/$writeRateLimitSessionId/photos", ['url' => "http://example.com/p$i.jpg"], $writeRateLimitToken);
        if ($status === 429) {
            $sawPhotoThrottle = true;
            break;
        }
    }
    check('repeated photo-attach calls against the SAME session ALSO eventually hit HTTP 429 (independent bucket, not shared with notes)', $sawPhotoThrottle, 'never saw a 429 across 65 rapid photo-attach calls');

    [, $rotateSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-rotate-throttle']);
    $rotateSessionId = $rotateSession['id'] ?? null;
    $rotateToken = $rotateSession['access_token'] ?? null;
    check('separate session created for the rotate-token rate-limit test', $rotateSessionId !== null && $rotateToken !== null);

    if ($rotateSessionId !== null && $rotateToken !== null) {
        $sawRotateThrottle = false;
        $currentToken = $rotateToken;
        for ($i = 0; $i < 15; $i++) {
            [$status, $body] = net_http_json('POST', "$baseUrl/scan-sessions/$rotateSessionId/rotate-token", [], $currentToken);
            if ($status === 429) {
                $sawRotateThrottle = true;
                break;
            }
            $currentToken = $body['access_token'] ?? $currentToken;
        }
        check('repeated rotate-token calls against one session eventually hit HTTP 429', $sawRotateThrottle, 'never saw a 429 across 15 rapid rotate-token calls');
    }
}

echo "\n== GET routes (session read, access-log) are rate-limited per session ==\n";

[, $readRateLimitSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-read-throttle']);
$readRateLimitSessionId = $readRateLimitSession['id'] ?? null;
$readRateLimitToken = $readRateLimitSession['access_token'] ?? null;
check('session created for the GET rate-limit test', $readRateLimitSessionId !== null && $readRateLimitToken !== null);

if ($readRateLimitSessionId !== null && $readRateLimitToken !== null) {
    $sawReadThrottle = false;
    for ($i = 0; $i < 125; $i++) {
        [$status, ] = net_http_raw('GET', "$baseUrl/scan-sessions/$readRateLimitSessionId", null, $readRateLimitToken);
        if ($status === 429) {
            $sawReadThrottle = true;
            break;
        }
    }
    check('repeated GET session calls eventually hit HTTP 429', $sawReadThrottle, 'never saw a 429 across 125 rapid GET session calls');

    $sawAccessLogThrottle = false;
    for ($i = 0; $i < 125; $i++) {
        [$status, ] = net_http_raw('GET', "$baseUrl/scan-sessions/$readRateLimitSessionId/access-log", null, $readRateLimitToken);
        if ($status === 429) {
            $sawAccessLogThrottle = true;
            break;
        }
    }
    check('repeated GET access-log calls against the SAME session ALSO eventually hit HTTP 429 (independent bucket, not shared with read)', $sawAccessLogThrottle, 'never saw a 429 across 125 rapid GET access-log calls');
}

echo "\n== Session-creation rate limit ==\n";

$sawRateLimited = false;
$sessionCreationLoopMax = (int) (getenv('VERIFY_SESSION_CREATION_LOOP_MAX') ?: 2050);
for ($i = 0; $i < $sessionCreationLoopMax; $i++) {
    [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
    if ($status === 429) {
        $sawRateLimited = true;
        break;
    }
}
check('repeated rapid session creation eventually hits HTTP 429', $sawRateLimited, "never saw a 429 across $sessionCreationLoopMax rapid session-creation calls");

echo "\n== Repeated lookups of NONEXISTENT session ids are also throttled ==\n";

$sawNotFoundThrottle = false;
for ($i = 0; $i < 80; $i++) {
    [$status, ] = net_http_json('GET', "$baseUrl/scan-sessions/does-not-exist-enterprise-net-$i", null, "guess-$i");
    if ($status === 429) {
        $sawNotFoundThrottle = true;
        break;
    }
}
check('repeated lookups of nonexistent session ids eventually hit HTTP 429', $sawNotFoundThrottle, 'never saw a 429 across 80 rapid nonexistent-session lookups');

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