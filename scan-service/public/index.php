<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;
use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

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

header('X-Content-Type-Options: nosniff');

$corsOrigin = getenv('SCAN_SERVICE_CORS_ORIGIN') ?: 'http://127.0.0.1:8090';
if (($_SERVER['HTTP_ORIGIN'] ?? null) === $corsOrigin) {
    header("Access-Control-Allow-Origin: $corsOrigin");
    header('Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, X-Scan-Access-Token, Idempotency-Key');
}
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    return;
}

header('Content-Type: application/json');

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

function idempotencyFingerprint(array $body): string
{
    $relevant = [
        'raw_capture' => $body['raw_capture'] ?? null,
        'capture_provider' => $body['capture_provider'] ?? null,
        'capture_location' => $body['capture_location'] ?? null,
    ];
    try {
        return hash('sha256', json_encode($relevant, JSON_THROW_ON_ERROR));
    } catch (\JsonException $e) {
        return hash('sha256', serialize($relevant));
    }
}

function deleteSessionPhotoDir(string $sessionId): void
{
    $photoDir = __DIR__ . '/../data/photos/' . $sessionId;
    if (!is_dir($photoDir)) {
        return;
    }
    foreach (glob($photoDir . '/*') ?: [] as $file) {
        if (is_file($file)) {
            unlink($file);
        }
    }
    rmdir($photoDir);
}

const BACKUP_MIN_INTERVAL_SECONDS = 24 * 60 * 60;
const BACKUP_MAX_KEPT = 14;

