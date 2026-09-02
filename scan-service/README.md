# Scan Service

The single backend in this repo. Plain PHP 8.1+, PDO/SQLite, no framework, no Composer
dependency. See root `ARCHITECTURE.md` section 3.2.1 for the full component
description, and `docs/adr/0001-scan-service-stack.md` for why this stack.

## Run it (native PHP, no Docker)

```
cd scan-service
php -d post_max_size=16M -d display_errors=0 -S 127.0.0.1:8089 public/index.php
```

`post_max_size=16M` is set intentionally above this app's own `MAX_REQUEST_BODY_BYTES`
cap (8MB, in `public/index.php`) — see "Known limits" below for why the two must not be
set equal.

Requires the `pdo_sqlite` PHP extension (bundled with most PHP installs) and, for PNG
export, the `gd` extension.

The schema in `migrations/schema.sql` is applied fresh on boot — no separate migration
step. The database file lives at `data/scan_service.sqlite` (gitignored) or wherever
`SCAN_SERVICE_DB_PATH` points.

## Run it (Docker, host-independent)

```
cd scan-service
docker build -t vuuro-scan-service .
docker run -p 8089:8089 -v "$(pwd)/data:/app/data" vuuro-scan-service
```

The `Dockerfile` installs both `pdo_sqlite` and `gd` — PNG export needs `gd` and will
500 without it (see "Known limits").

## Testing this locally from a real device (not just Simulator/curl)

If you're pointing a real iOS device at this instance over Wi-Fi rather than testing
from the same machine, bind to all interfaces instead of loopback:

```
php -d post_max_size=16M -d display_errors=0 -S 0.0.0.0:8089 public/index.php
```

See `ios-app/README.md`'s real-device checklist for the full walkthrough.

## API reference

Every route below except `POST /scan-sessions` and `GET /health` requires an
`X-Scan-Access-Token` header (see `docs/adr/0003-privacy-acl-session-tokens.md`).

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Unauthenticated liveness check — touches only the DB connection. |
| POST | `/scan-sessions` | Create a session. Body carries `ScanIdentity` (property/unit/organisation, purpose, `occupied`, `consent_obtained`). Returns the session id and its one-time access token. `occupied: true` requires `consent_obtained: true` or `403 consent_required`. |
| POST | `/scan-sessions/{id}/rotate-token` | Issue a new token before or within `ROTATE_GRACE_PERIOD_SECONDS` (7 days) after expiry. |
| POST | `/scan-sessions/{id}/capture` | Submit `raw_capture` (RoomPlan-shaped JSON) + `capture_provider`. Converted via the matching adapter into the `FloorPlan` contract. Supports `Idempotency-Key` for safe retries. |
| POST | `/scan-sessions/{id}/photos` | Attach a photo by URL (e.g. one already returned by `photo-uploads` below), with optional caption/room id. |
| POST | `/scan-sessions/{id}/photo-uploads` | Upload real image bytes (multipart), content-sniffed via `finfo`, stored under `data/photos/{session_id}/`. Returns a `url` to pass into `/photos`. |
| GET | `/scan-sessions/{id}/photo-uploads/{filename}` | Fetch a previously uploaded photo. |
| POST | `/scan-sessions/{id}/notes` | Attach a text note, with optional room id. |
| GET | `/scan-sessions/{id}/export/floorplan.png` | Per-room PNG tile(s) — see `docs/adr/0002-export-coordinate-frame.md` for why these aren't a fused layout. |
| GET | `/scan-sessions/{id}/export/floorplan.pdf` | Per-room metrics-table PDF. |
| GET | `/scan-sessions/{id}/access-log` | This session's `action`/`outcome`/`occurred_at` audit trail — never the token or caller IP. |
| GET | `/scan-sessions/{id}` | Fetch the current `FloorPlan` state for the session. |

## Known limits

- **Body-size enforcement order**: `post_max_size` must stay set *above*
  `MAX_REQUEST_BODY_BYTES` (8MB). If they're equal, PHP's own SAPI-level check fires
  first, emitting a raw startup Warning that bypasses `set_exception_handler` (a
  Warning is not a `Throwable`) and leaves the HTTP status at 200 instead of the app's
  own `413`. This applies to both the native `php -S` invocation above and the
  Dockerfile's `CMD`.
- **Rate limiting**: per-session and per-caller-IP fixed-window buckets on session
  creation (default 60 per 600s window, overridable via
  `SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX` /
  `SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_WINDOW_SECONDS`), capture, exports (PNG/PDF
  independently), failed-auth attempts, and the raw request-body read itself. Old
  rate-limit events are pruned after `RATE_LIMIT_EVENT_RETENTION_SECONDS` (1 hour).
  This is DoS-resistance for a single-instance pilot, not a substitute for an edge/CDN
  rate limiter in a real deployment.
- **Token model is per-session, not per-account**: see
  `docs/adr/0003-privacy-acl-session-tokens.md`'s "what this doesn't solve" section in
  full — no login, no org-level isolation, no TLS in this repo.
- **Export bounds**: PNG canvas capped at 4000px per side
  (`FloorPlanImageRenderer::MAX_CANVAS_DIMENSION_PX`); PDF capped at 200 pages
  (`FloorPlanPdfRenderer::MAX_PAGES`). A capture large enough to exceed either is
  rejected rather than silently truncated.
- **No framework, no Composer**: intentional per `docs/adr/0001`, not an oversight —
  don't introduce either without updating that ADR first.

## Testing

- `tests/*_test.php` — fast, in-process unit tests, no server needed:
  `adapter_test.php`, `repository_test.php`, `export_renderer_test.php`,
  `concurrency_test.php` (a real multi-process `proc_open` test — the write-lock race it
  checks can't be proven any other way against `php -S`'s single-threaded server).
- `net/verify_*.php` — the independent net, the actual merge gate. HTTP-only, re-derives
  expected results with separate logic, never imports `src/`. Run in order (all but the
  last are chained against one shared server/DB — `verify_enterprise_hardening.php`'s
  rate-limit check must run last):
  ```
  php net/verify_capture_geometry.php http://127.0.0.1:8089
  php net/verify_multiroom_and_attachments.php http://127.0.0.1:8089
  php net/verify_exports.php http://127.0.0.1:8089
  php net/verify_acl.php http://127.0.0.1:8089
  php net/verify_coverage.php http://127.0.0.1:8089
  php net/verify_openings_and_objects.php http://127.0.0.1:8089
  php net/verify_security_fixes.php http://127.0.0.1:8089
  php net/verify_error_messages.php http://127.0.0.1:8089
  php net/verify_enterprise_hardening.php http://127.0.0.1:8089
  ```
  `net/verify_post_body_read_rate_limit.php` is deliberately standalone — it floods a
  global per-IP bucket that would spuriously 429 every other script above if it shared
  a server, so run it last against its own fresh server/DB on a different port.
- `.github/workflows/scan-service-ci.yml` and `.gitlab-ci.yml` both run the full
  sequence above automatically. GitLab is where merges to this repo actually happen —
  that's the real merge gate.
