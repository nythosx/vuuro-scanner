# Vuuro Scan — Scan Service

Property reality capture for Vuuro: floor plans, measurements, photos and notes, bound
to Vuuro property, unit and organisation identity from day one. A branded scanning
product beside the rental platform — not a sidecar photo tool, and not the rental app
itself. The Vuuro rental codebase couples to this later, over API.

> LiDAR/RoomPlan is one capture provider, not the product — hence the repo name.
> The product is **Vuuro Scan**.

## Status

Phase 1 (proof of capture) and Phase 2 (unit story) are complete and independently
verified. Phase 3 (pilot hardening) is underway: PNG/PDF exports, a first privacy/ACL
pass, and per-room coverage/quality scoring are done; an optional laser spike is still
open. All on branch `feature/vuuro-scan` — the single working branch for this whole
build, not merged to `main` yet. See [`CLAUDE.md`](./CLAUDE.md) for the working direction,
[`PHASES.md`](./PHASES.md) for the three-phase arc, and
[`docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf`](./docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf)
for the full kickoff brief.

- [`scan-service/`](./scan-service/) — the Scan Service API (PHP + SQLite). Run it and
  its independent net locally: see `scan-service/README.md`.
- [`contracts/floorplan.schema.json`](./contracts/floorplan.schema.json) — the
  vendor-neutral `FloorPlan` contract every capture adapter converts into.
- [`docs/adr/0001-scan-service-stack.md`](./docs/adr/0001-scan-service-stack.md) — why
  this stack, and what Phase 1's fixture-based capture input does and doesn't prove
  given no Mac/Xcode access on this machine.
- [`docs/adr/0002-export-coordinate-frame.md`](./docs/adr/0002-export-coordinate-frame.md)
  — why floor plan exports are honest per-room tiles, not a spatially fused layout.
- [`docs/adr/0003-privacy-acl-session-tokens.md`](./docs/adr/0003-privacy-acl-session-tokens.md)
  — the per-session access-token/consent/audit-log model closing hard constraint #3's
  gap, and what it deliberately doesn't solve yet.
- [`ios-app/`](./ios-app/) — RoomPlan capture flow **written, not compiled or run** (no
  Mac/Xcode access on this machine); see `ios-app/README.md` for the verification
  checklist for whoever opens it in Xcode first.

## What this is

A dedicated **Scan Service**: ingest, processing, and storage for room/unit capture
sessions, exposed over an API. Mobile captures a room (guided LiDAR/RoomPlan-class flow
on capable iOS devices, with an honest fallback story for everything else) and uploads
it; the Scan Service processes it into a vendor-neutral `FloorPlan` result — 2D floor
plan, room list, indicative areas, photos, and notes — bound to property/unit/org
identity. The Vuuro rental app consumes that contract later, as an API client.

## Principles

- **Provider-neutral core.** The internal data model never knows where geometry came
  from — RoomPlan, the RoomPlan simulator, Android, a third-party SDK, are all adapters
  behind the same `FloorPlan` contract.
- **API-first.** The contract is designed as if a consumer already exists, before the
  consumer does.
- **Honest measurement.** Indicative, NEN2580-*inspired* metrics — never presented as
  certified survey output.
- **Privacy by design.** Occupied-unit consent and tenant-scoped storage are part of
  the first design, not a later cleanup.
- **Independently verified.** A verification pass that doesn't share the assumptions
  of the code it checks gates every merge.

## Development

No LiDAR-capable device is required to develop against this repo — development targets
Xcode's RoomPlan simulator, by explicit agreement with the product owner. See
`CLAUDE.md` for the full context.
