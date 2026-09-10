# Scan Service

The single backend in this repo. Plain PHP 8.1+, PDO/SQLite, no framework, no Composer
dependency. See root `ARCHITECTURE.md` section 3.2.1 for the full component
description, and `docs/adr/0001-scan-service-stack.md` for why this stack.

## Run it (native PHP, no Docker)

```
cd scan-service
php -d post_max_size=30M -d upload_max_filesize=26M -d display_errors=0 -S 127.0.0.1:8089 public/index.php
```

`post_max_size=30M` (with `upload_max_filesize=26M`) is set intentionally above this app's own `MAX_REQUEST_BODY_BYTES`
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
php -d post_max_size=30M -d upload_max_filesize=26M -d display_errors=0 -S 0.0.0.0:8089 public/index.php
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
| POST | `/scan-sessions/{id}/rooms` | Wholesale-replace this session's rooms with a fused set (body: `captures[]`, one `raw_capture` per room) — used once a multi-room merge succeeds, superseding the individually-uploaded tiles from `capture` above without double-counting them. |
| POST | `/scan-sessions/{id}/photos` | Attach a photo by URL (e.g. one already returned by `photo-uploads` below), with optional caption/room id. |
| POST | `/scan-sessions/{id}/photo-uploads` | Upload real image bytes (multipart), content-sniffed via `finfo`, stored under `data/photos/{session_id}/`. Returns a `url` to pass into `/photos`. |
| GET | `/scan-sessions/{id}/photo-uploads/{filename}` | Fetch a previously uploaded photo. |
| DELETE | `/scan-sessions/{id}/photos/{photo_id}` | Remove a single attached photo. Also deletes the underlying uploaded file from disk, unless another photo entry still references the same file. |
| POST | `/scan-sessions/{id}/notes` | Attach a text note, with optional room id. |
| DELETE | `/scan-sessions/{id}/notes/{note_id}` | Remove a single attached note. |
| POST | `/scan-sessions/{id}/rooms/{room_id}/room-type` | Set or clear a room's `room_type.confirmed` after capture — body `{"room_type": "kitchen"}` or `{"room_type": null}` to clear. Independent of the live ✓/✗ capture-time prompt; works even on a room that never had a guess. |
| GET | `/scan-sessions/{id}/export/floorplan.png` | Fused single-layout PNG when every room in the session carries `structure_origin_m` (see `docs/adr/0002-export-coordinate-frame.md`); per-room tiles otherwise, or always with `?layout=tiles`. `?room_id=<id>` isolates one room's own tile. `?unit=metric\|imperial` (default `metric`) controls displayed measurement units. `?label=<text>` (120 chars max) adds an optional branding/caption line. |
| GET | `/scan-sessions/{id}/export/floorplan.pdf` | Per-room metrics-table PDF, all rooms unless narrowed with `?room_id=<id>`. Same `?unit=` and `?label=` params as the PNG export above. |
| GET | `/scan-sessions/{id}/access-log` | This session's `action`/`outcome`/`occurred_at` audit trail — never the token or caller IP. |
| GET | `/scan-sessions/{id}` | Fetch the current `FloorPlan` state for the session. |
| DELETE | `/scan-sessions/{id}` | Delete the session and everything attached to it (floor plan, photos, notes, access log). |
| GET | `/scan-sessions?property_id=&unit_id=&organisation_id=` | Look up sessions by any combination of those three filters — the only way to recover "what scans exist for this property" without already holding a session's id/token. Gated behind an `X-Admin-Api-Key` header matching `SCAN_SERVICE_ADMIN_API_KEY`; disabled entirely (always `401`) if that env var isn't set. Never returns `access_token`. |

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
  full — no login, no org-level isolation. TLS itself is available (see below) but not
  on by default for local dev.
- **TLS**: the app itself speaks plain HTTP only (same as any PHP `-S`/Docker setup);
  `Caddyfile` + `docker-compose.yml` in this directory put Caddy in front for automatic
  HTTPS the moment a real domain is pointed at the host — `SCAN_SERVICE_DOMAIN=scan.example.com
  docker compose up`. No manual certificate work: Caddy issues and renews a Let's
  Encrypt cert on its own as long as ports 80/443 are reachable from the internet for
  that domain. Point the iOS app's `ScanServiceBaseURL` at the `https://` domain once
  it's up. Not wired up for pure `127.0.0.1` local dev — Let's Encrypt can't issue a
  cert for an address with no real DNS record, which is the one thing this can't remove
  the need for.
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
  php net/verify_multiroom_fusion.php http://127.0.0.1:8089
  php net/verify_exports.php http://127.0.0.1:8089
  php net/verify_acl.php http://127.0.0.1:8089
  php net/verify_coverage.php http://127.0.0.1:8089
  php net/verify_openings_and_objects.php http://127.0.0.1:8089
  php net/verify_replace_rooms.php http://127.0.0.1:8089
  php net/verify_security_fixes.php http://127.0.0.1:8089
  php net/verify_error_messages.php http://127.0.0.1:8089
  php net/verify_session_delete.php http://127.0.0.1:8089
  php net/verify_enterprise_hardening.php http://127.0.0.1:8089
  ```
  `net/verify_post_body_read_rate_limit.php` is deliberately standalone — it floods a
  global per-IP bucket that would spuriously 429 every other script above if it shared
  a server, so run it last against its own fresh server/DB on a different port.
- `.github/workflows/scan-service-ci.yml` and `.gitlab-ci.yml` both run the full
  sequence above automatically. GitLab is where merges to this repo actually happen —
  that's the real merge gate.
