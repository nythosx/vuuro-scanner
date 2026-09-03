<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;
use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

// Route every uncaught Throwable through one place: no stack trace, no
// server paths, and an honest 500 with the status code actually set.
ini_set('display_errors', '0');
error_reporting(E_ALL);
set_exception_handler(static function (\Throwable $e): void {
    http_response_code(500);
    header('Content-Type: application/json');
    echo json_encode([
        'error' => 'internal_error',
        'message' => "Something went wrong on our end while handling that request. Please try again in a moment, and if it keeps happening, let us know what you were doing.",
    ], JSON_PRETTY_PRINT);
});

// Stop a browser from MIME-sniffing a response (JSON, PNG, or PDF here)
// into something it decides to execute as HTML/JS.
header('X-Content-Type-Options: nosniff');

// CORS: local-dev-only, scoped to a single origin (default: the
// web-viewer's own dev server), not a wildcard. Override via
// SCAN_SERVICE_CORS_ORIGIN when the Scan Service or its web-viewer runs on
// a different host/port than the 127.0.0.1:8089/:8090 pairing this repo
// ships with — same env-var-with-a-default pattern as SCAN_SERVICE_DB_PATH
// in Database.php.
$corsOrigin = getenv('SCAN_SERVICE_CORS_ORIGIN') ?: 'http://127.0.0.1:8090';
if (($_SERVER['HTTP_ORIGIN'] ?? null) === $corsOrigin) {
    header("Access-Control-Allow-Origin: $corsOrigin");
    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, X-Scan-Access-Token, Idempotency-Key');
}
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    return;
}

header('Content-Type: application/json');

// GET /health — deliberately unauthenticated and touches nothing but the DB
// connection itself.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && rtrim(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), '/') === '/health') {
    try {
        Database::connect();
        respond(200, ['status' => 'ok', 'time' => gmdate('c')]);
    } catch (\Throwable $e) {
        respond(503, ['status' => 'unavailable', 'message' => 'The Scan Service cannot reach its database right now.']);
    }
    return;
}

const MAX_REQUEST_BODY_BYTES = 8 * 1024 * 1024;

