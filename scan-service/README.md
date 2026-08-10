# Scan Service

Phase 1 ("proof of capture") plus Phase 2 groundwork (multi-room stitching, photos and
notes) plus a first slice of Phase 3 (PNG/PDF exports, privacy/ACL, coverage/quality
cues). See `../PHASES.md` and `../CLAUDE.md` for the product context — this file is just
how to run and verify what's here.

## What's here

- `public/index.php` — HTTP API (front controller, no framework).
- `src/Adapters/RoomPlanSimulatorAdapter.php` — converts a RoomPlan-shaped capture
  payload into the vendor-neutral `FloorPlan` contract (`../contracts/floorplan.schema.json`).
  This is the only place that knows RoomPlan vocabulary.
- `src/ScanSessionRepository.php`, `src/Storage/Database.php` — PDO/SQLite storage.
  `appendCapture()` stitches a new capture's rooms onto a session's existing FloorPlan
  rather than overwriting it — that's what makes a multi-room session possible.
- `fixtures/` — hand-built, RoomPlan-CapturedRoom-shaped capture payloads. **Not** real
  RoomPlan or RoomPlan-simulator output — no Mac/Xcode was reachable to produce that on
  this machine. See `../docs/adr/0001-scan-service-stack.md` for what that does and
  does not prove, and what to do once real device/simulator access exists.
- `src/Export/FloorPlanImageRenderer.php`, `FloorPlanPdfRenderer.php` — PNG/PDF export,
  pure GD and hand-built PDF bytes, no external libraries. Renders each room as its own
  accurately-scaled tile, not a spatially fused building layout — see
  `../docs/adr/0002-export-coordinate-frame.md` for why that's the honest choice given
  how multi-room sessions are captured.
- `src/ScanSessionRepository.php`'s `tokenMatches()`/`logAccess()` — privacy/ACL (hard
  constraint #3): every session-scoped endpoint requires a matching access token and
  every attempt (granted or denied) is audit-logged. See
  `../docs/adr/0003-privacy-acl-session-tokens.md` for the honest scope of what this
  does and does not solve.
- `RoomPlanSimulatorAdapter::computeCoverage()` — per-room scan quality score
  (PHASES.md Phase 3), aggregated across every surface RoomPlan reported for a capture
  call (floor, walls, doors, windows, openings), not just the floor's own confidence.
- `tests/adapter_test.php` — fast in-process regression + adjacent-case tests against
  the adapter directly.
- `net/verify_phase1.php`, `net/verify_phase2.php`, `net/verify_phase3_exports.php`,
  `net/verify_phase3_acl.php`, `net/verify_phase3_coverage.php`,
  `net/verify_security_fixes.php` — the independent net (CLAUDE.md hard constraint #6).
  Talk to the live HTTP API only, re-derive expected geometry/structure with their own
  separately-written logic, and never import the adapter/repository/renderer. These are
  the merge gate, not the unit tests above.
- `net/verify_security_fixes.php` specifically re-runs a manual security review's
  exploits (an uncaught-exception info leak, a session-existence enumeration oracle, and
  unbounded capture geometry) against the live server and confirms each is closed. See
  the fix comments in `public/index.php`, `src/Adapters/RoomPlanSimulatorAdapter.php`,
  `src/Export/FloorPlanImageRenderer.php`, and `src/Storage/Database.php` for what each
  one was and why.

## Run it (native PHP, no Docker)

Requires PHP 8.1+ with `pdo_sqlite` (bundled with the standard PHP Windows build).

```
cd scan-service
php -S 127.0.0.1:8089 public/index.php
```

In another shell:

```
# Fast dev-loop tests (adapter only, no server needed)
php tests/adapter_test.php

# The net — merge gate, needs the server above running
php net/verify_phase1.php http://127.0.0.1:8089
php net/verify_phase2.php http://127.0.0.1:8089
php net/verify_phase3_exports.php http://127.0.0.1:8089
php net/verify_phase3_acl.php http://127.0.0.1:8089
php net/verify_phase3_coverage.php http://127.0.0.1:8089
php net/verify_security_fixes.php http://127.0.0.1:8089
```

All seven must print `VERDICT: GREEN` (exit code 0) before merging, per CLAUDE.md:
"nothing merges past a red verdict."

## Run it (Docker, host-independent)

```
docker build -t vuuro-scan-service .
docker run --rm -p 8089:8089 vuuro-scan-service
```

Then run the `net/verify_phase*.php` scripts from the host against the container the
same way as above.

## API

Every endpoint below except `POST /scan-sessions` requires an `X-Scan-Access-Token`
header matching that session's `access_token` (returned exactly once, in the session
creation response) — a session id alone is never sufficient. See
`../docs/adr/0003-privacy-acl-session-tokens.md`. Missing or wrong token → `401`.

