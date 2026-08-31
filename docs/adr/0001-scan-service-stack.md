# 0001. Scan Service stack, and what fixture-based capture input proves

## Status

Accepted.

## Context

The brief calls for a dedicated Scan Service: ingest, processing, and storage for
room/unit capture sessions, exposed over an API, provider-neutral from day one (see
root `README.md`'s "Principles"). Building it requires two choices made together: what
the backend runs on, and — since this repo was built with no Mac/Xcode/LiDAR device
reachable on the dev machine — what stands in for a real RoomPlan capture during the
FIRST movement (proof of capture).

## Decision

**Backend stack**: plain PHP 8.1+ (`declare(strict_types=1)` throughout), PDO/SQLite,
no framework, no Composer dependency (a hand-rolled `autoload.php`). `public/index.php`
is a single-file router matching `$method`/`preg_match($path)` per route. All SQLite
access goes through one class, `ScanSessionRepository`, specifically so a later swap to
MySQL/Postgres is a storage-layer change, not a rewrite. Chosen for zero external
dependency risk and because the brief's actual hard constraint is the independent net
(see ADR-0003's sibling constraint, and root `README.md`'s "Independently verified"),
not a particular backend technology.

**Capture input for the FIRST movement**: hand-built, RoomPlan-shaped JSON fixtures
(`scan-service/fixtures/`) mirroring Apple's real `CapturedRoom` export format —
`floors[].polygonCorners`, `walls[]`, `doors[]`, `windows[]`, per-surface `confidence`
— covering a single room, an L-shaped room, and degenerate/low-confidence adversarial
cases. `RoomPlanSimulatorAdapter` converts this into the vendor-neutral `FloorPlan`
contract. This is this repo's own decision, made necessary by zero Mac/Xcode
reachability on the dev machine — **not** something the direction brief signs off on;
see root `README.md`'s development-section correction (2026-08-27) for that exact
distinction. The word "simulator" does not appear in the brief; it only ever describes
capture on "a capable device."

## Consequences

- Provider-neutral core holds: RoomPlan, the RoomPlan simulator, Android, or a
  third-party SDK are all meant to be adapters behind the same `FloorPlan` contract,
  never special-cased in the core (`RoomPlanSimulatorAdapter`'s own header makes this
  explicit).
- What fixture-based input **proves**: the contract, the adapter's geometry math
  (shoelace-formula area/perimeter, independently re-implemented in
  `net/verify_capture_geometry.php` so the net never shares a bug with the code it
  checks), the full session lifecycle, and the export pipeline — all exercised with
  input shaped exactly like a real `CapturedRoom` export.
- What it does **not** prove: anything about real RoomPlan/ARKit behavior, real LiDAR
  noise/confidence characteristics, or real-device performance. That gap closes only
  when the app is opened in Xcode and run against real hardware — see
  `ios-app/README.md`'s checklist.
- Later, CI (`.github/workflows/ios-build.yml`) and appetize.io's cloud iOS Simulator
  closed part of this gap for the iOS client specifically (compiled + simulator-run,
  not fixture-only) — still not a real-device/real-LiDAR run. See `ios-app/README.md`'s
  verification-status section for the current line between what's proven and what
  isn't.
