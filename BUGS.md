How to Read This File
Status — OPEN, IN PROGRESS, FIXED, WITHDRAWN, WONTFIX

Severity — Critical, High, Medium, Low

Effort — S (hours), M (day), L (days)

CRITICAL
[1.1] Built-in PHP server as production runtime
Status: OPEN

Severity: Critical

Effort: M

Location: Dockerfile (CMD), docker-compose.prod.yml

Issue:
The production runtime is php -S 0.0.0.0:8089. The PHP manual explicitly states php -S is for development and testing only. It is single-threaded — one request at a time. Caddy fronts it but does not change the fact that the backend processes requests serially. Under any concurrent load, requests queue and time out.

Evidence:

text
CMD ["php", "-S", "0.0.0.0:8089"]
Impact:

One slow request blocks all other requests.

A large export (see 2.4) blocks the entire server for the duration of the response.

No graceful restart, no process management, no connection pooling.

Fix:

Replace with PHP-FPM + Nginx or Caddy as a reverse proxy to FPM.

Or use a proper application server like FrankenPHP or RoadRunner.

Update docker-compose.prod.yml accordingly.

[1.2] SQLite WAL not enabled; no retry on lock contention
Status: OPEN

Severity: Critical

Effort: S

Location: src/Storage/Database.php (connect), ScanSessionRepository::withWriteLock

Issue:
Two problems:

journal_mode = WAL is never set. Default journal mode is DELETE, which blocks readers during writers and is slower under concurrency.

withWriteLock has no retry loop. If a SQLITE_BUSY occurs after the 5-second busy_timeout, the raw PDOException propagates to the caller, which returns a 500.

Evidence:

php
$pdo->exec('PRAGMA foreign_keys = ON;');
$pdo->exec('PRAGMA busy_timeout = 5000;');
// No journal_mode = WAL
php
private function withWriteLock(callable $fn): mixed
{
$this->db->exec('BEGIN IMMEDIATE');
try {
$result = $fn();
$this->db->exec('COMMIT');
return $result;
} catch (\Throwable $e) {
$this->db->exec('ROLLBACK');
throw $e; // No retry
}
}
Impact:

Write contention causes 500s under load.

Readers are blocked during writes (DELETE journal mode).

Single-threaded server (1.1) compounds the problem.

Fix:

php
$pdo->exec('PRAGMA journal_mode = WAL;');
$pdo->exec('PRAGMA synchronous = NORMAL;');
$pdo->exec('PRAGMA busy_timeout = 5000;');
Add retry with exponential backoff:

php
private function withWriteLock(callable $fn): mixed
{
    $attempts = 0;
    $maxAttempts = 3;
    while (true) {
        try {
            $this->db->exec('BEGIN IMMEDIATE');
            $result = $fn();
            $this->db->exec('COMMIT');
            return $result;
        } catch (\PDOException $e) {
            $this->db->exec('ROLLBACK');
            if (str_contains($e->getMessage(), 'database is locked') && ++$attempts < $maxAttempts) {
usleep(100_000 \* $attempts);
continue;
}
throw $e;
} catch (\Throwable $e) {
$this->db->exec('ROLLBACK');
throw $e;
}
}
}
[1.6] Webhook unauthenticated
Status: OPEN

Severity: Critical

Effort: S

Location: public/index.php publish-to-platform handler

Issue:
The webhook sends the session payload to the receiving platform with no signature, no shared secret, and no authentication. The receiving platform cannot verify the request came from VuuroScan.

Evidence:

php
'header' => "Content-Type: application/json\r\n" .
"X-Vuuro-Scan-Session: {$session['id']}\r\n" .
            "Content-Length: " . strlen($payloadJson) . "\r\n",
The URL is only validated as https?://.

Impact:

Anyone who knows the webhook URL can send arbitrary payloads.

Receiving platform cannot distinguish real from fake.

No replay protection.

Fix:

Add HMAC-SHA256 signature header: X-Vuuro-Signature: sha256=<hmac>.

