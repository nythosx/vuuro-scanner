# Vuuro Scan — Scan Service

Property reality capture for Vuuro: floor plans, measurements, photos and notes, bound
to Vuuro property, unit and organisation identity from day one. A branded scanning
product beside the rental platform — not a sidecar photo tool, and not the rental app
itself. The Vuuro rental codebase couples to this later, over API.

> LiDAR/RoomPlan is one capture provider, not the product — hence the repo name.
> The product is **Vuuro Scan**.

## Status

Kickoff. See [`CLAUDE.md`](./CLAUDE.md) for the working direction and
[`docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf`](./docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf)
for the full kickoff brief.

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
