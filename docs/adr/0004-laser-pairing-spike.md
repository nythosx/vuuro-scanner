# 0004. Laser-pairing spike deferred

## Status

Deferred — not rejected. Revisit if a named pilot or Mark asks for ground-truth
measurement validation.

## Context

The brief lists an optional spike: pairing a laser measure device for ground-truth
validation against RoomPlan's indicative measurements. Root `README.md`'s "Honest
measurement" principle is explicit that this build's metrics are NEN2580-*inspired* and
indicative, never certified survey output — a laser-pairing spike would be about
building confidence in that indicative number, not replacing it with a certified one.

## Decision

Defer the spike for this build's window. Reasons:
1. It's explicitly optional in the brief, not a hard constraint.
2. Everything else in the FIRST/THEN/AFTER-THAT movements (capture, unit story,
   pilot hardening: exports, ACL, coverage/quality scoring, enterprise hardening) is a
   harder, non-optional dependency for a usable pilot, and none of it needs laser data
   to be built or verified.
3. No pilot or named use case has asked for ground-truth measurement validation yet —
   building this ahead of that request risks solving a problem nobody has confirmed
   they have.
4. No Mac/Xcode/device access for most of this build's window (`docs/adr/0001`) means
   even the RoomPlan side of a pairing integration couldn't be built past a sketch
   without hardware anyway.

## Integration sketch, if a pilot ever asks for it

Not implemented — this is a starting point, not a design commitment:

- A laser measure device that exposes readings over Bluetooth LE (most consumer laser
  distance meters with an app companion do) would need its own adapter, parallel to
  `RoomPlanSimulatorAdapter`, converting its raw readings into a small
  `LaserReferenceMeasurement` shape (e.g. one wall-to-wall distance + a room/wall
  identifier) rather than a full geometry replacement.
- Pairing would most naturally happen as an optional attachment to an existing scan
  session (similar in shape to a photo/note attachment — see `ScanSessionRepository`'s
  capture/photo/note append methods) rather than a new top-level resource: one or more
  reference measurements attached to a session, compared against the corresponding
  RoomPlan-derived dimension for that wall.
- The comparison itself (RoomPlan-derived vs. laser-reference, with a delta) would be a
  new, separate computation — deliberately not folded into `RoomPlanSimulatorAdapter`'s
  existing geometry math, so a discrepancy is surfaced as a data point, not silently
  averaged into the reported number. This keeps the "honest measurement" principle
  intact if a laser reading itself is ever wrong or misapplied.
- None of this needs a schema migration beyond adding one new table for reference
  measurements — no change to `floor_plans`, `sessions`, or the existing contract in
  `contracts/floorplan.schema.json` is implied by this sketch.

## Consequences

No laser-pairing capability exists today. Nothing in the current build assumes it will
exist later — the `FloorPlan` contract and adapter boundary are already positioned so
that adding it later is additive, not a rework, should the sketch above prove out.