Include timestamp and nonce to prevent replay.

Receiving platform verifies signature before processing.

Use a shared secret from environment variables.

[2.1] Default secrets in docker-compose.yml
Status: OPEN

Severity: Critical (per audit, originally High)

Effort: S

Location: docker-compose.yml

Issue:
Both the admin API key and export signing secret default to publicly-known values.

Evidence:

yaml
SCAN_SERVICE_ADMIN_API_KEY: ${SCAN_SERVICE_ADMIN_API_KEY:-change-me-local-dev}
SCAN_SERVICE_EXPORT_SECRET: ${SCAN_SERVICE_EXPORT_SECRET:-change-me-local-dev-signing}
Impact:

If deployed without overriding these, anyone can access admin endpoints.

Export signatures can be forged.

These defaults are in the public repo.

Fix:

Remove the :-change-me-local-dev defaults.

Fail fast at startup if secrets are missing or still set to default.

Add a startup check:

php
if (getenv('SCAN_SERVICE_ADMIN_API_KEY') === false
|| getenv('SCAN_SERVICE_ADMIN_API_KEY') === 'change-me-local-dev') {
throw new \RuntimeException('SCAN_SERVICE_ADMIN_API_KEY must be set to a secure value');
}
Document in .env.example with placeholder only.

[B.1] Concurrent captures collide on room_id and return 500
Status: OPEN

Severity: Critical (promoted from new finding)

Effort: M

Location: public/index.php capture handler + ScanSessionRepository::appendCapture

Issue:
roomCount() is read outside the write lock. Two concurrent capture requests both read roomCount() = 0 and both generate room-01. The first writes successfully. The second hits a duplicate room ID check inside appendCapture and throws RuntimeException, which propagates to a generic 500.

Evidence:

php
$adapter = new RoomPlanSimulatorAdapter();
try {
    $roomIndexOffset = $repo->roomCount($session['id']); // <-- read outside lock
$capturedFloorPlan = $adapter->adapt($body['raw_capture'], [...], $roomIndexOffset);
} catch (\Throwable $e) {
    // ...
}
php
$duplicateRoomIds = array_intersect($existingRoomIds, $newRoomIds);
if (!empty($duplicateRoomIds)) {
throw new \RuntimeException(
'Capture retried with room_id(s) already present on this session: ...'
);
}
Impact:

Legitimate concurrent uploads from multi-room clients (iOS TaskGroup) return 500.

Client may retry indefinitely.

Idempotency claim is released, so retry is safe, but the client sees a 500 and may not retry correctly.

Fix (option A — generate IDs inside lock):
Move roomCount() and ID generation inside appendCapture under the write lock.

Fix (option B — return structured 409):

php
if (!empty($duplicateRoomIds)) {
respondError(409, 'room_id_conflict', 'Room IDs already exist on this session. Retry with new IDs.', [
'retry_after_ms' => 250,
]);
return;
}
Option B is simpler but requires client cooperation. Option A is more robust.

HIGH
[2.2] Admin-key brute-force protection shared across endpoints on same IP bucket
Status: OPEN

Severity: High

Effort: M

Location: public/index.php rate limiter

Issue:
Rate limiting is keyed on IP only, not on endpoint + IP. One abusive client can exhaust the shared bucket for all admin endpoints from that IP.

Impact:

Self-DoS: one bad actor from an IP blocks all admin access from that IP.

Legitimate admin locked out by an attacker sharing the same NAT/proxy IP.

Fix:

Key rate limit buckets on endpoint + clientIp().

Or use a token bucket per API key with a separate IP-based global cap.

[2.4] Export bundles unbounded (base64 PNG + PDF embedded in JSON)
Status: OPEN

Severity: High

Effort: M

Location: public/index.php export handler

Issue:
png_base64 and pdf_base64 are embedded in the JSON export with no size cap. A 40-room session's PNG approaches the 4000px canvas limit, and the PDF embeds every photo.

Impact:

