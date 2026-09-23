# Scan Service

The single backend in this repo. Plain PHP 8.1+, PDO/SQLite, no framework, no Composer
dependency. See root `ARCHITECTURE.md` section 3.2.1 for the full component
description, and `docs/adr/0001-scan-service-stack.md` for why this stack.

## Cross-platform note

The Scan Service and admin panel run identically on Mac, Windows, and Linux via
Docker. The Python scripts in this repo (run\*server.py, install\*\*.py) are
Windows-only dev tooling used on the original dev machine — end users never need
them.

This path is used by the original dev machine on Windows with XAMPP. Mac and Linux
users should prefer the Docker path below.

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

## Run it (Docker — any OS)

```
cd scan-service
docker compose up
open http://localhost:8089/admin in a browser
```

Sign in with the `SCAN_SERVICE_ADMIN_API_KEY` value (default is
`change-me-local-dev` if no `.env` was created).

Note: the default key is intentionally weak for local testing, and only works
because `SCAN_SERVICE_ENV` defaults to `development`. `docker-compose.prod.yml`
sets `SCAN_SERVICE_ENV=production`, which makes the app refuse to boot at all
(hard `RuntimeException`, not a silent fallback) if `SCAN_SERVICE_ADMIN_API_KEY`
or `SCAN_SERVICE_EXPORT_SECRET` is missing or still set to its default value —
see "Known limits". For anything shared with anyone else, copy `.env.example`
to `.env` and set both secrets regardless.

The `Dockerfile` builds on [FrankenPHP](https://frankenphp.dev/) (PHP embedded in
Caddy) rather than `php -S`, so it can actually serve concurrent requests instead of
one at a time — see "Known limits" for why the old built-in server was a problem.
It installs both `pdo_sqlite` and `gd` — PNG export needs `gd` and will 500 without
it.

## Local TLS test (self-signed, localhost only)

```
cd scan-service
sh scripts/tls-local-up.sh
curl -k https://localhost:8443/health
```

`docker-compose.tls-local.yml` adds a Caddy container with `tls internal` (Caddy's own
local CA) on `https://localhost:8443`, in front of the same `scan-service` container.
The script brings both up, waits for their health checks (the Caddy one hits `/health`
over HTTPS), prints the SHA-256 fingerprint of Caddy's local root certificate, and
fails unless `/health` returns 200 over HTTPS. Tear down with
`docker compose -f docker-compose.yml -f docker-compose.tls-local.yml down`.

This is for testing the HTTPS path only. The certificate is self-signed, so a phone
will not trust it without installing that root certificate, and `tls internal` must
never be used in `docker-compose.prod.yml`.

### Real certificate on a free subdomain (DuckDNS) — not configured yet

Once there is a host with a public IP, a free DuckDNS subdomain is enough for a real
Let's Encrypt certificate:

1. Sign in at duckdns.org, create a subdomain (e.g. `vuuro-scan.duckdns.org`), and set
   its IP to the host's public IP.
2. Keep the IP current if it can change: a cron job calling
   `https://www.duckdns.org/update?domains=vuuro-scan&token=<your token>&ip=`. The token
   is a secret; keep it out of git.
3. Open ports 80 and 443 to the host (Let's Encrypt's HTTP challenge needs port 80).
4. `SCAN_SERVICE_DOMAIN=vuuro-scan.duckdns.org docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d`.
   `Caddyfile` reads `SCAN_SERVICE_DOMAIN` (falling back to `localhost` if unset), and
   Caddy issues and renews the certificate itself.
5. Point the iOS app's `SCAN_SERVICE_BASE_URL` at `https://vuuro-scan.duckdns.org`.

## Off-box backups (free tier)