function json_body(string $raw): array
{
    if ($raw === '') {
        return [];
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

/**
 * Fixed-window rate limiter shared by every route that calls it. `$bucket`
 * should combine the caller's IP or session with the route so unrelated
 * endpoints don't share a budget. Sends 429 + Retry-After and returns true
 * if the caller is over budget; records this call as an event either way,
 * since even a rejected attempt counts against the window.
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
// claim to finish. 20 x 50ms = 1s max. If it never resolves in that window,
// the caller gets a clean 409 rather than this looping forever.
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

/**
 * Fingerprints "is this the same request" for Idempotency-Key reuse
 * detection. Deliberately only the fields that define a distinct capture.
 * Falls back to serialize() when the payload can't be JSON-encoded (e.g. a
 * coordinate that overflowed to INF/NaN during decode) — serialize() has no
 * such restriction and is just as deterministic for fingerprinting purposes.
 */
function idempotencyFingerprint(array $body): string
{
    $relevant = [
        'raw_capture' => $body['raw_capture'] ?? null,
        'capture_provider' => $body['capture_provider'] ?? null,
    ];
    try {
        return hash('sha256', json_encode($relevant, JSON_THROW_ON_ERROR));
    } catch (\JsonException $e) {
        return hash('sha256', serialize($relevant));
    }
}

function clientIp(): string
{
    // No reverse proxy / load balancer in front of this local-dev service
    // today, so REMOTE_ADDR is trustworthy — deliberately NOT trusting
    // X-Forwarded-For, since that header is caller-supplied.
    return $_SERVER['REMOTE_ADDR'] ?? 'unknown';
}

function respond(int $status, array $body): void
{
    http_response_code($status);
    echo json_encode($body, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
}

/**
 * Every error response goes through here so `message` is never missing.
 * `error` is the stable, machine-readable code for client-side branching;
 * `message` is the sentence a UI can put in front of a user directly.
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
 * Returns [field, max] for the first field that's too long, or null if all
 * are fine.
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
        // mb_strlen(), not strlen(): every caller of this function tells the
        // client the limit is in "characters," and strlen() counts bytes.
        // json_body() already guarantees valid UTF-8.
        if (is_string($value) && mb_strlen($value, 'UTF-8') > $max) {
            return [$field, $max];
        }
    }
    return null;
}

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
 * all or the token presented is wrong, never a distinguishing 404 — that
 * would let a caller holding a leaked scan_session_id use the distinction
 * as a confirmation oracle. hash_equals() always runs against a
 * same-length dummy token when there's no real session to check against,
 * so a nonexistent session doesn't resolve measurably faster.
 */
function authorizeSession(ScanSessionRepository $repo, string $sessionId, string $action): ?array
{
    $session = $repo->find($sessionId);
    $token = presented_token() ?? '';

    if ($session !== null) {
        $granted = $repo->tokenMatches($session, $token);
    } else {
        hash_equals('00000000-0000-0000-0000-000000000000', $token);
        $granted = false;
    }

    // Two independent buckets: real-session-wrong-token is bounded per
    // session (an attacker can't fabricate a valid session id to dodge
    // this), session-not-found is bounded per caller IP. Only DENIED
    // attempts count — a legitimate client presenting the correct token
    // repeatedly never touches either bucket.
    //
    // ACL-surface scan finding: this check must run BEFORE logAccess()
    // below, not after. It used to run after, so a runaway client hammering
    // a session with a wrong token kept writing a 'denied' row to
    // access_log on every single request even once past the throttle —
    // rate-limiting the HTTP responses (401 -> 429) but not the underlying
    // audit-log growth it exists to bound. access_log has no cap and isn't
    // pruned (unlike rate_limit_events), so that was an unbounded-growth
    // vector through the very feature meant to stop one. Confirmed live
    // before the fix: 60 wrong-token requests against one session produced
    // 60 'denied' rows despite only the first 20 getting a real 401 (the
    // other 40 got 429). granted attempts are unaffected — they never reach
    // this branch, so they still log every single time as before.
    if ($session !== null && !$granted) {
        if (rateLimited($repo, $session['id'] . ':denied_auth', 20, 300)) {
            return null;
        }
    } elseif ($session === null) {
        if (rateLimited($repo, clientIp() . ':session_not_found', 30, 300)) {
            return null;
        }
    }

    // upload_photo always logs its own, more specific outcome below
    // (stored/rejected_*/failed_*) once granted, so logging a generic
    // 'granted' row here too would double-count every successful attempt.
    // Denials still log here — they never reach that downstream log.
    if ($session !== null && !($granted && $action === 'upload_photo')) {
        $repo->logAccess($session['id'], $action, $granted ? 'granted' : 'denied');
    }

    if (!$granted) {
        respondError(401, 'invalid_or_missing_access_token', 'This request needs a valid access token. Include the X-Scan-Access-Token header you were given when the session was created.');
        return null;
    }

    // Checked only after the token has already matched, so a caller who
    // doesn't hold the right token learns nothing new here.
    if ($repo->isTokenExpired($session)) {
        // Scoped narrowly — ONLY the rotate_token action gets this
        // exception, and only within ROTATE_GRACE_PERIOD_SECONDS of the
        // original expiry. Every other action stays hard-blocked at expiry.
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

$rawRequestBody = '';
if ($method === 'POST') {
    // Scan finding: every route below this point rate-limits its own
    // work, but ALL of them — including a request to a path that doesn't
    // even match a route — pass through this same up-to-8MB
    // file_get_contents() first, and nothing bounded how often THAT could
    // run. Confirmed live: 10 back-to-back 1MB POSTs to a nonexistent,
    // unauthenticated path were each fully read into memory before their
    // 404, with zero throttling anywhere on that path — the exact
    // resource-exhaustion shape the per-route limits below exist to
    // prevent, just reachable one layer earlier where none of them apply
    // yet (create_session's own rate limit doesn't even run until after
    // this read finishes). Generic per-IP cap here, checked BEFORE the
    // read so an over-limit caller is rejected without ever having 8MB
    // buffered on their behalf. 500/300s is generous next to any real
    // client's combined traffic (well above this repo's own net suite's
    // peak burst) while still bounding sustained flooding.
    if (rateLimited($repo, clientIp() . ':post_body_read', 500, 300)) {
        return;
    }

    // Bounds the ACTUAL bytes read off php://input (the 5th
    // file_get_contents() argument caps how many bytes are pulled from the
    // stream), independent of any client-supplied header — Content-Length
    // alone isn't trustworthy since chunked Transfer-Encoding omits it.
    // Read exactly once here and threaded through to every route's
    // json_body($rawRequestBody) call below.
    $rawRequestBody = file_get_contents('php://input', false, null, 0, MAX_REQUEST_BODY_BYTES + 1);
    if ($rawRequestBody === false) {
        $rawRequestBody = '';
    }
    if (strlen($rawRequestBody) > MAX_REQUEST_BODY_BYTES) {
        $maxMb = round(MAX_REQUEST_BODY_BYTES / (1024 * 1024), 1);
        respondError(413, 'payload_too_large', "This request is larger than the {$maxMb}MB limit. If this is a real capture, check for an unexpectedly large field rather than retrying as-is.", ['max_bytes' => MAX_REQUEST_BODY_BYTES]);
        return;
    }
}

if ($method === 'POST' && $path === '/scan-sessions') {
    // Session creation is the one endpoint with no token to gate it.
    // Bounded per caller IP; overridable via env for a pilot deployment
    // behind one shared IP range.
    $createSessionMax = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX') ?: 60);
    $createSessionWindowSeconds = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_WINDOW_SECONDS') ?: 600);
    if (rateLimited($repo, clientIp() . ':create_session', $createSessionMax, $createSessionWindowSeconds)) {
        return;
    }

    $body = json_body($rawRequestBody);
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
    // recorded consent — checked at the earliest possible point (session
    // creation), not left for capture time or later cleanup.
    if ($body['occupied'] === true && $consentObtained !== true) {
        respondError(403, 'consent_required', 'This unit is marked occupied, so tenant consent must be recorded (consent_obtained: true) before a scan session can be created.');
        return;
    }

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

    // Each rotation is a real DB write and immediately invalidates the
    // token just used, so unbounded rotation is also a self-inflicted
    // lockout risk for a legitimate caller racing itself.
    if (rateLimited($repo, $session['id'] . ':rotate_token', 10, 300)) {
        return;
    }

    $body = json_body($rawRequestBody);
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

    // Bounds a runaway client (or a compromised token) from hammering the
    // adapter/renderer pipeline indefinitely.
    if (rateLimited($repo, $session['id'] . ':capture', 60, 300)) {
        return;
    }

    // Idempotent retry support: a client resubmitting the exact same
    // capture after a dropped response gets back the stored result instead
    // of appending the room a second time.
    $body = json_body($rawRequestBody);
    $idempotencyKey = $_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? null;
    $holdsIdempotencyClaim = false;
    if (is_string($idempotencyKey) && $idempotencyKey !== '') {
        if (mb_strlen($idempotencyKey, 'UTF-8') > 200) {
            respondError(422, 'idempotency_key_too_long', "The Idempotency-Key header is too long — please keep it to 200 characters or fewer.", ['max_length' => 200]);
            return;
        }

        $fingerprint = idempotencyFingerprint($body);

        // A key reused with a DIFFERENT body must not silently replay a
        // stale response for the wrong capture. Checked against the
        // fingerprint recorded at claim time even while another request's
        // capture is still pending.
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

        // Two requests with the SAME key can both reach this point with
        // $cached === null if they arrive close enough together. Only the
        // request that wins this atomic claim may actually run the capture
        // below — see ScanSessionRepository::claimIdempotencyKey.
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
        // Releasing here (and at the two other 422 exits below) makes the
        // SAME key usable again on a corrected retry.
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        respondError(422, 'missing_raw_capture', "Please include a 'raw_capture' field with the RoomPlan capture data for this room.");
        return;
    }

    if (array_key_exists('capture_provider', $body) && !is_string($body['capture_provider'])) {
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        respondError(422, 'field_must_be_string', "'capture_provider' must be a plain string.", ['field' => 'capture_provider']);
        return;
    }

    // Exports-surface scan finding: capture_provider had a type check but no
    // length cap, unlike every other client-suppliable string field
    // (property_id/unit_id/organisation_id at 200, url/caption at 2000, note
    // text at 5000, Idempotency-Key at 200). Confirmed live: a 500,000-char
    // capture_provider was accepted (still well under the 8MB whole-request
    // cap) and flowed straight into the stored FloorPlan, inflating a normal
    // ~1.3KB PDF export to ~500KB on every export call — a client-controlled
    // amplification path through storage and every later export/render,
    // capped nowhere along the way. 200 chars matches the identity-field cap
    // above; capture_provider is an identifier ("roomplan_simulator_fixture"
    // etc.), not free text, so the same bound fits.
    $tooLongCaptureProvider = first_too_long($body, ['capture_provider' => 200]);
    if ($tooLongCaptureProvider !== null) {
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        respondError(422, 'field_too_long', "'capture_provider' is too long — please keep it to 200 characters or fewer.", ['field' => 'capture_provider', 'max_length' => 200]);
        return;
    }

    // capture_location: honest null when not sent; malformed is rejected, same bar as capture_provider.
    if (array_key_exists('capture_location', $body) && $body['capture_location'] !== null) {
        $loc = $body['capture_location'];
        $locValid = is_array($loc)
            && isset($loc['lat'], $loc['lon'], $loc['accuracy_m'])
            && (is_int($loc['lat']) || is_float($loc['lat'])) && is_finite((float) $loc['lat']) && abs((float) $loc['lat']) <= 90
            && (is_int($loc['lon']) || is_float($loc['lon'])) && is_finite((float) $loc['lon']) && abs((float) $loc['lon']) <= 180
            && (is_int($loc['accuracy_m']) || is_float($loc['accuracy_m'])) && is_finite((float) $loc['accuracy_m']) && (float) $loc['accuracy_m'] >= 0
            && (!isset($loc['captured_at']) || is_string($loc['captured_at']));
        if (!$locValid) {
            if ($holdsIdempotencyClaim) {
                $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
            }
            respondError(422, 'invalid_capture_location', "'capture_location', when present, needs numeric lat (-90..90), lon (-180..180), and accuracy_m (>=0).", ['field' => 'capture_location']);
            return;
        }
    }

    $adapter = new RoomPlanSimulatorAdapter();
    try {
        // Offset by rooms already captured this session, so a second or
        // third guided RoomPlan capture in the same session continues room
        // numbering instead of restarting at "Room 1".
        $roomIndexOffset = $repo->roomCount($session['id']);
        $capturedFloorPlan = $adapter->adapt($body['raw_capture'], [
            'scan_session_id' => $session['id'],
            'property_id' => $session['property_id'],
            'unit_id' => $session['unit_id'],
            'organisation_id' => $session['organisation_id'],
            'purpose' => $session['purpose'],
            'capture_provider' => $body['capture_provider'] ?? 'roomplan_simulator_fixture',
            'capture_location' => $body['capture_location'] ?? null,
        ], $roomIndexOffset);
    } catch (\InvalidArgumentException $e) {
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        respondError(422, 'unprocessable_capture', "This capture couldn't be processed: " . $e->getMessage() . ' Please rescan this room.');
        return;
    }

    // Capture-surface scan finding: appendCapture() can genuinely throw
    // (BEGIN IMMEDIATE can hit SQLite's own busy_timeout under real write
    // contention from an overlapping request — see
    // tests/concurrency_test.php's own doc comment on this mechanism), but
    // this block used to run uncaught. The global exception handler still
    // turns that into a clean 500 with no stack trace, so the HTTP response
    // was never the problem — but with $holdsIdempotencyClaim true, nothing
    // released the claim first, so it stayed in IDEMPOTENCY_PENDING_MARKER
    // forever: a retry with that SAME Idempotency-Key would get
    // capture_in_progress on every future attempt, permanently, with no
    // visible link back to the original 500. Same silent-lockout shape as
    // the "idempotency claims stuck on validation failure" bug fixed
    // earlier, just triggered by a genuine transient failure instead of a
    // 422. Reproduced live under real multi-process lock contention (the
    // same technique tests/concurrency_test.php uses) before this fix:
    // appendCapture() threw SQLSTATE[HY000] "database is locked" while
    // holding a claim, and the claim was still stuck afterward.
    // Capture-surface scan finding: appendCapture() enforces
    // MAX_ROOMS_PER_SESSION with an \OverflowException (same cap style as
    // photos/notes), but that used to fall into the generic \Throwable catch
    // below and get rethrown into the global handler's raw 500 instead of a
    // clean 422 like every other overflow response
    // (too_many_photos/too_many_notes). Confirmed live: the 11th capture
    // call past the cap returned a bare "internal_error" 500 with no
    // actionable message. Caught here first, same pattern as photos/notes.
    try {
        $floorPlan = $repo->appendCapture($session['id'], $capturedFloorPlan);
        $repo->markCaptured($session['id']);
    } catch (\OverflowException $e) {
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        respondError(422, 'too_many_rooms', $e->getMessage() . ' Start a new scan session to continue capturing rooms.');
        return;
    } catch (\Throwable $e) {
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        throw $e;
    }
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

    if (rateLimited($repo, $sessionId . ':attach_photo', 60, 300)) {
        return;
    }

    $body = json_body($rawRequestBody);
    $missing = require_fields($body, ['url']);
    if ($missing !== null) {
        respondError(422, 'missing_required_fields', "Please include a 'url' pointing to the uploaded photo.", ['fields' => $missing]);
        return;
    }
    $notString = first_not_string($body, ['url', 'caption', 'taken_at']);
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
    } catch (\OverflowException $e) {
        // Caught BEFORE \RuntimeException below — \OverflowException
        // extends \RuntimeException in PHP's SPL hierarchy.
        respondError(422, 'too_many_photos', $e->getMessage() . ' Start a new scan session to continue attaching photos.');
        return;
    } catch (\RuntimeException $e) {
        respondError(409, 'no_floor_plan_yet', 'Please capture at least one room in this session before attaching photos.');
        return;
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unknown_room_id', $e->getMessage() . ' Omit room_id to attach this photo to the session generally, or check it against a room_id already returned by a capture call.');
        return;
    }

    respond(201, $floorPlan);
    return;
}

// The brief lists "photos" as a first-class listing asset, but the /photos
// route above only ever accepted a URL to an image already hosted
// somewhere else — this repo never actually stored image bytes (see
// scan-service/README.md's former "Known limits" entry). These two routes
// close that gap: upload real bytes here, get back a URL, then call
// POST /scan-sessions/{id}/photos with that URL exactly as before — the
// existing photos contract is unchanged, this just gives it something real
// to point at.
const MAX_PHOTO_UPLOAD_BYTES = 25 * 1024 * 1024;
const PHOTO_UPLOAD_MIME_EXTENSIONS = [
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/heic' => 'heic',
    'image/webp' => 'webp',
];

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/photo-uploads$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'upload_photo');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];

    if (rateLimited($repo, $sessionId . ':upload_photo', 30, 300)) {
        return;
    }

    // Multipart bodies bypass the generic php://input size gate near the top
    // of this file entirely (php://input is empty for multipart/form-data —
    // a PHP SAPI-level limitation, not something this app controls), so this
    // route needs its own explicit size check rather than relying on that
    // gate having already run.
    if (!isset($_FILES['photo']) || !is_array($_FILES['photo'])) {
        $repo->logAccess($sessionId, 'upload_photo', 'rejected_missing_file');
        respondError(422, 'missing_photo_file', "Please include a 'photo' file field (multipart/form-data) with the image to upload.");
        return;
    }

    $file = $_FILES['photo'];
    if ($file['error'] !== UPLOAD_ERR_OK) {
        $tooLarge = in_array($file['error'], [UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE], true);
        $repo->logAccess($sessionId, 'upload_photo', $tooLarge ? 'rejected_too_large' : 'rejected_upload_error');
        respondError(
            422,
            $tooLarge ? 'photo_too_large' : 'photo_upload_failed',
            $tooLarge ? 'The uploaded photo is too large.' : 'The photo upload failed — please try again.'
        );
        return;
    }

    if ($file['size'] > MAX_PHOTO_UPLOAD_BYTES) {
        $maxMb = round(MAX_PHOTO_UPLOAD_BYTES / (1024 * 1024), 1);
        $repo->logAccess($sessionId, 'upload_photo', 'rejected_too_large');
        respondError(422, 'photo_too_large', "Photos are limited to {$maxMb}MB.", ['max_bytes' => MAX_PHOTO_UPLOAD_BYTES]);
        return;
    }

    // Sniffs the actual bytes rather than trusting the client-supplied
    // filename/Content-Type — same "don't trust the client's own label"
    // principle as is_http_url()'s scheme check above.
    $mime = (new \finfo(FILEINFO_MIME_TYPE))->file($file['tmp_name']);
    if (!isset(PHOTO_UPLOAD_MIME_EXTENSIONS[$mime])) {
        $repo->logAccess($sessionId, 'upload_photo', 'rejected_unsupported_type');
        respondError(
            422,
            'unsupported_photo_type',
            'Photos must be JPEG, PNG, HEIC, or WebP.',
            ['allowed' => array_values(PHOTO_UPLOAD_MIME_EXTENSIONS)]
        );
        return;
    }

    $photoUploadId = ScanSessionRepository::uuid();
    $filename = $photoUploadId . '.' . PHOTO_UPLOAD_MIME_EXTENSIONS[$mime];
    $storageDir = __DIR__ . '/../data/photos/' . $sessionId;
    if (!is_dir($storageDir) && !mkdir($storageDir, 0755, true) && !is_dir($storageDir)) {
        $repo->logAccess($sessionId, 'upload_photo', 'failed_storage_error');
        respondError(500, 'internal_error', 'Could not create photo storage for this session.');
        return;
    }
    if (!move_uploaded_file($file['tmp_name'], $storageDir . '/' . $filename)) {
        $repo->logAccess($sessionId, 'upload_photo', 'failed_storage_error');
        respondError(500, 'internal_error', 'Could not save the uploaded photo.');
        return;
    }

    $repo->logAccess($sessionId, 'upload_photo', 'stored');
    $scheme = (($_SERVER['HTTPS'] ?? 'off') !== 'off') ? 'https' : 'http';
    $url = "{$scheme}://{$_SERVER['HTTP_HOST']}/scan-sessions/{$sessionId}/photo-uploads/{$filename}";
    respond(201, ['url' => $url, 'photo_upload_id' => $photoUploadId]);
    return;
}

if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/photo-uploads/([a-f0-9\-]+\.(?:jpg|png|heic|webp))$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'read_photo_upload');
    if ($session === null) {
        return;
    }

    if (rateLimited($repo, $session['id'] . ':read_photo_upload', 120, 300)) {
        return;
    }

    $filename = $m[2];
    $filePath = __DIR__ . '/../data/photos/' . $session['id'] . '/' . $filename;
    if (!is_file($filePath)) {
        respondError(404, 'photo_not_found', 'No uploaded photo found at this URL.');
        return;
    }

    $extension = pathinfo($filename, PATHINFO_EXTENSION);
    $mimeByExtension = array_flip(PHOTO_UPLOAD_MIME_EXTENSIONS);
    header('Content-Type: ' . ($mimeByExtension[$extension] ?? 'application/octet-stream'));
    readfile($filePath);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/notes$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'attach_note');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];

    if (rateLimited($repo, $sessionId . ':attach_note', 60, 300)) {
        return;
    }

    $body = json_body($rawRequestBody);
    $missing = require_fields($body, ['text']);
    if ($missing !== null) {
        respondError(422, 'missing_required_fields', "Please include a 'text' field with the note's content.", ['fields' => $missing]);
        return;
    }
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
    } catch (\OverflowException $e) {
        respondError(422, 'too_many_notes', $e->getMessage() . ' Start a new scan session to continue attaching notes.');
        return;
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

    // Rendering is expensive (FloorPlanImageRenderer can allocate up to a
    // 4000x4000 truecolor canvas per call) — bounded generously per
    // session, well above any real workflow.
    if (rateLimited($repo, $session['id'] . ':export_png', 30, 300)) {
        return;
    }

    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respondError(404, 'no_floor_plan_yet', 'This session doesn\'t have a captured floor plan yet — capture at least one room before exporting.');
        return;
    }

    $layout = $_GET['layout'] ?? 'auto';
    if (!in_array($layout, ['auto', 'tiles'], true)) {
        respondError(422, 'invalid_layout', "'layout' must be 'auto' or 'tiles' if given.");
        return;
    }
    $roomId = isset($_GET['room_id']) ? (string) $_GET['room_id'] : null;

    try {
        $png = (new FloorPlanImageRenderer())->render($floorPlan, $layout, $roomId);
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

    // PDF rendering can walk up to MAX_PAGES (200) pages per call, an
    // independent and comparably expensive cost to PNG export.
    if (rateLimited($repo, $session['id'] . ':export_pdf', 30, 300)) {
        return;
    }

    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respondError(404, 'no_floor_plan_yet', 'This session doesn\'t have a captured floor plan yet — capture at least one room before exporting.');
        return;
    }

    $roomId = isset($_GET['room_id']) ? (string) $_GET['room_id'] : null;

    try {
        $pdf = (new FloorPlanPdfRenderer())->render($floorPlan, $roomId);
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

    if (rateLimited($repo, $session['id'] . ':view_access_log', 120, 300)) {
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

    if (rateLimited($repo, $session['id'] . ':read', 120, 300)) {
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