On the single-threaded server (1.1), this blocks all other requests for the duration of the response.

Memory exhaustion on large exports.

Large JSON payloads over the wire.

Fix:

Add max_size guard before embedding.

Stream large exports instead of embedding.

Return download URLs instead of base64 blobs.

Or cap the export at a documented room count (see B.10).

[2.5] MAX_REQUEST_BODY_BYTES check reads up to 8MB into PHP memory after PHP already buffered
Status: OPEN

Severity: High

Effort: S

Location: public/index.php request size check

Issue:
PHP has already buffered the request body up to post_max_size before the application-level check runs. The check reads up to 8MB into PHP memory unnecessarily.

Impact:

Memory waste on every large request.

The check is post-hoc, not preventative.

Fix:

Set post_max_size and upload_max_filesize in PHP config.

Use Content-Length header check before reading body.

Reject early with 413 if Content-Length exceeds limit.

[2.6] clientIp() ignores X-Forwarded-For behind Caddy
Status: OPEN

Severity: High

Effort: S

Location: public/index.php clientIp()

Issue:
Behind Caddy (from docker-compose.prod.yml), REMOTE_ADDR is the Caddy container's IP. Every rate-limit bucket keyed on clientIp() becomes a bucket keyed on the proxy.

Evidence:

php
function clientIp(): string
{
// (four blank lines)

    return $_SERVER['REMOTE_ADDR'] ?? 'unknown';

}
The blank lines are almost certainly where the proxy-aware logic was intended.

Impact:

Per-IP rate limiting is defeated.

Self-DoS: one abusive client exhausts the shared bucket for all users.

Access logs show Caddy's IP, not the real client.

Fix:

php
function clientIp(): string
{
$trustedProxies = ['127.0.0.1', '::1', '172.16.0.0/12']; // Caddy container range
$remote = $\_SERVER['REMOTE_ADDR'] ?? 'unknown';

    if (in_array($remote, $trustedProxies, true) || isTrustedProxy($remote)) {
        $forwarded = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? '';
        if ($forwarded !== '') {
            $ips = array_map('trim', explode(',', $forwarded));
            return $ips[0]; // leftmost = original client
        }
    }

    return $remote;

}
Configure Caddy to set X-Forwarded-For correctly.

[2.7] backupDatabaseIfDue race between mtime check and touch()
Status: OPEN

Severity: High

Effort: S

Location: src/Storage/Database.php backupDatabaseIfDue()

Issue:
Race condition between the filemtime() check and touch(). Two concurrent requests can both see the backup as due and both run it.

Impact:

Duplicate backup files.

Disk space waste.

Potential corruption if both write to the same path.

Fix:

Use flock() on a lock file before checking and running backup.

Or use touch() with O_EXCL semantics via a temp file + atomic rename.

Ensure backup path includes a unique suffix if concurrent backups are acceptable.

MEDIUM
[1.5] Fragile XSS defence
Status: OPEN (downgraded from Critical)

Severity: Medium

Effort: S

Location: admin.js, admin HTML response

Issue:
Every interpolation in admin.js currently passes through escapeHtml(). No unescaped interpolation of user data was found. However:

No Content-Security-Policy header on the admin HTML response.

No automated test that feeds <script> payloads through every rendered field.

The escaping discipline depends entirely on every future PR remembering to call escapeHtml().

Impact:

A single missed escapeHtml() in a future PR becomes stored XSS.

No defence-in-depth if an escape is missed.

Fix:

Add CSP header:

text
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none';
Add an automated test that feeds <script>alert(1)</script> through every rendered field and asserts it appears escaped.

Consider using a templating engine with auto-escaping, or DOM APIs (textContent) instead of string interpolation.

[B.2] Non-string room_id produces a confusing error message
Status: OPEN

Severity: Medium

Effort: S

Location: public/index.php photo and note handlers

Issue:
If room_id is an array (e.g., client sends "room_id": ["x"]), string interpolation emits an Array to string conversion warning and produces room_id 'Array'. The client gets unknown_room_id with a nonsensical message.