- `POST /scan-sessions` — `{property_id, unit_id, organisation_id, purpose, occupied, consent_obtained?}`
  → `201` with the created session, including its one-time `access_token`. Any missing
  identity field or a missing `occupied` is rejected with `422` (hard constraint #1: no
  orphan captures). If `occupied: true` and `consent_obtained` is not also `true`,
  rejected with `403 consent_required` (hard constraint #3). `property_id`/`unit_id`/
  `organisation_id` are capped at 200 characters (`422 field_too_long` otherwise).
- `POST /scan-sessions/{id}/capture` — `{raw_capture: <RoomPlan-shaped JSON>}` → `200`
  with the resulting `FloorPlan` contract. **Callable more than once per session** — each
  call is treated as one more guided RoomPlan capture (one room) and its rooms are
  appended to the session's FloorPlan, not overwritten. This is how a multi-room "unit
  story" session is built: capture room 1, call again for room 2, etc. Capture geometry
  is sanity-bounded (finite, ≤1000m coordinates, ≤50 floors, ≤1000 points/floor, ≤500
  surfaces/group) — see `RoomPlanSimulatorAdapter`'s `MAX_*` constants.
- `POST /scan-sessions/{id}/photos` — `{url, caption?, room_id?}` → `201` with the
  updated `FloorPlan`. Requires a capture to already exist for the session (`409`
  otherwise) — photos attach to the same unit package, never a separate side-channel.
  `url` must start with `http://` or `https://` (`422 invalid_url_scheme` otherwise —
  this field is documented as a future image source, so `javascript:`/`data:` etc. are
  rejected at the boundary rather than trusted to every future consumer). `url`/
  `caption` capped at 2000 characters each.
- `POST /scan-sessions/{id}/notes` — `{text, room_id?}` → `201` with the updated
  `FloorPlan`. Same `409`-before-capture rule as photos. `text` capped at 5000 characters.
- `GET /scan-sessions/{id}` — `200` with the stored `FloorPlan` contract (or
  `{status, floor_plan: null}` if not yet captured).
- `GET /scan-sessions/{id}/export/floorplan.png` — `200 image/png`, an indicative
  per-room floor plan sheet (each room to scale, tiled — not spatially fused, see ADR
  0002). `404` if no capture exists yet.
- `GET /scan-sessions/{id}/export/floorplan.pdf` — `200 application/pdf`, a one-page
  metrics summary (identity, honest-measurement disclaimer, per-room area/perimeter/
  confidence table). `404` if no capture exists yet.
- `GET /scan-sessions/{id}/access-log` — `200` with every access attempt (granted and
  denied) recorded for this session, itself gated by the same token.

Each `rooms[]` entry also carries a `coverage` object (`{score, confidence_counts,
usable, message}`) — see `contracts/floorplan.schema.json` for the full shape. `score`
is a 0-100 aggregate across every surface RoomPlan reported for that room's capture
call; `usable` is `score >= 70`; `message` is a rescan prompt when not usable, `null`
otherwise.

## Known limits (deliberate, not oversights)

- The access-token model is a real, narrow privacy/ACL control, not a full Vuuro
  user/org auth system — no login, no cross-org tenant isolation beyond per-session
  token possession, no token rotation/expiry, and no TLS (this runs over plain HTTP
  locally). See `../docs/adr/0003-privacy-acl-session-tokens.md` for exactly what's
  solved and what isn't, and why that's the right scope for this window.
- `photos[].url` assumes the mobile client already uploaded the image bytes somewhere
  reachable by URL — the Scan Service does not itself receive/store image bytes yet.
  Deferred deliberately; revisit once there's a real upload target to point at.
- Multi-room stitching assumes each `capture` call is exactly one room (matching a
  single guided RoomPlan session). A capture payload with multiple `floors[]` in one
  call is still supported (all its rooms get appended together), but the real capture
  flow is expected to be one room per call.
- Floor plan exports are per-room tiles, not one spatially fused building layout —
  deliberate, see `../docs/adr/0002-export-coordinate-frame.md`.
- Coverage score's 70-point usable threshold and confidence weights (high=100,
  medium=60, low=20) are this repo's own bar, not a RoomPlan-provided signal — a
  deliberate, documented choice (see the doc comment on
  `RoomPlanSimulatorAdapter::computeCoverage()`), open to revision with a better
  argument once real captures show whether 70 is calibrated right.
- No rate limiting, request-size cap, or per-capture array-count-beyond-the-adapter's-own
  sanity limits (`RoomPlanSimulatorAdapter`'s `MAX_*` constants). Session creation is
  unauthenticated by design (a session's own token is what it grants), so nothing stops
  unlimited session creation today. Found during a manual security review and
  deliberately accepted as out of scope for a local-dev-only Phase 3 slice — revisit
  before any shared or deployed environment (hard constraint #8).
