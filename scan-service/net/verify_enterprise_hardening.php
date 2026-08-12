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

// Adjacent case, found by deliberately probing the boundary itself rather
// than only "clearly outside" values: the two checks above prove values far
// past the edges are rejected, but an off-by-one in the comparison operator
// (e.g. `<=` where `>` was meant, or vice versa) would sail through both of
// those and only show up exactly AT 60 or AT 365 days. "Between min and max"
// is documented (public/index.php) as inclusive, so both boundary values
// themselves must be ACCEPTED, not rejected.
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
// public API to make the test fast — instead this only exercises that a
// short-but-valid TTL is honestly accepted and still live seconds later,
// which is the adjacent case a naive "expires_at in the past" bug could
// break just as easily as the expired case itself.
$expId = $expSession['id'] ?? null;
$expToken = $expSession['access_token'] ?? null;
if ($expId !== null && $expToken !== null) {
    [$stillLiveStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$expId", null, $expToken);
    check('a freshly issued 60s-TTL token is still valid seconds later (HTTP 200)', $stillLiveStatus === 200, "got HTTP $stillLiveStatus");
}

// Closes the permanent-lockout gap flagged in README's "Known limits":
// once a token actually expired, rotate-token was unreachable too, with no
// recovery path at all. Fix: rotate-token now accepts an expired-but-correct
// token within a 7-day grace window (ScanSessionRepository::
// ROTATE_GRACE_PERIOD_SECONDS); every other action stays hard-blocked at the
// instant of expiry, unchanged. Proven here over real HTTP with a real
// 60-second-TTL token actually left to expire (the minimum allowed TTL,
// same technique the "still valid seconds later" check above uses to stay
// fast) — not a synthetic session array, so this exercises the real
// authorizeSession() code path end to end.
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