Evidence:

php
throw new \InvalidArgumentException(
"room_id '{$item['room_id']}' does not match any room captured in this session."
);
There is no explicit is_string check on room_id in either handler.

Fix:

php
if (array_key_exists('room_id', $body)
    && $body['room_id'] !== null
    && !is_string($body['room_id'])) {
respondError(422, 'field_must_be_string', 'room_id must be a string.');
return;
}
[B.3] taken_at on photos is neither length-limited nor format-validated
Status: OPEN

Severity: Medium

Effort: S

Location: public/index.php photo handler

Issue:
taken_at is passed through verbatim. first_not_string catches non-string values, but there is no length cap. A client can send a 1MB string, which is stored in the JSON floor plan and re-serialised on every read.

Evidence:

php
$tooLong = first_too_long($body, ['url' => 2000, 'caption' => 2000]);
// taken_at not in map
...
'taken_at' => $body['taken_at'] ?? gmdate('c'),
Impact:

Small DoS surface: JSON contract grows unboundedly.

Storage bloat.

Fix:

Add 'taken_at' => 100 to the first_too_long map.

Validate against an ISO 8601 pattern if format enforcement is desired.

[B.4] Missing migrations/schema.sql creates a silent empty database
Status: OPEN

Severity: Medium

Effort: S

Location: src/Storage/Database.php

Issue:
If migrations/schema.sql is missing (bad Docker build, .dockerignore misconfiguration), file_get_contents returns false, (string) false is '', and $pdo->exec('') is a no-op. The database is created but empty. The first session creation then fails with a cryptic PDOException at an unpredictable point.

Evidence:

php
$schema = __DIR__ . '/../../migrations/schema.sql';
$pdo->exec((string) file_get_contents($schema));
Fix:

php
if (!is_file($schema)) {
    throw new \RuntimeException("Schema file not found at {$schema}");
}
$schemaSql = file_get_contents($schema);
if ($schemaSql === false || trim($schemaSql) === '') {
throw new \RuntimeException("Schema file at {$schema} is empty or unreadable");
}
$pdo->exec($schemaSql);
[B.5] Import failure is not logged; only a generic 500 is returned
Status: OPEN

Severity: Medium

Effort: S

Location: public/index.php import handler

Issue:
The specific exception (constraint violation, disk error) is discarded. The error_log call in the global exception handler never fires because the exception is caught here.

Evidence:

php
try {
$stored = $repo->insertImportedScan($record);
} catch (\Throwable $e) {
respondError(500, 'import_failed', 'Could not save the imported scan.');
return;
}
Fix:

php
} catch (\Throwable $e) {
error_log("Import failed: " . $e->getMessage() . "\n" . $e->getTraceAsString());
respondError(500, 'import_failed', 'Could not save the imported scan.');
return;
}
[3.2] Admin search has no pagination (hard-coded LIMIT 100)
Status: OPEN

Severity: Medium

Effort: S

Location: admin.js / admin search endpoint

Issue:
Search results are capped at 100 with no pagination. Users cannot see beyond the first 100 results.

Fix:

Add offset and limit query parameters.

Add pagination controls in the admin UI.

[3.3] Room-type correction not exposed in admin UI
Status: OPEN

Severity: Medium

Effort: M

Location: admin.js, admin UI

Issue:
The backend supports room-type correction, but the admin UI does not expose it.

Fix:

Add UI controls for room-type correction.

Or document that this is API-only and remove from scope.

[3.6] Net test scripts accumulate sessions and DB rows
Status: OPEN

Severity: Medium

Effort: S

Location: net/verify\_\*.php

Issue:
Net test scripts create sessions and database rows without cleanup. Repeated CI runs accumulate data.

Fix:

Add teardown logic to delete created sessions.

Or use a separate test database that is reset between runs.

LOW
[4.1] Schema migration swallows all PDOExceptions
Status: OPEN

Severity: Low

Effort: S

Location: src/Storage/Database.php