The app already writes local snapshots to `data/backups/*.sqlite` (`VACUUM INTO`), but
those live on the same disk as the database. `scripts/backup-offbox.sh` copies the
newest snapshot to object storage with [rclone](https://rclone.org):

- `daily/<snapshot name>.sqlite` on every run, keeping the newest
  `SCAN_SERVICE_BACKUP_KEEP_DAILY` (default 14);
- `weekly/<ISO week>.sqlite`, overwritten within the same week, keeping the newest
  `SCAN_SERVICE_BACKUP_KEEP_WEEKLY` (default 8).

It refuses to upload an empty or non-SQLite file, verifies the upload landed, and exits
non-zero with a clear log line if the remote is unreachable (exit codes: 2 bad config,
3 no usable local backup, 4 remote failure). Nightly schedule:
`scripts/backup-offbox.cron.example` (03:00).

Both free options below give 10 GB, far more than this SQLite database needs. Use one.

**Cloudflare R2** (10 GB free, no egress fees): create a bucket `vuuro-scan-backups`,
then an R2 API token with Object Read & Write on that bucket only.

```
rclone config create r2 s3 provider=Cloudflare   access_key_id=<key id> secret_access_key=<secret>   endpoint=https://<account id>.r2.cloudflarestorage.com   acl=private no_check_bucket=true
export SCAN_SERVICE_BACKUP_REMOTE=r2:vuuro-scan-backups
```

**Backblaze B2** (first 10 GB free): create a private bucket `vuuro-scan-backups` and an
application key restricted to it.

```
rclone config create b2 b2 account=<key id> key=<application key>
export SCAN_SERVICE_BACKUP_REMOTE=b2:vuuro-scan-backups
```

Then `sh scripts/backup-offbox.sh` once by hand before enabling the cron job.

Local test, no cloud account needed (Docker only): `sh scripts/test-offbox-backup.sh`
starts MinIO and an rclone container on a throwaway network, runs the script against
it, checks upload, content, daily/weekly retention, and the failure paths, then removes
everything.

Snapshots taken before the access-token hashing migration still contain plaintext
tokens. Delete old local snapshots rather than uploading them.

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
| POST | `/scan-sessions/{id}/photos` | Attach a photo by URL (e.g. one already returned by `photo-uploads` below), with optional caption/room id/`tags` (#21 inspection purpose tags — array from `VuuroScan\InspectionTag::VALUES`, defaults to `[]`). |
| POST | `/scan-sessions/{id}/photo-uploads` | Upload real image bytes (multipart), content-sniffed via `finfo`, stored under `data/photos/{session_id}/`. Returns a `url` to pass into `/photos`. |
| GET | `/scan-sessions/{id}/photo-uploads/{filename}` | Fetch a previously uploaded photo. |
| DELETE | `/scan-sessions/{id}/photos/{photo_id}` | Remove a single attached photo. Also deletes the underlying uploaded file from disk, unless another photo entry still references the same file. |
| POST | `/scan-sessions/{id}/notes` | Attach a text note, with optional room id/`tags` (#21 inspection purpose tags, same enum as photos, defaults to `[]`). |
| POST | `/scan-sessions/{id}/notes/{note_id}` | Edit a note's `text` in place; optionally replace its `tags` too (omit `tags` entirely to leave the existing ones untouched). |
| DELETE | `/scan-sessions/{id}/notes/{note_id}` | Remove a single attached note. |
| POST | `/scan-sessions/{id}/rooms/{room_id}/room-type` | Set or clear a room's `room_type.confirmed` after capture — body `{"room_type": "kitchen"}` or `{"room_type": null}` to clear. Independent of the live ✓/✗ capture-time prompt; works even on a room that never had a guess. |
| GET | `/scan-sessions/{id}/export/floorplan.png` | Fused single-layout PNG when every room in the session carries `structure_origin_m` (see `docs/adr/0002-export-coordinate-frame.md`); per-room tiles otherwise, or always with `?layout=tiles`. `?room_id=<id>` isolates one room's own tile. `?unit=metric\|imperial` (default `metric`) controls displayed measurement units. `?label=<text>` (120 chars max) adds an optional branding/caption line. |
| GET | `/scan-sessions/{id}/export/floorplan.svg` | Same layout/room_id/unit/label params and fused-vs-tiles logic as the PNG export, rendered as an SVG floor plan sheet instead (grid background, room fills by type, wall outlines, door-swing/window symbols, dimension labels). |
| GET | `/scan-sessions/{id}/export/floorplan.pdf` | Per-room metrics-table PDF, all rooms unless narrowed with `?room_id=<id>`. Same `?unit=` and `?label=` params as the PNG export above. |
| GET | `/scan-sessions/{id}/access-log` | This session's `action`/`outcome`/`occurred_at` audit trail — never the token or caller IP. |
| GET | `/scan-sessions/{id}` | Fetch the current `FloorPlan` state for the session. |
| DELETE | `/scan-sessions/{id}` | Delete the session and everything attached to it (floor plan, photos, notes, access log). |
| GET | `/scan-sessions?property_id=&unit_id=&organisation_id=` | Look up sessions by any combination of those three filters — the only way to recover "what scans exist for this property" without already holding a session's id/token. Gated behind an `X-Admin-Api-Key` header matching `SCAN_SERVICE_ADMIN_API_KEY`; disabled entirely (always `401`) if that env var isn't set. Never returns `access_token`. |

## Known limits

- **Single-instance runtime**: the app itself is still a single PHP process handling
  SQLite writes serially — FrankenPHP gives it a real concurrent HTTP server (no more
  one-request-at-a-time queuing on slow requests like large exports), but it is not a
  multi-node deployment. Fine for a single-instance pilot; a real production rollout
  would still want multiple app replicas behind a load balancer for anything beyond
  that.
- **Production secrets are fail-fast, not silently defaulted**: `SCAN_SERVICE_ENV`
  defaults to `development`, which allows the weak `change-me-local-dev` /
  `change-me-local-dev-signing` defaults so local setup works with zero config.
  `docker-compose.prod.yml` sets `SCAN_SERVICE_ENV=production`, and in that mode the
  app throws at boot (every request 500s until fixed) if `SCAN_SERVICE_ADMIN_API_KEY`
  or `SCAN_SERVICE_EXPORT_SECRET` is unset or still equal to its default value.
- **Body-size enforcement order**: `post_max_size` must stay set *above*
  `MAX_REQUEST_BODY_BYTES` (8MB). If they're equal, PHP's own SAPI-level check fires
  first, emitting a raw startup Warning that bypasses `set_exception_handler` (a
  Warning is not a `Throwable`) and leaves the HTTP status at 200 instead of the app's
  own `413`. This applies both to the native `php -S` invocation above and to the
  Docker image, which sets the same `post_max_size`/`upload_max_filesize` via
  `conf.d/scan-service.ini`.
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
- **TLS**: the app itself speaks plain HTTP only; Caddy terminates TLS in front of it.
  `docker-compose.prod.yml` + `Caddyfile` get a Let's Encrypt certificate automatically
  once `SCAN_SERVICE_DOMAIN` is a real DNS name pointed at the host (see "Real
  certificate on a free subdomain"). For local HTTPS testing without a domain, use the
  self-signed overlay in "Local TLS test". Let's Encrypt cannot issue for a bare
  `127.0.0.1`.
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
