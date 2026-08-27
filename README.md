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
pass, and per-room coverage/quality scoring are done; an optional laser spike is
deferred with a written rationale (`docs/adr/0004-laser-pairing-spike.md`). On top of
that, an enterprise-hardening pass adds access-token expiry/rotation, per-caller-IP and
per-session rate limiting, idempotent capture retries, a request body size cap, and a
`GET /health` endpoint — see `scan-service/README.md`'s "Known limits" for exactly what
each does and doesn't solve.

**This branch, `feature/vuuro-scan-design`, is a pick-one variant of `feature/vuuro-scan`:**
`ios-app/` here is restyled to vuuro.com's actual brand (colors/fonts/buttons pulled from
the live site's own computed CSS, not guessed) — everything else (Scan Service,
contracts, docs) is identical between the two branches. Check out this branch to use the
branded UI, or `feature/vuuro-scan` for the plain, brief-exact UI — pick one, they're not
meant to be merged together. Neither is merged to `main` yet. See
[`docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf`](./docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf)
for the full kickoff brief — the only source of truth for direction on this build.

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
- [`docs/adr/0004-laser-pairing-spike.md`](./docs/adr/0004-laser-pairing-spike.md) — why
  Phase 3's optional laser-pairing spike is deferred for now, and the integration sketch
  to start from if a pilot ever asks for it.
- [`ios-app/`](./ios-app/) — RoomPlan capture flow, **restyled to vuuro.com's actual
  brand** on this branch (see `Sources/Design/VuuroDesign.swift`), and
  **CI-compiled and simulator-tested, not yet run on a real device** (no Mac/Xcode
  access on this machine, but GitHub Actions builds it for the iOS Simulator and it's
  been live-tested end to end on appetize.io using DEBUG-only fake-LiDAR/tunnel
  tooling); see `ios-app/README.md` for exactly what's verified vs. still open, and the
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
Xcode's RoomPlan simulator, by explicit agreement with the product owner (see the
direction brief linked above).