function backupDatabaseIfDue(): void
{
    $dbPath = \VuuroScan\Storage\Database::resolvePath();
    if (!is_file($dbPath)) {
        return;
    }
    $backupDir = dirname($dbPath) . '/backups';
    if (!is_dir($backupDir) && !mkdir($backupDir, 0750, true) && !is_dir($backupDir)) {
        return;
    }

    $existing = glob($backupDir . '/*.sqlite') ?: [];
    $newest = 0;
    foreach ($existing as $file) {
        $newest = max($newest, (int) filemtime($file));
    }
    if ($newest !== 0 && time() - $newest < BACKUP_MIN_INTERVAL_SECONDS) {
        return;
    }

    $backupPath = $backupDir . '/' . gmdate('Ymd\THis\Z') . '.sqlite';
    if (!copy($dbPath, $backupPath)) {
        return;
    }

    $all = glob($backupDir . '/*.sqlite') ?: [];
    sort($all);
    $excess = count($all) - BACKUP_MAX_KEPT;
    for ($i = 0; $i < $excess; $i++) {
        unlink($all[$i]);
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

function respondError(int $status, string $errorCode, string $message, array $extra = []): void
{
    respond($status, ['error' => $errorCode, 'message' => $message, ...$extra]);
}

function require_fields(array $body, array $fields): ?array
{
    $missing = array_values(array_filter($fields, static fn ($f) => !array_key_exists($f, $body) || $body[$f] === ''));
    return $missing === [] ? null : $missing;
}

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

function adminAuthorized(): bool
{
    $configuredKey = getenv('SCAN_SERVICE_ADMIN_API_KEY');
    if (!is_string($configuredKey) || $configuredKey === '') {
        return false;
    }
    $presentedKey = $_SERVER['HTTP_X_ADMIN_API_KEY'] ?? '';
    return is_string($presentedKey) && $presentedKey !== '' && hash_equals($configuredKey, $presentedKey);
}

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

    if ($session !== null && !$granted) {
        if (rateLimited($repo, $session['id'] . ':denied_auth', 20, 300)) {
            return null;
        }
    } elseif ($session === null) {
        if (rateLimited($repo, clientIp() . ':session_not_found', 30, 300)) {
            return null;
        }
    }

    if ($session !== null && !($granted && $action === 'upload_photo')) {
        $repo->logAccess($session['id'], $action, $granted ? 'granted' : 'denied');
    }

    if (!$granted) {
        respondError(401, 'invalid_or_missing_access_token', 'This request needs a valid access token. Include the X-Scan-Access-Token header you were given when the session was created.');
        return null;
    }

    if ($repo->isTokenExpired($session)) {
      
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
    $postBodyReadMax = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_POST_BODY_READ_MAX') ?: 500);
    $postBodyReadWindowSeconds = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_POST_BODY_READ_WINDOW_SECONDS') ?: 300);
    if (rateLimited($repo, clientIp() . ':post_body_read', $postBodyReadMax, $postBodyReadWindowSeconds)) {
        return;
    }

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
    $createSessionMax = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX') ?: 60);
    $createSessionWindowSeconds = (int) (getenv('SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_WINDOW_SECONDS') ?: 600);
    if (rateLimited($repo, clientIp() . ':create_session', $createSessionMax, $createSessionWindowSeconds)) {
        return;
    }

    $body = json_body($rawRequestBody);
    foreach (['property_id', 'unit_id', 'organisation_id'] as $identityField) {
        if (is_string($body[$identityField] ?? null)) {
            $body[$identityField] = trim($body[$identityField]);
        }
    }
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

    backupDatabaseIfDue();

    if ($repo->lastInsertRowId() % 10 === 0) {
        foreach ($repo->findExpiredBeyondGracePeriod() as $expiredId) {
            $repo->deleteSession($expiredId);
            deleteSessionPhotoDir($expiredId);
        }
        foreach (['listing', 'check_in', 'check_out', 'renovation', 'other'] as $purposeToCheck) {
            $retentionDaysRaw = getenv('SCAN_SERVICE_RETENTION_DAYS_' . strtoupper($purposeToCheck));
            if ($retentionDaysRaw === false || !ctype_digit(trim((string) $retentionDaysRaw)) || (int) $retentionDaysRaw < 1) {
                continue;
            }
            foreach ($repo->findEarlyPurgeCandidates($purposeToCheck, (int) $retentionDaysRaw) as $expiredId) {
                $repo->deleteSession($expiredId);
                deleteSessionPhotoDir($expiredId);
            }
        }
    }
    respond(201, [
        ...$session,
        'occupied' => (bool) $session['occupied'],
        'consent_obtained' => (bool) $session['consent_obtained'],
    ]);
    return;
}

if ($method === 'GET' && $path === '/scan-sessions') {
    if (!adminAuthorized()) {
        if (rateLimited($repo, clientIp() . ':denied_admin_auth', 20, 300)) {
            return;
        }
        respondError(401, 'invalid_or_missing_admin_api_key', 'This request needs a valid admin key. Include the X-Admin-Api-Key header, and set SCAN_SERVICE_ADMIN_API_KEY on the server to enable this endpoint at all.');
        return;
    }
    if (rateLimited($repo, clientIp() . ':list_sessions', 60, 300)) {
        return;
    }

    $propertyId = isset($_GET['property_id']) && is_string($_GET['property_id']) && $_GET['property_id'] !== '' ? $_GET['property_id'] : null;
    $unitId = isset($_GET['unit_id']) && is_string($_GET['unit_id']) && $_GET['unit_id'] !== '' ? $_GET['unit_id'] : null;
    $organisationId = isset($_GET['organisation_id']) && is_string($_GET['organisation_id']) && $_GET['organisation_id'] !== '' ? $_GET['organisation_id'] : null;
    if ($propertyId === null && $unitId === null && $organisationId === null) {
        respondError(422, 'missing_filter', 'Please provide at least one of property_id, unit_id, or organisation_id to look up sessions.');
        return;
    }

    respond(200, ['sessions' => $repo->findByFilters($propertyId, $unitId, $organisationId)]);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/rotate-token$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'rotate_token');
    if ($session === null) {
        return;
    }
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
    if (rateLimited($repo, $session['id'] . ':capture', 60, 300)) {
        return;
    }

    $body = json_body($rawRequestBody);
    $idempotencyKey = $_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? null;
    $holdsIdempotencyClaim = false;
    if (is_string($idempotencyKey) && $idempotencyKey !== '') {
        if (mb_strlen($idempotencyKey, 'UTF-8') > 200) {
            respondError(422, 'idempotency_key_too_long', "The Idempotency-Key header is too long — please keep it to 200 characters or fewer.", ['max_length' => 200]);
            return;
        }

        $fingerprint = idempotencyFingerprint($body);

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

    $tooLongCaptureProvider = first_too_long($body, ['capture_provider' => 200]);
    if ($tooLongCaptureProvider !== null) {
        if ($holdsIdempotencyClaim) {
            $repo->releaseIdempotencyKey($session['id'], $idempotencyKey);
        }
        respondError(422, 'field_too_long', "'capture_provider' is too long — please keep it to 200 characters or fewer.", ['field' => 'capture_provider', 'max_length' => 200]);
        return;
    }

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

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/rooms$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'replace_rooms');
    if ($session === null) {
        return;
    }
    if (rateLimited($repo, $session['id'] . ':replace_rooms', 20, 300)) {
        return;
    }

    $body = json_body($rawRequestBody);
    if (empty($body['captures']) || !is_array($body['captures']) || !array_is_list($body['captures'])) {
        respondError(422, 'missing_captures', "Please include a 'captures' field with one raw_capture entry per fused room.");
        return;
    }
    if (count($body['captures']) > ScanSessionRepository::MAX_ROOMS_PER_SESSION) {
        respondError(422, 'too_many_rooms', 'captures[] has ' . count($body['captures']) . ' entries, exceeding the ' . ScanSessionRepository::MAX_ROOMS_PER_SESSION . '-room limit.');
        return;
    }

    $adapter = new RoomPlanSimulatorAdapter();
    $rooms = [];
    $captureProvider = 'roomplan_simulator_fixture';
    $capturedAt = gmdate('c');
    foreach ($body['captures'] as $index => $capture) {
        if (!is_array($capture) || empty($capture['raw_capture']) || !is_array($capture['raw_capture'])) {
            respondError(422, 'missing_raw_capture', "captures[$index] must include a 'raw_capture' field with the RoomPlan capture data for this room.");
            return;
        }
        if (isset($capture['capture_provider']) && !is_string($capture['capture_provider'])) {
            respondError(422, 'field_must_be_string', "captures[$index].capture_provider must be a plain string.");
            return;
        }
        try {
            $adapted = $adapter->adapt($capture['raw_capture'], [
                'scan_session_id' => $session['id'],
                'property_id' => $session['property_id'],
                'unit_id' => $session['unit_id'],
                'organisation_id' => $session['organisation_id'],
                'purpose' => $session['purpose'],
                'capture_provider' => $capture['capture_provider'] ?? 'roomplan_simulator_fixture',
                'capture_location' => $capture['capture_location'] ?? null,
            ], count($rooms));
        } catch (\InvalidArgumentException $e) {
            respondError(422, 'unprocessable_capture', "captures[$index] couldn't be processed: " . $e->getMessage());
            return;
        }
        $rooms = array_merge($rooms, $adapted['rooms']);
        $captureProvider = $adapted['capture_provider'];
        $capturedAt = $adapted['captured_at'];
    }

    try {
        $floorPlan = $repo->replaceRooms($session['id'], $rooms, $captureProvider, $capturedAt);
    } catch (\OverflowException $e) {
        respondError(422, 'too_many_rooms', $e->getMessage());
        return;
    } catch (\RuntimeException $e) {
        respondError(409, 'no_floor_plan_yet', $e->getMessage());
        return;
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

if ($method === 'DELETE' && preg_match('#^/scan-sessions/([^/]+)/photos/([^/]+)$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'delete_photo');
    if ($session === null) {
        return;
    }
    if (rateLimited($repo, $session['id'] . ':delete_photo', 60, 300)) {
        return;
    }

    try {
        $floorPlan = $repo->deletePhoto($session['id'], $m[2]);
    } catch (\RuntimeException $e) {
        respondError(409, 'no_floor_plan_yet', 'This session has no captured rooms yet.');
        return;
    } catch (\InvalidArgumentException $e) {
        respondError(404, 'photo_not_found', $e->getMessage());
        return;
    }

    respond(200, $floorPlan);
    return;
}

if ($method === 'DELETE' && preg_match('#^/scan-sessions/([^/]+)/notes/([^/]+)$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'delete_note');
    if ($session === null) {
        return;
    }
    if (rateLimited($repo, $session['id'] . ':delete_note', 60, 300)) {
        return;
    }

    try {
        $floorPlan = $repo->deleteNote($session['id'], $m[2]);
    } catch (\RuntimeException $e) {
        respondError(409, 'no_floor_plan_yet', 'This session has no captured rooms yet.');
        return;
    } catch (\InvalidArgumentException $e) {
        respondError(404, 'note_not_found', $e->getMessage());
        return;
    }

    respond(200, $floorPlan);
    return;
}

if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/rooms/([^/]+)/room-type$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'update_room_type');
    if ($session === null) {
        return;
    }
    $sessionId = $session['id'];
    $roomId = $m[2];

    if (rateLimited($repo, $sessionId . ':update_room_type', 60, 300)) {
        return;
    }

    $body = json_body($rawRequestBody);
    if (!array_key_exists('room_type', $body)) {
        respondError(422, 'missing_required_fields', "Please include a 'room_type' field (or null to clear it).", ['fields' => ['room_type']]);
        return;
    }
    $confirmed = $body['room_type'];
    if ($confirmed !== null && (!is_string($confirmed) || !in_array($confirmed, \VuuroScan\RoomType::CONFIRMED_VALUES, true))) {
        respondError(422, 'invalid_room_type', 'room_type must be one of the known values, or null to clear it.', ['allowed' => \VuuroScan\RoomType::CONFIRMED_VALUES]);
        return;
    }

    try {
        $floorPlan = $repo->updateRoomType($sessionId, $roomId, $confirmed);
    } catch (\RuntimeException $e) {
        respondError(409, 'no_floor_plan_yet', 'This session has no captured rooms yet.');
        return;
    } catch (\InvalidArgumentException $e) {
        respondError(422, 'unknown_room_id', $e->getMessage());
        return;
    }

    respond(200, $floorPlan);
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
    $unit = $_GET['unit'] ?? \VuuroScan\Export\UnitFormatter::METRIC;
    if (!in_array($unit, \VuuroScan\Export\UnitFormatter::VALID, true)) {
        respondError(422, 'invalid_unit', "'unit' must be 'metric' or 'imperial' if given.");
        return;
    }
    $label = isset($_GET['label']) ? trim((string) $_GET['label']) : null;
    if ($label !== null && mb_strlen($label, 'UTF-8') > 120) {
        respondError(422, 'field_too_long', "'label' is too long — please keep it to 120 characters or fewer.", ['field' => 'label', 'max_length' => 120]);
        return;
    }

    try {
        $png = (new FloorPlanImageRenderer())->render($floorPlan, $layout, $roomId, $unit, $label);
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

    $layout = $_GET['layout'] ?? 'auto';
    if (!in_array($layout, ['auto', 'tiles'], true)) {
        respondError(422, 'invalid_layout', "'layout' must be 'auto' or 'tiles' if given.");
        return;
    }
    $roomId = isset($_GET['room_id']) ? (string) $_GET['room_id'] : null;
    $unit = $_GET['unit'] ?? \VuuroScan\Export\UnitFormatter::METRIC;
    if (!in_array($unit, \VuuroScan\Export\UnitFormatter::VALID, true)) {
        respondError(422, 'invalid_unit', "'unit' must be 'metric' or 'imperial' if given.");
        return;
    }
    $label = isset($_GET['label']) ? trim((string) $_GET['label']) : null;
    if ($label !== null && mb_strlen($label, 'UTF-8') > 120) {
        respondError(422, 'field_too_long', "'label' is too long — please keep it to 120 characters or fewer.", ['field' => 'label', 'max_length' => 120]);
        return;
    }

    try {
        $pdf = (new FloorPlanPdfRenderer())->render($floorPlan, $layout, $roomId, $unit, $label);
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

if ($method === 'DELETE' && preg_match('#^/scan-sessions/([^/]+)$#', $path, $m)) {
    $session = authorizeSession($repo, $m[1], 'delete_session');
    if ($session === null) {
        return;
    }

    if (rateLimited($repo, $session['id'] . ':delete_session', 10, 300)) {
        return;
    }

    $repo->deleteSession($session['id']);
    deleteSessionPhotoDir($session['id']);

    respond(200, ['deleted' => true]);
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
