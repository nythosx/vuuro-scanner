<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;
use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

// Security hardening (found via manual review, confirmed exploitable this
// session): an uncaught exception anywhere below — e.g. malformed capture
// coordinates that overflow to INF/NaN and make json_encode() throw —
// previously fell through to PHP's default handler, which emits an HTML
// stack trace containing full server file paths AND leaves the HTTP status
// at 200 (since http_response_code() was never reached), making a server
// crash look like a successful response to any client that only checks the
// status code. Route every uncaught Throwable through one place instead:
// no stack trace, no paths, and an honest 500.
ini_set('display_errors', '0');
error_reporting(E_ALL);
set_exception_handler(static function (\Throwable $e): void {
    http_response_code(500);
    header('Content-Type: application/json');
    // UX note: friendly wording, but deliberately generic — no exception
    // message, class name, or file path, matching the security rationale
    // above. A helpful-sounding 500 and a safe one aren't in tension here;
    // the fix is phrasing, not detail.
    echo json_encode([
        'error' => 'internal_error',
        'message' => "Something went wrong on our end while handling that request. Please try again in a moment, and if it keeps happening, let us know what you were doing.",
    ], JSON_PRETTY_PRINT);
});

// Cheap standard hardening: stop a browser from MIME-sniffing a response
// (JSON, PNG, or PDF here) into something it decides to execute as HTML/JS.
header('X-Content-Type-Options: nosniff');

// CORS: local-dev-only, scoped to the web-viewer's own dev server
// (web-viewer/README.md), not a wildcard. This is the one deliberate
// scan-service/ touch-point WEB_VIEWER_PLAN.md calls out — additive, does
// not touch any existing route/business logic. Revisit the allowed origin
// (and whether this belongs here at all) once real deployment or Vuuro API
// coupling makes CORS an actual production concern, not a local-dev one.
$corsOrigin = 'http://127.0.0.1:8090';
if (($_SERVER['HTTP_ORIGIN'] ?? null) === $corsOrigin) {
    header("Access-Control-Allow-Origin: $corsOrigin");
    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
    // Idempotency-Key added for the enterprise-hardening pass's idempotent
    // capture retries — found missing here by actually driving a capture
    // through the web-viewer in a browser: without it, the preflight
    // OPTIONS request for any POST /capture call carrying that header gets
    // rejected before the real request ever fires, surfacing to the page
    // only as a generic "Failed to fetch" with no server-side trace at all
    // (no 4xx logged, nothing — the browser blocks it before it leaves).
    header('Access-Control-Allow-Headers: Content-Type, X-Scan-Access-Token, Idempotency-Key');
}
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    return;
}

header('Content-Type: application/json');

// GET /health — enterprise ops requirement (load balancer / uptime monitor
// target). Deliberately unauthenticated and touches nothing but the DB
// connection itself, so it reflects "is this process up and can it reach its
// database" and nothing about any particular session.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && rtrim(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), '/') === '/health') {
    try {
        Database::connect();
        respond(200, ['status' => 'ok', 'time' => gmdate('c')]);
    } catch (\Throwable $e) {
        respond(503, ['status' => 'unavailable', 'message' => 'The Scan Service cannot reach its database right now.']);
    }
    return;
}

/**
 * Manual review finding (enterprise hardening pass): request bodies were
 * read and json_decode()'d with no size limit anywhere before reaching any
 * of RoomPlanSimulatorAdapter's own MAX_* geometry limits — a client could
 * still make the server allocate an arbitrarily large string/array for a
 * single request before any of those per-field checks ever run. Capped well
 * above any real capture payload (RoomPlan's own limits keep genuine
 * captures well under this) but far below a resource-exhaustion attempt.
 */
const MAX_REQUEST_BODY_BYTES = 8 * 1024 * 1024;

