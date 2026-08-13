<?php

declare(strict_types=1);

/**
 * Fast in-process unit tests for ScanSessionRepository — specifically the
 * enterprise-hardening logic (token expiry/rotation, idempotency, rate-limit
 * counting) added on top of the original Phase 1-3 repository. Same spirit
 * as tests/adapter_test.php: quick dev-loop feedback against an in-memory
 * SQLite DB, NOT the independent net (net/verify_enterprise_hardening.php
 * owns that — HTTP only, no import of this class). Both must be green
 * before a merge; neither substitutes for the other.
 *
 * Usage: php tests/repository_test.php
 */

require __DIR__ . '/../src/autoload.php';

use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$failures = [];
$checks = 0;

function r_check(string $label, bool $pass, string $detail = ''): void
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

function r_approx(float $a, float $b, float $tol = 2.0): bool
{
    return abs($a - $b) <= $tol;
}

// Fresh in-memory DB per run — fast, isolated, no leftover state between runs
// (unlike the shared local scan_service.sqlite the net scripts talk to).
$db = Database::connect(':memory:');
$repo = new ScanSessionRepository($db);

function fresh_session(ScanSessionRepository $repo, int $ttlSeconds = ScanSessionRepository::DEFAULT_TOKEN_TTL_SECONDS): array
{
    return $repo->create('prop-unit-test', 'unit-unit-test', 'org-unit-test', 'listing', false, false, $ttlSeconds);
}

echo "== Token creation sets a real expires_at ==\n";
$defaultSession = fresh_session($repo);
$expectedDefaultExpiry = time() + ScanSessionRepository::DEFAULT_TOKEN_TTL_SECONDS;
r_check(
    'default TTL (90 days) expires_at is ~90 days out, not empty/now',
    r_approx((float) strtotime($defaultSession['expires_at']), (float) $expectedDefaultExpiry, 5.0)
);

$shortSession = fresh_session($repo, 3600);
r_check(
    'a custom 1-hour TTL produces a ~1-hour-out expires_at, not the 90-day default',
    r_approx((float) strtotime($shortSession['expires_at']), (float) (time() + 3600), 5.0)
);
echo "\n";

echo "== Token rotation replaces the token AND the expiry ==\n";
$rotSession = fresh_session($repo);
$oldToken = $rotSession['access_token'];
$oldExpiry = $rotSession['expires_at'];

$rotated = $repo->rotateToken($rotSession['id'], 7200);
r_check('rotateToken() returns a different access_token', $rotated['access_token'] !== $oldToken);
r_check('rotateToken() returns a different expires_at', $rotated['expires_at'] !== $oldExpiry);
r_check(
    'rotated token TTL (2h) is honored, not silently reusing the original TTL',
    r_approx((float) strtotime($rotated['expires_at']), (float) (time() + 7200), 5.0)
);

// Adjacent case: the OLD token must no longer authorize this session — this
// is the entire point of rotation. tokenMatches() is what public/index.php
// actually calls, so exercise that, not just "the column changed."
$refetched = $repo->find($rotSession['id']);
r_check('the OLD token no longer matches after rotation', !$repo->tokenMatches($refetched, $oldToken));
r_check('the NEW token matches after rotation', $repo->tokenMatches($refetched, $rotated['access_token']));
echo "\n";

echo "== isTokenExpired() ==\n";
$futureSession = ['expires_at' => gmdate('c', time() + 3600)];
$pastSession = ['expires_at' => gmdate('c', time() - 3600)];
$noExpirySession = ['expires_at' => ''];

r_check('a future expires_at is NOT expired', $repo->isTokenExpired($futureSession) === false);
r_check('a past expires_at IS expired', $repo->isTokenExpired($pastSession) === true);
// Adjacent case, not the happy path: a session created before this column
// existed has expires_at = '' (Database.php's ALTER TABLE migration default).
// That must read as "no expiry recorded," never as "already expired" — the
// opposite bug (silently locking out every pre-existing session) would be
// far worse than the one this feature closes.
r_check(
    'an empty expires_at (pre-migration session) reads as NOT expired, not as expired',
    $repo->isTokenExpired($noExpirySession) === false
);
echo "\n";

// Closes the permanent-lockout gap: rotate-token now accepts an expired
// token within ScanSessionRepository::ROTATE_GRACE_PERIOD_SECONDS of the
// original expiry. isBeyondRotateGracePeriod() is the hard cutoff even
// rotate-token cannot cross — tested directly against synthetic sessions,
// same technique as isTokenExpired() above, so this doesn't depend on
// actually waiting out a real TTL.
echo "== isBeyondRotateGracePeriod() ==\n";
$grace = ScanSessionRepository::ROTATE_GRACE_PERIOD_SECONDS;
$justExpiredSession = ['expires_at' => gmdate('c', time() - 1)];
$withinGraceSession = ['expires_at' => gmdate('c', time() - $grace + 3600)];
$exactlyAtGraceEdgeSession = ['expires_at' => gmdate('c', time() - $grace - 1)];
$wayBeyondGraceSession = ['expires_at' => gmdate('c', time() - $grace - 3600)];
$notYetExpiredSession = ['expires_at' => gmdate('c', time() + 3600)];

