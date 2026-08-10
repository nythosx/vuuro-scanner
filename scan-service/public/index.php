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
    echo json_encode(['error' => 'internal_error'], JSON_PRETTY_PRINT);
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
    header('Access-Control-Allow-Headers: Content-Type, X-Scan-Access-Token');
}
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    return;
}

header('Content-Type: application/json');

function json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === '' || $raw === false) {
        return [];
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

function respond(int $status, array $body): void
{
    http_response_code($status);
    echo json_encode($body, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
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
 * Returns the first field name that's too long, or null if all are fine.
 */
function first_too_long(array $body, array $maxLengths): ?string
{
    foreach ($maxLengths as $field => $max) {
        $value = $body[$field] ?? null;
        if (is_string($value) && strlen($value) > $max) {
            return $field;
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

    if (!$granted) {
        respond(401, ['error' => 'invalid_or_missing_access_token']);
        return null;
    }

    return $session;
}

$db = Database::connect();
$repo = new ScanSessionRepository($db);

$method = $_SERVER['REQUEST_METHOD'];
$path = rtrim(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), '/');

// POST /scan-sessions
if ($method === 'POST' && $path === '/scan-sessions') {
    $body = json_body();
    // Hard constraint #1: identity-native captures. A session cannot be
    // created without property/unit/organisation — no orphan captures by
    // construction, not by convention.
    $missing = require_fields($body, ['property_id', 'unit_id', 'organisation_id', 'purpose', 'occupied']);
    if ($missing !== null) {
        respond(422, ['error' => 'missing_required_fields', 'fields' => $missing]);
        return;
    }
    $tooLongField = first_too_long($body, ['property_id' => 200, 'unit_id' => 200, 'organisation_id' => 200]);
    if ($tooLongField !== null) {
        respond(422, ['error' => 'field_too_long', 'field' => $tooLongField]);
        return;
    }
    $validPurposes = ['listing', 'check_in', 'check_out', 'renovation', 'other'];
    if (!in_array($body['purpose'], $validPurposes, true)) {
        respond(422, ['error' => 'invalid_purpose', 'allowed' => $validPurposes]);
        return;
    }
    if (!is_bool($body['occupied'])) {
        respond(422, ['error' => 'occupied_must_be_boolean']);
        return;
    }
    $consentObtained = $body['consent_obtained'] ?? false;
    if (!is_bool($consentObtained)) {
        respond(422, ['error' => 'consent_obtained_must_be_boolean']);
        return;
    }
    // Hard constraint #3: an occupied unit cannot be scanned without
    // recorded consent — this is checked at the earliest possible point
    // (session creation), not left for capture time or later cleanup.
    if ($body['occupied'] === true && $consentObtained !== true) {
        respond(403, ['error' => 'consent_required', 'message' => 'occupied units require consent_obtained: true before a session can be created']);
        return;
    }

    $session = $repo->create(
        $body['property_id'],
        $body['unit_id'],
        $body['organisation_id'],
        $body['purpose'],
        $body['occupied'],
        $consentObtained
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

// POST /scan-sessions/{id}/capture
if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/capture$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'capture');
    if ($session === null) {
        return;
    }

    $body = json_body();
    if (empty($body['raw_capture']) || !is_array($body['raw_capture'])) {
        respond(422, ['error' => 'missing_raw_capture', 'hint' => 'body must include raw_capture: <RoomPlan-shaped capture JSON>']);
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
        respond(422, ['error' => 'unprocessable_capture', 'message' => $e->getMessage()]);
        return;
    }

    $floorPlan = $repo->appendCapture($session['id'], $capturedFloorPlan);
    $repo->markCaptured($session['id']);
    respond(200, $floorPlan);
    return;
}

// POST /scan-sessions/{id}/photos
if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/photos$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'attach_photo');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];

    $body = json_body();
    $missing = require_fields($body, ['url']);
    if ($missing !== null) {
        respond(422, ['error' => 'missing_required_fields', 'fields' => $missing]);
        return;
    }
    if (!is_http_url($body['url'])) {
        respond(422, ['error' => 'invalid_url_scheme', 'message' => 'url must start with http:// or https://']);
        return;
    }
    $tooLongField = first_too_long($body, ['url' => 2000, 'caption' => 2000]);
    if ($tooLongField !== null) {
        respond(422, ['error' => 'field_too_long', 'field' => $tooLongField]);
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
        respond(409, ['error' => 'no_floor_plan_yet', 'message' => $e->getMessage()]);
        return;
    }

    respond(201, $floorPlan);
    return;
}

// POST /scan-sessions/{id}/notes
if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/notes$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'attach_note');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];

    $body = json_body();
    $missing = require_fields($body, ['text']);
    if ($missing !== null) {
        respond(422, ['error' => 'missing_required_fields', 'fields' => $missing]);
        return;
    }
    $tooLongField = first_too_long($body, ['text' => 5000]);
    if ($tooLongField !== null) {
        respond(422, ['error' => 'field_too_long', 'field' => $tooLongField]);
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
        respond(409, ['error' => 'no_floor_plan_yet', 'message' => $e->getMessage()]);
        return;
    }

    respond(201, $floorPlan);
    return;
}

// GET /scan-sessions/{id}/export/floorplan.png
if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/export/floorplan\.png$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'export_png');
    if ($session === null) {
        return;
    }
    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respond(404, ['error' => 'no_floor_plan_yet']);
        return;
    }

    try {
        $png = (new FloorPlanImageRenderer())->render($floorPlan);
    } catch (\InvalidArgumentException $e) {
        respond(422, ['error' => 'unrenderable_floor_plan', 'message' => $e->getMessage()]);
        return;
    }
    header('Content-Type: image/png');
    echo $png;
    return;
}

// GET /scan-sessions/{id}/export/floorplan.pdf
if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/export/floorplan\.pdf$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'export_pdf');
    if ($session === null) {
        return;
    }
    $floorPlan = $repo->findFloorPlan($session['id']);
    if ($floorPlan === null) {
        respond(404, ['error' => 'no_floor_plan_yet']);
        return;
    }

    header('Content-Type: application/pdf');
    echo (new FloorPlanPdfRenderer())->render($floorPlan);
    return;
}

// GET /scan-sessions/{id}/access-log
if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)/access-log$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'view_access_log');
    if ($session === null) {
        return;
    }

    respond(200, ['scan_session_id' => $session['id'], 'access_log' => $repo->accessLog($session['id'])]);
    return;
}

// GET /scan-sessions/{id}
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

respond(404, ['error' => 'not_found']);