function json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === '' || $raw === false) {
        return [];
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

/**
 * Fixed-window rate limiter shared by every route that calls it. `$bucket`
 * should combine the caller's IP with the route so unrelated endpoints don't
 * share a budget. Sends 429 + Retry-After and returns true if the caller is
 * over budget (callers just check the return value and `return;`); records
 * this call as an event either way, since even a rejected attempt counts
 * against the window (otherwise a caller sitting exactly at the limit could
 * hammer the endpoint forever without ever advancing the window).
 */
function rateLimited(ScanSessionRepository $repo, string $bucket, int $max, int $windowSeconds): bool
{
    $repo->recordEvent($bucket);
    $count = $repo->countRecentEvents($bucket, $windowSeconds);
    if ($count > $max) {
        header("Retry-After: $windowSeconds");
        $windowMinutes = max(1, (int) round($windowSeconds / 60));
        respondError(429, 'rate_limited', "You're making requests faster than we can safely process (limit: $max per $windowMinutes minute(s)). Please slow down and try again shortly.", ['limit' => $max, 'window_seconds' => $windowSeconds]);
        return true;
    }
    return false;
}

// Bounded wait for a concurrent request that already won the idempotency
// claim to finish. 20 x 50ms = 1s max — generous next to a single in-process
// adapt()+save() (milliseconds), tiny next to a real client's own HTTP
// timeout. If it never resolves in that window, the caller gets a clean 409
// (see the capture route) rather than this looping forever or, worse, giving
// up and running the capture itself.
function pollForIdempotentResponse(ScanSessionRepository $repo, string $sessionId, string $idempotencyKey): ?array
{
    for ($attempt = 0; $attempt < 20; $attempt++) {
        usleep(50_000);
        $result = $repo->findIdempotentResponse($sessionId, $idempotencyKey);
        if ($result !== null) {
            return $result;
        }
    }
    return null;
}

// Fingerprints "is this the same request" for Idempotency-Key reuse
// detection — see ScanSessionRepository::idempotencyKeyFingerprint's doc
// comment for why this exists. Deliberately only the fields that define a
// distinct capture; unrelated fields (if any get added later) should not be
// folded in here without checking whether they'd make legitimate retries
// look like mismatches.
function idempotencyFingerprint(array $body): string
{
    return hash('sha256', json_encode([
        'raw_capture' => $body['raw_capture'] ?? null,
        'capture_provider' => $body['capture_provider'] ?? null,
    ], JSON_THROW_ON_ERROR));
}

function clientIp(): string
{
    // No reverse proxy / load balancer in front of this local-dev service
    // today, so REMOTE_ADDR is trustworthy — deliberately NOT trusting
    // X-Forwarded-For here, since that header is caller-supplied and would
    // let anyone claim any IP and reset their own rate-limit bucket at will.
    // Revisit if/when this ever sits behind a real reverse proxy that sets
    // X-Forwarded-For itself.
    return $_SERVER['REMOTE_ADDR'] ?? 'unknown';
}

function respond(int $status, array $body): void
{
    http_response_code($status);
    echo json_encode($body, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
}

/**
 * UX hardening: every error response goes through here so `message` is
 * never missing. Found by manual review that roughly half of this file's
 * error responses had an `error` machine code but no human-readable
 * `message` (`invalid_purpose`, `occupied_must_be_boolean`,
 * `field_too_long`, the bare 404/500 fallbacks, ...) — fine for a developer
 * reading the code, not fine for a mobile app or the web-viewer trying to
 * show the person holding the phone something better than the raw error
 * code. `error` stays the stable, documented machine-readable code for
 * client-side branching (net/verify_*.php and the iOS client both key off
 * it); `message` is the sentence a UI can put directly in front of a user
 * without translating the code itself. `$extra` carries any additional
 * structured detail (allowed values, field name, limits) a client may still
 * want programmatically.
 */
function respondError(int $status, string $errorCode, string $message, array $extra = []): void
{
    respond($status, ['error' => $errorCode, 'message' => $message, ...$extra]);
}

function require_fields(array $body, array $fields): ?array
{
    $missing = array_values(array_filter($fields, static fn ($f) => !array_key_exists($f, $body) || $body[$f] === ''));
    return $missing === [] ? null : $missing;
}

/**
 * Manual security review finding: no field anywhere had a length cap, so a
 * client could submit e.g. a multi-megabyte property_id — stored unbounded
 * in SQLite, echoed unbounded into every future JSON response for that
 * session, and (for identity fields) embedded unbounded into PDF export
 * text. Same class of resource-exhaustion risk as the capture-geometry
 * limits in RoomPlanSimulatorAdapter, applied here to free-text fields.
 * Returns [field, max] for the first field that's too long, or null if all
 * are fine — the max is returned too so the error message can actually tell
 * the caller the limit instead of just which field tripped it.
 */
/**
 * Adjacent-case fix, found by deliberately probing session creation the same
 * way the PDF/PNG export MAX_PAGES/MAX_CANVAS bugs were found: a caller
 * sending a non-string value for an identity field (e.g. a numeric
 * property_id, or an object) passed require_fields() (present, non-empty)
 * and first_too_long() (silently skips non-strings — see its own comment),
 * then reached ScanSessionRepository::create()'s `string $propertyId`-typed
 * parameter under this file's own declare(strict_types=1) and threw an
 * uncaught TypeError. The global exception handler caught it safely (no
 * leak), but turned an entirely client-side, actionable mistake into a
 * generic "something went wrong on our end" 500 — exactly the same shape of
 * bug as the export MAX_PAGES fix elsewhere in this file, just reached
 * through a type mismatch instead of a missing try/catch. Returns the first
 * offending field name, or null if all are strings.
 */
function first_not_string(array $body, array $fields): ?string
{
    foreach ($fields as $field) {
        if (array_key_exists($field, $body) && !is_string($body[$field])) {
            return $field;
        }
    }
    return null;
}

function first_too_long(array $body, array $maxLengths): ?array
{
    foreach ($maxLengths as $field => $max) {
        $value = $body[$field] ?? null;
        // Found by deliberately checking a promise this codebase makes
        // elsewhere: every caller of this function tells the client the
        // limit is in "characters" (see the field_too_long messages in this
        // file). strlen() counts BYTES, so a note/property_id written in
        // Japanese, Arabic, or with accented Latin characters (3-4 bytes
        // each in UTF-8) used to hit the byte cap at a fraction of the
        // promised character count — e.g. a 5000-byte cap silently allowed
        // only ~1,250 real Japanese characters, not 5000. json_body()
        // already guarantees valid UTF-8 (invalid encoding fails json_decode
        // upstream), so mb_strlen() is safe here without extra validation.
        if (is_string($value) && mb_strlen($value, 'UTF-8') > $max) {
            return [$field, $max];
        }
    }
    return null;
}

/**
 * Manual security review finding: photos[].url is documented (see
 * contracts/floorplan.schema.json) as "wherever the mobile client already
 * uploaded the image" — every real consumer of this contract is going to
 * treat it as an image source sooner or later. Nothing validated it was
 * even a URL, let alone an http(s) one, so a stored `javascript:` or
 * `data:` value would sit there as a stored-XSS trap waiting for whichever
 * future UI renders it with an <img src> or similar without independently
 * re-validating — better to reject it at the one place it enters the
 * system than trust every future consumer to re-derive this rule.
 */
function is_http_url(string $url): bool
{
    return (bool) preg_match('#^https?://#i', $url);
}

function presented_token(): ?string
{
    $header = $_SERVER['HTTP_X_SCAN_ACCESS_TOKEN'] ?? null;
    return is_string($header) && $header !== '' ? $header : null;
}

/**
 * Privacy by design gate (hard constraint #3): every session-scoped
 * endpoint below other than creation must call this before touching
 * session data. Returns the session row if authorized, or null after
 * already sending a 401 response — callers just check for null and
 * `return;`.
 *
 * Deliberately returns the SAME 401 whether the session doesn't exist at
 * all or the token presented is simply wrong, never a distinguishing 404.
 * Found via manual security review: a caller holding a leaked
 * scan_session_id — precisely the threat this token model exists to
 * defend against — could previously tell "no such session" (404) apart
 * from "wrong token" (401) and use that as a free confirmation oracle,
 * even without ever presenting a valid token. hash_equals() always runs
 * against a same-length dummy token when there's no real session to check
 * against, so a nonexistent session doesn't even resolve measurably
 * faster than a real one with a wrong token.
 */
function authorizeSession(ScanSessionRepository $repo, string $sessionId, string $action): ?array
{
    $session = $repo->find($sessionId);
    $token = presented_token() ?? '';

    if ($session !== null) {
        $granted = $repo->tokenMatches($session, $token);
        $repo->logAccess($session['id'], $action, $granted ? 'granted' : 'denied');
    } else {
        hash_equals('00000000-0000-0000-0000-000000000000', $token);
        $granted = false;
    }

    // Adjacent-case ACL gap, found by deliberately probing what capture's
    // own rate limit ("bounds a runaway client... from hammering... the
    // adapter/renderer pipeline indefinitely" — see that comment below)
    // implies should exist everywhere, but doesn't: every OTHER
    // session-scoped route (read, exports, photos, notes, rotate-token) had
    // no bound at all on repeated failed-auth attempts. Confirmed directly:
    // 100 back-to-back GETs against a real session with a wrong token each
    // time all returned a plain 401, no throttling. access_token is a
    // 122-bit UUID, so brute-forcing the actual value isn't practically
    // feasible — this isn't a credential-guessing fix — but unbounded
    // denied attempts still mean unbounded access_log INSERTs per session
    // (storage exhaustion) and unbounded Database::find() lookups for a
    // scanning attacker trying many session ids (the "session not found"
    // branch). Two independent buckets, mirroring create_session's
    // per-IP / capture's per-session split: real-session-wrong-token is
    // bounded per session (an attacker can't fabricate a valid session id to
    // dodge this), session-not-found is bounded per caller IP (an attacker
    // rotating through fake ids can't dodge this either). Only DENIED
    // attempts count — a legitimate client presenting the correct token
    // repeatedly never touches either bucket.
    if ($session !== null && !$granted) {
        if (rateLimited($repo, $session['id'] . ':denied_auth', 20, 300)) {
            return null;
        }
    } elseif ($session === null) {
        if (rateLimited($repo, clientIp() . ':session_not_found', 30, 300)) {
            return null;
        }
    }

    if (!$granted) {
        respondError(401, 'invalid_or_missing_access_token', 'This request needs a valid access token. Include the X-Scan-Access-Token header you were given when the session was created.');
        return null;
    }

    // Enterprise hardening: token expiry (docs/adr/0003's "no token
    // rotation/expiry" known limit). Checked only after the token has
    // already matched, so a caller who doesn't hold the right token learns
    // nothing new here — this can't become a second enumeration oracle on
    // top of the one authorizeSession's 401-for-both-cases already closes.
    if ($repo->isTokenExpired($session)) {
        // Closes the permanent-lockout gap: rotate-token itself used to be
        // blocked by this same check, so an expired token had no recovery
        // path at all. Scoped narrowly — ONLY the rotate_token action gets
        // this exception, and only within ROTATE_GRACE_PERIOD_SECONDS of
        // the original expiry. Every other action is unaffected: still
        // hard-blocked the instant the token expires, exactly as before.
        if ($action === 'rotate_token' && !$repo->isBeyondRotateGracePeriod($session)) {
            $repo->logAccess($session['id'], $action, 'granted_grace_rotation');
            return $session;
        }
        $repo->logAccess($session['id'], $action, 'expired');
        $graceDays = (int) round(ScanSessionRepository::ROTATE_GRACE_PERIOD_SECONDS / 86400);
        respondError(
            401,
            'token_expired',
            $action === 'rotate_token'
                ? "This token expired more than {$graceDays} days ago, past the rotation grace period. There is no recovery path once that window closes — a new session is needed."
                : "Your access token has expired. Call POST /scan-sessions/{id}/rotate-token with your current token within {$graceDays} days of expiry to get a new one."
        );
        return null;
    }

    return $session;
}

$db = Database::connect();
$repo = new ScanSessionRepository($db);

$method = $_SERVER['REQUEST_METHOD'];
$path = rtrim(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), '/');

if ($method === 'POST') {
    $contentLength = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
    if ($contentLength > MAX_REQUEST_BODY_BYTES) {
        $maxMb = round(MAX_REQUEST_BODY_BYTES / (1024 * 1024), 1);
        respondError(413, 'payload_too_large', "This request is larger than the {$maxMb}MB limit. If this is a real capture, check for an unexpectedly large field rather than retrying as-is.", ['max_bytes' => MAX_REQUEST_BODY_BYTES]);
        return;
    }
}

if ($method === 'POST' && $path === '/scan-sessions') {
    // Enterprise hardening: session creation is the one endpoint with no
    // token to gate it (there isn't one yet), which is exactly why
    // scan-service/README.md's "Known limits" flagged unlimited session
    // creation as an accepted-for-now risk. Bounded per caller IP.
    //
    // Overridable via env (a real pilot deployment behind one shared IP
    // range may want this much tighter than local dev/CI needs it to be).
    // The default is deliberately generous rather than tuned to a realistic
    // single guided-capture pace: this repo's own merge-gate net suite
    // (net/verify_*.php) creates ~20 sessions from localhost every time it
    // runs end to end, and re-running it more than once inside the same
    // window must not start failing unrelated checks with spurious 429s —
    // see the adjacent-case note in net/verify_enterprise_hardening.php.
    $createSessionMax = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX') ?: 60);
    $createSessionWindowSeconds = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_WINDOW_SECONDS') ?: 600);
    if (rateLimited($repo, clientIp() . ':create_session', $createSessionMax, $createSessionWindowSeconds)) {
        return;
    }

    $body = json_body();
    // Hard constraint #1: identity-native captures. A session cannot be
    // created without property/unit/organisation — no orphan captures by
    // construction, not by convention.
    $missing = require_fields($body, ['property_id', 'unit_id', 'organisation_id', 'purpose', 'occupied']);
    if ($missing !== null) {
        $fieldList = implode(', ', $missing);
        respondError(422, 'missing_required_fields', "Please provide the following before starting a scan: $fieldList.", ['fields' => $missing]);
        return;
    }
    $notString = first_not_string($body, ['property_id', 'unit_id', 'organisation_id']);
    if ($notString !== null) {
        respondError(422, 'field_must_be_string', "'$notString' must be a plain string.", ['field' => $notString]);
        return;
    }
    $tooLong = first_too_long($body, ['property_id' => 200, 'unit_id' => 200, 'organisation_id' => 200]);
    if ($tooLong !== null) {
        [$tooLongField, $tooLongMax] = $tooLong;
        respondError(422, 'field_too_long', "'$tooLongField' is too long — please keep it to $tooLongMax characters or fewer.", ['field' => $tooLongField, 'max_length' => $tooLongMax]);
        return;
    }
    $validPurposes = ['listing', 'check_in', 'check_out', 'renovation', 'other'];
    if (!in_array($body['purpose'], $validPurposes, true)) {
        respondError(422, 'invalid_purpose', 'Please choose a valid purpose for this scan: listing, check_in, check_out, renovation, or other.', ['allowed' => $validPurposes]);
        return;
    }
    if (!is_bool($body['occupied'])) {
        respondError(422, 'occupied_must_be_boolean', "Please specify whether the unit is currently occupied (true or false) — 'occupied' isn't optional, so a scan can't accidentally skip the consent check that depends on it.");
        return;
    }
    $consentObtained = $body['consent_obtained'] ?? false;
    if (!is_bool($consentObtained)) {
        respondError(422, 'consent_obtained_must_be_boolean', "Please specify 'consent_obtained' as true or false.");
        return;
    }
    // Hard constraint #3: an occupied unit cannot be scanned without
    // recorded consent — this is checked at the earliest possible point
    // (session creation), not left for capture time or later cleanup.
    if ($body['occupied'] === true && $consentObtained !== true) {
        respondError(403, 'consent_required', 'This unit is marked occupied, so tenant consent must be recorded (consent_obtained: true) before a scan session can be created.');
        return;
    }

    // Enterprise hardening: caller-adjustable token TTL, bounded server-side.
    // Lets a pilot deployment tighten this for a highly sensitive occupied
    // unit, or loosen it for a long-running renovation project, without
    // needing a code change on either side.
    $tokenTtlSeconds = $body['access_token_ttl_seconds'] ?? ScanSessionRepository::DEFAULT_TOKEN_TTL_SECONDS;
    if (!is_int($tokenTtlSeconds) || $tokenTtlSeconds < ScanSessionRepository::MIN_TOKEN_TTL_SECONDS || $tokenTtlSeconds > ScanSessionRepository::MAX_TOKEN_TTL_SECONDS) {
        respondError(
            422,
            'invalid_access_token_ttl_seconds',
            'access_token_ttl_seconds must be between ' . ScanSessionRepository::MIN_TOKEN_TTL_SECONDS . ' and ' . ScanSessionRepository::MAX_TOKEN_TTL_SECONDS . ' seconds — omit it entirely to use the default.',
            ['min' => ScanSessionRepository::MIN_TOKEN_TTL_SECONDS, 'max' => ScanSessionRepository::MAX_TOKEN_TTL_SECONDS]
        );
        return;
    }

    $session = $repo->create(
        $body['property_id'],
        $body['unit_id'],
        $body['organisation_id'],
        $body['purpose'],
        $body['occupied'],
        $consentObtained,
        $tokenTtlSeconds
    );
    // access_token is returned here and only here — the one moment a client
    // is expected to learn it. Every later call must present it explicitly.
    respond(201, [
        ...$session,
        'occupied' => (bool) $session['occupied'],
        'consent_obtained' => (bool) $session['consent_obtained'],
    ]);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/rotate-token$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'rotate_token');
    if ($session === null) {
        return;
    }

    $body = json_body();
    $tokenTtlSeconds = $body['access_token_ttl_seconds'] ?? ScanSessionRepository::DEFAULT_TOKEN_TTL_SECONDS;
    if (!is_int($tokenTtlSeconds) || $tokenTtlSeconds < ScanSessionRepository::MIN_TOKEN_TTL_SECONDS || $tokenTtlSeconds > ScanSessionRepository::MAX_TOKEN_TTL_SECONDS) {
        respondError(
            422,
            'invalid_access_token_ttl_seconds',
            'access_token_ttl_seconds must be between ' . ScanSessionRepository::MIN_TOKEN_TTL_SECONDS . ' and ' . ScanSessionRepository::MAX_TOKEN_TTL_SECONDS . ' seconds — omit it entirely to use the default.',
            ['min' => ScanSessionRepository::MIN_TOKEN_TTL_SECONDS, 'max' => ScanSessionRepository::MAX_TOKEN_TTL_SECONDS]
        );
        return;
    }

    $updated = $repo->rotateToken($session['id'], $tokenTtlSeconds);
    // The OLD token presented on this very request is now invalid — this
    // response is the only place the client learns the new one.
    respond(200, [
        'id' => $updated['id'],
        'access_token' => $updated['access_token'],
        'expires_at' => $updated['expires_at'],
    ]);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/capture$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'capture');
    if ($session === null) {
        return;
    }

    // Enterprise hardening: 60 capture calls per 5-minute window per session
    // is far above any real guided multi-room pace, but bounds a runaway
    // client (or a compromised token) from hammering the adapter/renderer
    // pipeline indefinitely.
    if (rateLimited($repo, $session['id'] . ':capture', 60, 300)) {
        return;
    }

    // Enterprise reliability hardening: idempotent retry support. A client
    // resubmitting the exact same capture after a dropped response (see
    // ScanSessionRepository::findIdempotentResponse's doc comment) gets back
    // the stored result instead of appending the room a second time. Body is
    // parsed here (earlier than the raw_capture validation below needs it)
    // specifically so the fingerprint below can see it before any cache/claim
    // decision is made.
    $body = json_body();
    $idempotencyKey = $_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? null;
    $holdsIdempotencyClaim = false;
    if (is_string($idempotencyKey) && $idempotencyKey !== '') {
        $fingerprint = idempotencyFingerprint($body);

        // Adjacent case to the retry/replay logic below: a key reused with a
        // DIFFERENT body (client bug, or two distinct captures accidentally
        // sharing a key) must not silently replay a stale response for the
        // wrong capture — that's real data quietly dropped, not just a
        // wasted retry. Checked before either the cache read or the claim
        // attempt, and against the fingerprint recorded at claim time even
        // while another request's capture is still pending, so a same-key
        // collision is rejected immediately rather than after a 1s poll.
        $existingFingerprint = $repo->idempotencyKeyFingerprint($session['id'], $idempotencyKey);
        if ($existingFingerprint !== null && $existingFingerprint !== $fingerprint) {
            respondError(
                409,
                'idempotency_key_reused',
                'This Idempotency-Key was already used for a different capture on this session. Idempotency-Keys must be unique per distinct request — use a new key for a new capture.'
            );
            return;
        }

        $cached = $repo->findIdempotentResponse($session['id'], $idempotencyKey);
        if ($cached !== null) {
            respond(200, $cached);
            return;
        }

        // Adjacent case to the retry above: two requests with the SAME key
        // can both reach this point with $cached === null if they arrive
        // close enough together (a real risk under PHP-FPM/production, even
        // though this dev server serializes requests and can't reproduce
        // it). Only the request that wins this atomic claim may actually
        // run the capture below — see ScanSessionRepository::claimIdempotencyKey.
        $holdsIdempotencyClaim = $repo->claimIdempotencyKey($session['id'], $idempotencyKey, $fingerprint);
        if (!$holdsIdempotencyClaim) {
            $result = pollForIdempotentResponse($repo, $session['id'], $idempotencyKey);
            if ($result !== null) {
                respond(200, $result);
            } else {
                respondError(
                    409,
                    'capture_in_progress',
                    'Another request with this Idempotency-Key is still being processed for this session. Please retry shortly.'
                );
            }
            return;
        }
    }

    if (empty($body['raw_capture']) || !is_array($body['raw_capture'])) {
        respondError(422, 'missing_raw_capture', "Please include a 'raw_capture' field with the RoomPlan capture data for this room.");
        return;
    }

    $adapter = new RoomPlanSimulatorAdapter();
    try {
        // Offset by rooms already captured this session, so a second or
        // third guided RoomPlan capture in the same "unit story" session
        // (PHASES.md Phase 2) continues room numbering instead of
        // restarting at "Room 1" and colliding on room_id.
        $roomIndexOffset = $repo->roomCount($session['id']);
        $capturedFloorPlan = $adapter->adapt($body['raw_capture'], [
            'scan_session_id' => $session['id'],
            'property_id' => $session['property_id'],
            'unit_id' => $session['unit_id'],
            'organisation_id' => $session['organisation_id'],
            'purpose' => $session['purpose'],
            'capture_provider' => $body['capture_provider'] ?? 'roomplan_simulator_fixture',
        ], $roomIndexOffset);
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unprocessable_capture', "This capture couldn't be processed: " . $e->getMessage() . ' Please rescan this room.');
        return;
    }

    $floorPlan = $repo->appendCapture($session['id'], $capturedFloorPlan);
    $repo->markCaptured($session['id']);
    if ($holdsIdempotencyClaim) {
        $repo->completeIdempotencyKey($session['id'], $idempotencyKey, $floorPlan);
    }
    respond(200, $floorPlan);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/photos$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'attach_photo');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];

    $body = json_body();
    $missing = require_fields($body, ['url']);
    if ($missing !== null) {
        respondError(422, 'missing_required_fields', "Please include a 'url' pointing to the uploaded photo.", ['fields' => $missing]);
        return;
    }
    // Adjacent case to the session-creation fix elsewhere in this file, same
    // bug shape: is_http_url() takes a typed `string $url`, and a non-string
    // 'url' (array, number, bool) used to reach it under this file's own
    // declare(strict_types=1) and throw an uncaught TypeError — caught safely
    // by the global exception handler but surfaced as a generic 500 for a
    // client-side mistake that deserves a real 422. 'caption' is checked in
    // the same pass: it doesn't crash anything (never reaches a typed
    // parameter), but first_too_long() silently skips non-strings by design
    // (see its own comment), so a non-string caption used to sail straight
    // through to storage and come back out of a later GET as, say, a JSON
    // array where every consumer of this API expects a string.
    $notString = first_not_string($body, ['url', 'caption']);
    if ($notString !== null) {
        respondError(422, 'field_must_be_string', "'$notString' must be a plain string.", ['field' => $notString]);
        return;
    }
    if (!is_http_url($body['url'])) {
        respondError(422, 'invalid_url_scheme', "The photo 'url' must start with http:// or https://.");
        return;
    }
    $tooLong = first_too_long($body, ['url' => 2000, 'caption' => 2000]);
    if ($tooLong !== null) {
        [$tooLongField, $tooLongMax] = $tooLong;
        respondError(422, 'field_too_long', "'$tooLongField' is too long — please keep it to $tooLongMax characters or fewer.", ['field' => $tooLongField, 'max_length' => $tooLongMax]);
        return;
    }

    $photo = [
        'photo_id' => ScanSessionRepository::uuid(),
        'url' => $body['url'],
        'caption' => $body['caption'] ?? '',
        'room_id' => $body['room_id'] ?? null,
        'taken_at' => $body['taken_at'] ?? gmdate('c'),
    ];

    try {
        $floorPlan = $repo->appendPhoto($sessionId, $photo);
    } catch (\RuntimeException $e) {
        // Photos/notes attach to the same unit package, not a side-channel
        // (PHASES.md Phase 2) — there must be a captured FloorPlan first.
        respondError(409, 'no_floor_plan_yet', 'Please capture at least one room in this session before attaching photos.');
        return;
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unknown_room_id', $e->getMessage() . ' Omit room_id to attach this photo to the session generally, or check it against a room_id already returned by a capture call.');
        return;
    }

    respond(201, $floorPlan);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/notes$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'attach_note');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];

    $body = json_body();
    $missing = require_fields($body, ['text']);
    if ($missing !== null) {
        respondError(422, 'missing_required_fields', "Please include a 'text' field with the note's content.", ['fields' => $missing]);
        return;
    }
    // Same silent-acceptance gap as 'caption' on photos, found in the same
    // pass: first_too_long() skips non-strings by design, so a non-string
    // 'text' (e.g. a JSON array) used to be stored as-is and returned from
    // every later GET as something no consumer of this API expects.
    if (!is_string($body['text'])) {
        respondError(422, 'field_must_be_string', "'text' must be a plain string.", ['field' => 'text']);
        return;
    }
    $tooLong = first_too_long($body, ['text' => 5000]);
    if ($tooLong !== null) {
        [$tooLongField, $tooLongMax] = $tooLong;
        respondError(422, 'field_too_long', "'$tooLongField' is too long — please keep it to $tooLongMax characters or fewer.", ['field' => $tooLongField, 'max_length' => $tooLongMax]);
        return;
    }

    $note = [
        'note_id' => ScanSessionRepository::uuid(),
        'text' => $body['text'],
        'room_id' => $body['room_id'] ?? null,
        'created_at' => gmdate('c'),
    ];

    try {
        $floorPlan = $repo->appendNote($sessionId, $note);
    } catch (\RuntimeException $e) {
        respondError(409, 'no_floor_plan_yet', 'Please capture at least one room in this session before attaching notes.');
        return;
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unknown_room_id', $e->getMessage() . ' Omit room_id to attach this note to the session generally, or check it against a room_id already returned by a capture call.');
        return;
    }

    respond(201, $floorPlan);
    return;
}