r_check('a token that JUST expired is NOT beyond the grace period', $repo->isBeyondRotateGracePeriod($justExpiredSession) === false);
r_check('a token expired well within the grace window is NOT beyond it', $repo->isBeyondRotateGracePeriod($withinGraceSession) === false);
// Adjacent case: the boundary itself, not just "clearly inside" (above) and
// "clearly outside" (below) — an off-by-one here would only show up exactly
// at the edge, same reasoning as net/verify_enterprise_hardening.php's TTL
// boundary checks.
r_check('a token expired just PAST the grace window IS beyond it', $repo->isBeyondRotateGracePeriod($exactlyAtGraceEdgeSession) === true);
r_check('a token expired well past the grace window IS beyond it', $repo->isBeyondRotateGracePeriod($wayBeyondGraceSession) === true);
// Adjacent case, the opposite direction: a token that hasn't even expired
// yet must not be reported as "beyond" any grace period — this function
// only ever widens rotate-token's acceptance window, never narrows anything
// that was already valid.
r_check('a token that has not expired at all is NOT beyond the grace period', $repo->isBeyondRotateGracePeriod($notYetExpiredSession) === false);
// Same "no expiry recorded" case isTokenExpired() protects — must not
// suddenly become "beyond grace" for a pre-migration session.
r_check('an empty expires_at reads as NOT beyond the grace period', $repo->isBeyondRotateGracePeriod($noExpirySession) === false);
echo "\n";

echo "== Idempotency key storage ==\n";
$idemSession = fresh_session($repo);
$otherSession = fresh_session($repo);

r_check(
    'no stored response for a key that has never been recorded',
    $repo->findIdempotentResponse($idemSession['id'], 'key-a') === null
);

r_check('claiming a never-seen key succeeds', $repo->claimIdempotencyKey($idemSession['id'], 'key-a', 'fp-a') === true);
r_check(
    'a claimed-but-not-yet-completed key still returns null, not a stale/empty response',
    $repo->findIdempotentResponse($idemSession['id'], 'key-a') === null
);

$repo->completeIdempotencyKey($idemSession['id'], 'key-a', ['rooms' => ['room-1']]);
$stored = $repo->findIdempotentResponse($idemSession['id'], 'key-a');
r_check('a completed claim is returned verbatim for the same (session, key)', $stored === ['rooms' => ['room-1']]);

// Adjacent case: a DIFFERENT key on the SAME session must not accidentally
// match — this is the exact bug that would make every retry (with a fresh
// key) look like a duplicate of the first capture.
r_check(
    'a different idempotency key on the same session is NOT treated as a match',
    $repo->findIdempotentResponse($idemSession['id'], 'key-b') === null
);

// Adjacent case, the other direction: the SAME key on a DIFFERENT session
// must not leak the first session's stored response — this is the exact bug
// that would let one caller's cached capture bleed into an unrelated session
// that happens to reuse an idempotency key.
r_check(
    'the same idempotency key on a DIFFERENT session is NOT treated as a match',
    $repo->findIdempotentResponse($otherSession['id'], 'key-a') === null
);

// Claiming an already-completed key again must not throw or overwrite —
// mirrors ON CONFLICT DO NOTHING in the SQL; the caller is expected to check
// findIdempotentResponse() first (the capture route does), so reaching this
// again means a very tight race, and losing the claim must be silent + safe.
r_check('re-claiming an already-completed key returns false, not true', $repo->claimIdempotencyKey($idemSession['id'], 'key-a', 'fp-a') === false);
$stillOriginal = $repo->findIdempotentResponse($idemSession['id'], 'key-a');
r_check(
    'a failed re-claim does not disturb the already-completed response',
    $stillOriginal === ['rooms' => ['room-1']]
);
echo "\n";

// Adjacent case to the whole feature: a key REUSED with a genuinely
// different request must be distinguishable from a true retry, or the
// second, different capture silently vanishes behind the first one's cached
// response. idempotencyKeyFingerprint() is what public/index.php checks
// before ever trusting a cache hit or a claim.
echo "== Idempotency fingerprint mismatch detection ==\n";
r_check(
    'fingerprint for a never-seen key is null (caller may claim freely)',
    $repo->idempotencyKeyFingerprint($idemSession['id'], 'never-seen-key') === null
);
r_check(
    'fingerprint for a completed key matches what it was claimed with',
    $repo->idempotencyKeyFingerprint($idemSession['id'], 'key-a') === 'fp-a'
);

$pendingSession = fresh_session($repo);
$repo->claimIdempotencyKey($pendingSession['id'], 'pending-key', 'fp-pending');
r_check(
    'fingerprint is visible even while the key is still pending (not completed yet) — this is what lets a colliding reuse be rejected without a poll',
    $repo->idempotencyKeyFingerprint($pendingSession['id'], 'pending-key') === 'fp-pending'
);
echo "\n";

