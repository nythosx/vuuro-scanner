# Scan Service

Phase 1 ("proof of capture") implementation. See `../PHASES.md` and `../CLAUDE.md`
for the product context — this file is just how to run and verify what's here.

## What's here

- `public/index.php` — HTTP API (front controller, no framework).
- `src/Adapters/RoomPlanSimulatorAdapter.php` — converts a RoomPlan-shaped capture
  payload into the vendor-neutral `FloorPlan` contract (`../contracts/floorplan.schema.json`).
  This is the only place that knows RoomPlan vocabulary.
- `src/ScanSessionRepository.php`, `src/Storage/Database.php` — PDO/SQLite storage.
- `fixtures/` — hand-built, RoomPlan-CapturedRoom-shaped capture payloads. **Not** real
  RoomPlan or RoomPlan-simulator output — no Mac/Xcode was reachable to produce that on
  this machine. See `../docs/adr/0001-scan-service-stack.md` for what that does and
  does not prove, and what to do once real device/simulator access exists.
- `tests/adapter_test.php` — fast in-process regression + adjacent-case tests against
  the adapter directly.
- `net/verify_phase1.php` — the independent net (CLAUDE.md hard constraint #6). Talks to
  the live HTTP API only, re-derives expected geometry with its own separately-written
  math, and never imports the adapter. This is the merge gate, not the unit tests above.

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
```

Both must print `VERDICT: GREEN` (exit code 0) before merging, per CLAUDE.md: "nothing
merges past a red verdict."

## Run it (Docker, host-independent)

```
docker build -t vuuro-scan-service .
docker run --rm -p 8089:8089 vuuro-scan-service
```

Then run `net/verify_phase1.php http://127.0.0.1:8089` from the host against the
container the same way as above.

## API (Phase 1 shape)

- `POST /scan-sessions` — `{property_id, unit_id, organisation_id, purpose}` → `201`
  with the created session. Any missing identity field is rejected with `422`
  (hard constraint #1: no orphan captures, enforced at creation, not by convention).
- `POST /scan-sessions/{id}/capture` — `{raw_capture: <RoomPlan-shaped JSON>}` → `200`
  with the resulting `FloorPlan` contract.
- `GET /scan-sessions/{id}` — `200` with the stored `FloorPlan` contract (or
  `{status, floor_plan: null}` if not yet captured).

## Known Phase 1 limits (deliberate, not oversights)

- Single room per session only. Multi-room stitching is Phase 2.
- No auth on the API yet — Phase 1 proves the contract locally; auth shape is an open
  decision (CLAUDE.md) to make before any shared/deployed environment, not before local
  proof.
- `photos` and `notes` are present in every `FloorPlan` response but always empty —
  the contract carries the field now so Phase 2 doesn't change response shape, only
  content.