Issue:
The migration execution catches all PDOExceptions without logging or re-throwing. Errors are silently ignored.

Fix:

Log the exception.

Re-throw if the schema is critical.

[4.2] No duplicate-ID check on appendPhoto/appendNote
Status: OPEN

Severity: Low

Effort: S

Location: ScanSessionRepository

Issue:
appendCapture has a duplicate room ID check, but appendPhoto and appendNote do not.

Fix:

Add duplicate ID checks for photos and notes.

Or document that duplicates are intentional.

[4.4] .env.example omits CORS, webhook, DB path, and rate-limit overrides
Status: OPEN

Severity: Low

Effort: S

Location: .env.example

Issue:
Several environment variables used in code are not documented in .env.example.

Fix:

Add all environment variables with placeholder values and comments.

[4.6] Fusion solver O(n³) with no room-count guard, and runs before canvas-size check
Status: OPEN

Severity: Low

Effort: M

Location: FloorPlanFusionSolver

Issue:
O(n³) complexity with no guard on room count. Runs before the canvas-size check, so it does unnecessary work on sessions that will fail the canvas check anyway.

Fix:

Add a room-count guard before running the solver.

Move the canvas-size check earlier.

[4.7] verify_enterprise_hardening.php session-creation loop is not configurable
Status: OPEN

Severity: Low

Effort: S

Location: net/verify_enterprise_hardening.php

Issue:
The session-creation loop count is hard-coded.

Fix:

Make it configurable via environment variable or CLI argument.

[4.8] SVG and PNG renderers duplicate constants and drawing logic
Status: OPEN

Severity: Low

Effort: M

Location: SVG renderer, PNG renderer

Issue:
Both renderers duplicate constants (MAX_CANVAS_DIMENSION_PX, etc.) and drawing logic. Divergence risk.

Fix:

Extract shared constants and drawing logic into a common module.

[4.10] CORS test coupled to default configuration
Status: OPEN

Severity: Low

Effort: S

Location: CORS test

Issue:
The CORS test asserts behavior tied to the default http://127.0.0.1:8090 origin. Breaks if the default changes.

Fix:

Parameterize the test on the configured origin.

[4.11] alert()/prompt() for clipboard feedback
Status: OPEN

Severity: Low

Effort: S

Location: admin.js

Issue:
Uses alert() and prompt() for clipboard feedback. Blocks the UI and is poor UX.

Fix:

Use a toast notification or inline feedback.

[4.12] Admin panel assumes data.rooms is always an array
Status: OPEN

Severity: Low

Effort: S

Location: admin.js

Issue:
If data.rooms is not an array (malformed response), the admin panel throws.

Fix:

Add Array.isArray(data.rooms) guard.

[B.6] Import bundle signature is checked after structural validation
Status: OPEN

Severity: Low

Effort: S

Location: public/index.php import handler

Issue:
Signature is verified after structural validation. An attacker with the admin key can learn the bundle structure without knowing the export secret.

Impact:
Low given admin gating, but defensive-in-depth.

Fix:

Move verifyBundleSignature immediately after JSON parse and format check.

[B.8] verify_post_body_read_rate_limit.php lacks explicit exit(0)
Status: OPEN

Severity: Low

Effort: S

Location: net/verify_post_body_read_rate_limit.php

Issue:
Script ends without exit(0). Functionally fine (falls through to 0), but inconsistent with other verify scripts.

Fix:

Add exit(0); at the end for consistency.

[B.9] hash_equals in the nonexistent-session branch is a no-op
Status: OPEN

Severity: Low

Effort: S

Location: public/index.php authorizeSession

Issue:
The hash_equals result is discarded. The intent is to equalize timing, but the call has no effect. Surrounding control flow leaks timing regardless.

Evidence:

php
if ($session !== null) {
    $granted = $repo->tokenMatches($session, $token);
} else {
hash_equals('00000000-0000-0000-0000-000000000000', $token); // result discarded
$granted = false;
}
Fix:
