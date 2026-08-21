<?php

declare(strict_types=1);

/**
 * Independent net for the enterprise-hardening pass: token expiry/rotation,
 * fixed-window rate limiting, capture idempotency, request body size cap,
 * and the /health endpoint. Same rules as every other net script — HTTP
 * only, never imports ScanSessionRepository/index.php, re-derives its own
 * expected values (e.g. "room count must NOT double" for the idempotency
 * check) rather than re-running the same code path and comparing to itself.
 *
 * Usage: php net/verify_enterprise_hardening.php [base_url]
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

// "Between min and max" is documented (public/index.php) as inclusive, so
// both boundary values themselves must be ACCEPTED, not rejected.
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
// 60 is the minimum allowed TTL, so this can't be shrunk further via the
// public API to make the test fast.
$expId = $expSession['id'] ?? null;
$expToken = $expSession['access_token'] ?? null;
if ($expId !== null && $expToken !== null) {
    [$stillLiveStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$expId", null, $expToken);
    check('a freshly issued 60s-TTL token is still valid seconds later (HTTP 200)', $stillLiveStatus === 200, "got HTTP $stillLiveStatus");
}

// rotate-token accepts an expired-but-correct token within a 7-day grace
// window (ScanSessionRepository::ROTATE_GRACE_PERIOD_SECONDS); every other
// action stays hard-blocked at the instant of expiry. Proven here with a
// real 60-second-TTL token actually left to expire, over real HTTP.
echo "\n== Token-expiry grace period: rotate-token recovers an expired token, other routes stay blocked ==\n";

$graceFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

[, $graceSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'access_token_ttl_seconds' => 60]);
$graceId = $graceSession['id'] ?? null;
$graceOldToken = $graceSession['access_token'] ?? null;
check('session created for the grace-period test', $graceId !== null && $graceOldToken !== null);

if ($graceId !== null && $graceOldToken !== null) {
    sleep(61); // let the 60s token actually expire

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
    // The specific bug this net exists to catch: a naive "just retry" client
    // without idempotency support would see the room count double here
    // (2 instead of 1) because appendCapture() would run a second time.
    check(
        'retried capture does NOT double the room count',
        $retryRoomCount === $firstRoomCount,
        "first call had $firstRoomCount room(s), retry had $retryRoomCount — a retried upload must replay the cached result, not reprocess"
    );

    // Adjacent case: a DIFFERENT Idempotency-Key for the same session must
    // still behave like a normal second room capture (Phase 2's multi-room
    // stitching), not get accidentally deduplicated by session id alone.
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

    // The bug this proves is fixed: reusing the SAME Idempotency-Key with a
    // genuinely DIFFERENT raw_capture (a different room, here the L-shaped
    // fixture) must be rejected, not silently answered with the first
    // capture's stale cached response — that would make the second, real
    // room vanish from the client's point of view while returning HTTP 200.
    [$mismatchStatus, $mismatchBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$collisionId/capture", ['raw_capture' => $lshapedFixture], $collisionToken, ['Idempotency-Key' => $sharedKey]);
    check('reusing the key with a DIFFERENT body is rejected, not replayed (HTTP 409)', $mismatchStatus === 409, "got HTTP $mismatchStatus");
    check('rejection uses the idempotency_key_reused error code', ($mismatchBody['error'] ?? null) === 'idempotency_key_reused', 'got ' . json_encode($mismatchBody));

    // The room count must be exactly what the first, accepted capture
    // produced — the rejected second attempt must not have appended
    // anything, and the room count must not have been silently doubled by a
    // stale-response replay either.
    [$afterStatus, $afterBody] = net_http_json_ex('GET', "$baseUrl/scan-sessions/$collisionId", null, $collisionToken, []);
    check('session GET succeeds after the rejected collision (HTTP 200)', $afterStatus === 200, "got HTTP $afterStatus");
    $afterRoomCount = count($afterBody['rooms'] ?? []);
    check(
        'room count is untouched by the rejected collision — only the first capture landed',
        $afterRoomCount === $firstCollisionRoomCount,
        "expected $firstCollisionRoomCount room(s) (only the first, accepted capture), got $afterRoomCount"
    );

    // Adjacent-adjacent case: reusing the shared key with the ORIGINAL body
    // again (a genuine retry, not a collision) must still work exactly as
    // the retry test above proves — this key's fingerprint check must not
    // have turned every retry into a false-positive rejection.
    [$trueRetryStatus, $trueRetryBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/$collisionId/capture", ['raw_capture' => $fixture], $collisionToken, ['Idempotency-Key' => $sharedKey]);
    check('a true retry (same key, same body) after a rejected collision still replays cleanly (HTTP 200)', $trueRetryStatus === 200, "got HTTP $trueRetryStatus");
    check(
        'the true retry still returns the original room count, unaffected by the rejected collision attempt',
        count($trueRetryBody['rooms'] ?? []) === $firstCollisionRoomCount
    );
}

echo "\n== A failed capture releases its Idempotency-Key claim instead of poisoning it ==\n";

// ACL-surface scan finding — a real correctness bug, not just table growth:
// every 422 path after claimIdempotencyKey() succeeds (missing raw_capture,
// non-string capture_provider, or a rejected/degenerate capture) used to
// return its error WITHOUT ever releasing the claim, leaving the row stuck
// at "pending" forever. Confirmed live before this fix: a client whose first
// attempt failed validation and then retried with the SAME key got
// permanently stuck — either a bogus "capture_in_progress" 409 (nothing was
// actually in progress) on a same-body retry, or a false
// "idempotency_key_reused" 409 on a corrected-body retry — with no way to
// ever successfully use that key again.
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

$oversizedPropertyId = str_repeat('a', 9 * 1024 * 1024); // 9MB, over the 8MB cap
[$oversizedStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'property_id' => $oversizedPropertyId]);
check('a request body over the size cap is rejected (HTTP 413)', $oversizedStatus === 413, "got HTTP $oversizedStatus");

// Adjacent case: "clearly over" (9MB vs an 8MB cap) can't tell `>` apart from
// `>=` — only the exact boundary byte count can. MAX_REQUEST_BODY_BYTES is
// checked against the raw Content-Length before anything else runs, so a
// payload of EXACTLY that many bytes must still pass the size check itself
// (even though it then fails a later, unrelated 200-char field-length check
// — that's expected and is how this proves it got past the size gate at all).
echo "\n== Request body size boundary (the exact byte count itself) ==\n";
$maxBodyBytes = 8 * 1024 * 1024; // must match public/index.php's MAX_REQUEST_BODY_BYTES
$basePayloadForSizing = [...base_payload(), 'property_id' => ''];
$baseLength = strlen(json_encode($basePayloadForSizing, JSON_THROW_ON_ERROR));

$exactPadding = str_repeat('a', $maxBodyBytes - $baseLength);
$exactSizedBody = json_encode([...base_payload(), 'property_id' => $exactPadding], JSON_THROW_ON_ERROR);
check('constructed payload is exactly MAX_REQUEST_BODY_BYTES', strlen($exactSizedBody) === $maxBodyBytes, 'got ' . strlen($exactSizedBody) . ' bytes');
[$exactSizeStatus, ] = net_http_raw_literal('POST', "$baseUrl/scan-sessions", $exactSizedBody);
// Asserting the SPECIFIC expected outcome (422 field_too_long), not just
// "!== 413" — a merely-not-413 check would also incorrectly pass on an
// unrelated failure (e.g. a 429 from a shared rate-limit budget), silently
// hiding the very boundary this test exists to prove.
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

// ACL-surface scan finding: the size cap above used to only check the
// CLIENT-DECLARED Content-Length header, which chunked Transfer-Encoding
// omits entirely ($_SERVER['CONTENT_LENGTH'] is simply unset) — a client
// sending the exact same oversized body chunked instead sailed straight
// past the 413 check. Confirmed live before this fix: the identical 9MB
// payload that correctly got 413 with a normal Content-Length got a 422
// (reached and was fully buffered by a LATER, unrelated per-field check)
// when sent chunked — proving the whole body was read into memory
// unbounded, defeating the exact resource-exhaustion protection this cap
// exists for. Fixed by bounding the ACTUAL bytes read off php://input,
// independent of anything the client claims in a header.
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

echo "\n== Photos/notes/rotate-token routes are rate-limited per session ==\n";

[, $writeRateLimitSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-write-throttle']);
$writeRateLimitSessionId = $writeRateLimitSession['id'] ?? null;
$writeRateLimitToken = $writeRateLimitSession['access_token'] ?? null;
check('session created for the photos/notes/rotate-token rate-limit test', $writeRateLimitSessionId !== null && $writeRateLimitToken !== null);

if ($writeRateLimitSessionId !== null && $writeRateLimitToken !== null) {
    $sawNoteThrottle = false;
    for ($i = 0; $i < 65; $i++) {
        [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions/$writeRateLimitSessionId/notes", ['text' => "note $i"], $writeRateLimitToken);
        if ($status === 429) {
            $sawNoteThrottle = true;
            break;
        }
    }
    check('repeated note-attach calls against one session eventually hit HTTP 429', $sawNoteThrottle, 'never saw a 429 across 65 rapid note-attach calls');

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

// ACL-surface scan finding: every mutating session-scoped route now has a
// per-session rate limit, but the two GET routes never did. Cheaper
// per-call than capture/export, but not free — a session's access_log grows
// with every access attempt (including denied ones), and a session's
// contract_json can be large (unbounded room count; up to
// MAX_PHOTOS_PER_SESSION/MAX_NOTES_PER_SESSION each), so a valid (or
// compromised) token could still hammer either route indefinitely before
// this fix.
//
// Placed BEFORE the "Session-creation rate limit" section below, same
// cross-section-budget reason as the export/write-route sections above.
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

// The default limit is 60 per 10-minute window per caller IP
// (public/index.php — overridable via SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX).
// This net and every other net script share one IP (127.0.0.1) and this
// same window, so a full merge-gate suite run before this script has
// already spent some of that budget — this loop is generous (80 requests)
// so it reliably crosses the default limit even after the rest of the
// suite has run once. It intentionally does NOT try to survive being run
// many times back to back in the same 10-minute window: that's a known,
// documented tradeoff (scan-service/README.md), not something this test
// hides. Delete scan-service/data/scan_service.sqlite between rapid re-runs
// of the full suite if you hit this in practice.
$sawRateLimited = false;
for ($i = 0; $i < 80; $i++) {
    [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
    if ($status === 429) {
        $sawRateLimited = true;
        break;
    }
}
check('repeated rapid session creation eventually hits HTTP 429', $sawRateLimited, 'never saw a 429 across 80 rapid session-creation calls');

echo "\n== Repeated lookups of NONEXISTENT session ids are also throttled ==\n";

// Adjacent-case ACL gap found by deliberately probing what the
// session-creation and capture rate limits above imply should exist
// everywhere but didn't: authorizeSession()'s "session not found" branch had
// no bound at all — confirmed manually (100 back-to-back GETs against
// different fake session ids, all a plain 401, never throttled) before this
// fix existed. Bound per caller IP, same shape as create_session's own
// bucket right above, and deliberately tested here rather than in
// net/verify_acl.php for the exact same reason create_session's rate
// limit is tested only here: this bucket is shared across the whole suite
// by caller IP, and exhausting it in an earlier-run script poisons
// verify_security_fixes.php's own nonexistent-session check (found the hard
// way — it did, turning a legitimate 401-vs-404 assertion into a false 429
// failure until this test was moved here, last).
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