if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/export/floorplan\.png$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'export_png');
    if ($session === null) {
        return;
    }
    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respondError(404, 'no_floor_plan_yet', 'This session doesn\'t have a captured floor plan yet — capture at least one room before exporting.');
        return;
    }

    try {
        $png = (new FloorPlanImageRenderer())->render($floorPlan);
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unrenderable_floor_plan', "This floor plan couldn't be rendered: " . $e->getMessage());
        return;
    }
    header('Content-Type: image/png');
    echo $png;
    return;
}

if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/export/floorplan\.pdf$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'export_pdf');
    if ($session === null) {
        return;
    }
    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respondError(404, 'no_floor_plan_yet', 'This session doesn\'t have a captured floor plan yet — capture at least one room before exporting.');
        return;
    }

    // Found by deliberately probing the adjacent case to the PNG route right
    // above: FloorPlanPdfRenderer::render() throws InvalidArgumentException
    // when a session's room count would need more than MAX_PAGES (200) PDF
    // pages, but — unlike PNG — nothing here caught it. The exception fell
    // through to the generic 500 handler: a landlord who ran a very large
    // multi-room session got "something went wrong on our end," masking a
    // legitimate, actionable client-side condition (too many rooms for one
    // export) behind a message that says the opposite of the truth.
    // Verified manually (not by an automated net): direct-injected a 9000-room
    // FloorPlan and hit this route before this catch existed — got a raw 500
    // "internal_error" with no actionable cause. Same injected data after
    // adding the catch — a clean 422 naming the real reason. Not automated
    // as a permanent net check because nets in this project are HTTP-only by
    // hard rule (never touch the PHP classes/SQLite directly — see any
    // net/verify_*.php header comment), and reproducing 205 real PDF pages
    // needs ~8,800 rooms, which the 60-calls/5-minute per-session capture
    // rate limit makes impractical to drive over real HTTP without weakening
    // that limit just to satisfy a test. Documented here and in README's
    // "Known limits" rather than silently left unverified.
    try {
        $pdf = (new FloorPlanPdfRenderer())->render($floorPlan);
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unrenderable_floor_plan', "This floor plan couldn't be rendered: " . $e->getMessage());
        return;
    }
    header('Content-Type: application/pdf');
    echo $pdf;
    return;
}

if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/access-log$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'view_access_log');
    if ($session === null) {
        return;
    }

    respond(200, ['scan_session_id' => $session['id'], 'access_log' => $repo->accessLog($session['id'])]);
    return;
}

if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'read');
    if ($session === null) {
        return;
    }

    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respond(200, ['scan_session_id' => $session['id'], 'status' => $session['status'], 'floor_plan' => null]);
        return;
    }

    respond(200, $floorPlan);
    return;
}

respondError(404, 'not_found', "This endpoint doesn't exist. Check the path and HTTP method against scan-service/README.md's API section.");