// Found by deliberately probing the adjacent case to the sequential-retry
// test above: the OLD implementation (findIdempotentResponse, then later
// recordIdempotentResponse — no claim step) let two concurrent requests for
// the SAME key both see "no cached response yet" and both proceed to
// capture, double-appending the room. This is exactly the scenario
// public/index.php's capture route now guards against with
// claimIdempotencyKey(); this test proves the atomic primitive itself is
// correct, deterministically — no real thread timing needed, since a
// UNIQUE-constrained INSERT resolves the "who goes first" question for us.
echo "== The race: only one concurrent claim for the same key can win ==\n";
$raceSession = fresh_session($repo);
$firstClaim = $repo->claimIdempotencyKey($raceSession['id'], 'race-key', 'fp-race');
$secondClaim = $repo->claimIdempotencyKey($raceSession['id'], 'race-key', 'fp-race');
r_check('the first claim for a fresh key wins (returns true)', $firstClaim === true);
r_check(
    'a second, concurrent claim for the SAME key loses (returns false) — this is what prevents a double-append',
    $secondClaim === false
);
echo "\n";

echo "== Rate-limit event counting ==\n";
r_check('an unused bucket starts at 0 events', $repo->countRecentEvents('bucket-a', 600) === 0);

$repo->recordEvent('bucket-a');
$repo->recordEvent('bucket-a');
r_check('two recorded events count as 2 within the window', $repo->countRecentEvents('bucket-a', 600) === 2);

// Adjacent case: a different bucket must have its own independent count —
// the exact bug that would make one caller's IP share a budget with an
// unrelated caller (or one route's limit bleed into another's).
r_check('a different, unused bucket is unaffected by bucket-a\'s events', $repo->countRecentEvents('bucket-b', 600) === 0);

// Adjacent case, the one a naive "just COUNT(*) for this bucket" implementation
// would get wrong: an event recorded outside the window must not count.
// Inserted directly since recordEvent() always stamps "now" — this is
// testing the window filter itself, not the insert path.
$db->exec("INSERT INTO rate_limit_events (bucket, occurred_at) VALUES ('bucket-a', '" . gmdate('c', time() - 3600) . "')");
r_check(
    'an event from an hour ago does NOT count within a 10-minute (600s) window',
    $repo->countRecentEvents('bucket-a', 600) === 2 // still 2, the old event doesn't add a 3rd
);
r_check(
    'the same old event DOES count within a window wide enough to include it',
    $repo->countRecentEvents('bucket-a', 7200) === 3
);
echo "\n";

// Found by deliberately probing past the existing "must have a captured
// FloorPlan first" (409/RuntimeException) guard: nothing checked that a
// caller-supplied room_id, once a FloorPlan DOES exist, actually names one
// of ITS rooms. A typo'd or unrelated room_id used to be stored verbatim.
echo "== room_id validation on appendPhoto/appendNote ==\n";
$roomIdSession = fresh_session($repo);
$repo->appendCapture($roomIdSession['id'], [
    'scan_session_id' => $roomIdSession['id'],
    'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
    'capture_provider' => 'test', 'captured_at' => gmdate('c'),
    'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
    'rooms' => [[
        'room_id' => 'room-real-1', 'label' => 'Room 1', 'floor_area_m2' => 10.0,
        'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
        'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
        'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
    ]],
    'photos' => [], 'notes' => [],
]);

try {
    $repo->appendNote($roomIdSession['id'], ['note_id' => 'n1', 'text' => 'x', 'room_id' => 'room-does-not-exist', 'created_at' => gmdate('c')]);
    r_check('appendNote() rejects a room_id that matches no real room', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('appendNote() rejects a room_id that matches no real room', true);
}

try {
    $repo->appendPhoto($roomIdSession['id'], ['photo_id' => 'p1', 'url' => 'https://example.invalid/x.jpg', 'room_id' => 'room-does-not-exist', 'taken_at' => gmdate('c')]);
    r_check('appendPhoto() rejects a room_id that matches no real room', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('appendPhoto() rejects a room_id that matches no real room', true);
}

$withRealRoomId = $repo->appendNote($roomIdSession['id'], ['note_id' => 'n2', 'text' => 'x', 'room_id' => 'room-real-1', 'created_at' => gmdate('c')]);
r_check('appendNote() accepts a room_id that DOES match a real room', count($withRealRoomId['notes']) === 1);

$withNullRoomId = $repo->appendNote($roomIdSession['id'], ['note_id' => 'n3', 'text' => 'x', 'room_id' => null, 'created_at' => gmdate('c')]);
r_check('appendNote() still accepts room_id: null (session-wide note) — this fix must not make room_id required', count($withNullRoomId['notes']) === 2);
echo "\n";

echo count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);
