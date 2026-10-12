# 0002. Floor plan exports are per-room tiles, not a fused layout

## Status

Accepted, partially superseded — see the 2026-09-10 addendum below. The Context and
Decision sections describe the situation as it stood before multi-room fusion landed;
kept as-is for history rather than rewritten.

## Context

`FloorPlanImageRenderer` and `FloorPlanPdfRenderer` need a coordinate frame to draw
from. The capture flow today runs one RoomPlan session per room — there is no single
continuous multi-room session per unit yet (see root `README.md`'s roadmap item "Real
fused multi-room floor plan layout"). Each RoomPlan session reports geometry in its own
local coordinate space; two separate sessions have no shared origin or orientation.

## Decision

Render each room as its own accurately-scaled PNG tile — `outline_m` stays room-local —
bounded at `MAX_CANVAS_DIMENSION_PX` (4000px, `FloorPlanImageRenderer`). The PDF export
mirrors this: a per-room metrics table, bounded at `MAX_PAGES` (200,
`FloorPlanPdfRenderer`), rather than one fused floor plan drawing. Do not attempt to
spatially stitch rooms into one building layout from independent per-session geometry —
doing so without a shared coordinate frame would silently fabricate room adjacency and
orientation that was never actually captured.

## Consequences

- What's exported today is honest: a room-accurate tile per room, never a claim about
  how rooms relate to each other spatially.
- The "unit story" (multiple rooms bound to one property/unit) is a session-grouping
  and identity concept, not yet a spatial-fusion one — see `ScanIdentity`'s
  property/unit/organisation binding and the multi-room attachment net
  (`net/verify_multiroom_and_attachments.php`) for what *is* proven at that level
  today.
- Real fused multi-room layout is blocked on the capture flow moving to one continuous
  multi-room RoomPlan session per unit, which is a capture-flow change, not an export
  change. Revisit this ADR if/when that lands.

## Addendum (LIDAR-10, 2026-09-02): one floor per capture call is now enforced, not just assumed

`RoomPlanSimulatorAdapter::adapt()` already relied on "one RoomPlan session per room" per
the Context above — `computeCoverage()`'s own docblock calls this out ("accurate for the
supported one-room-per-call flow"). LIDAR-10 (doors/windows/height/objects) exposed why
that reliance needs to be an enforced input constraint, not just an assumption: RoomPlan's
`doors`/`windows`/`openings`/`objects` arrays carry no per-floor/per-room tag in this
payload shape, so a `raw_capture` reporting more than one `floors[]` entry has no honest
way to attribute an opening or object to the correct room — confirmed live pre-fix: a
2-floor capture with one door physically in floor A produced a second, phantom door entry
in floor B's `openings[]`, translated into floor B's own room-local frame and looking like
real captured data.

`RoomPlanSimulatorAdapter::validateRawCapture()` now rejects a `raw_capture` with more than
one `floors[]` entry (HTTP 422) **only when it also carries `walls`/`doors`/`windows`/
`openings`/`objects` data** — a floors-only multi-floor capture has nothing cross-floor to
misattribute (`net/verify_exports.php` legitimately submits up to 40 geometry-only floors
in one call to exercise PDF pagination and the PNG canvas-size bound; that keeps working
unchanged). This is a **hard constraint on LIDAR-4** (multi-room): multi-room sessions
carrying wall/door/window/object data must keep being built as multiple sequential
single-room `adapt()` calls (already how `roomIndexOffset`/
`ScanSessionRepository::appendCapture()` work today, per
`net/verify_multiroom_and_attachments.php`), not as one capture call carrying several floors
— unless/until a real per-floor association for doors/windows/openings/objects is designed,
at which point this rejection (and this addendum) should be revisited together
with the rest of this ADR's "one continuous multi-room RoomPlan session" scenario. Also
relevant to LIDAR-9 (rental-platform coupling proposal): the FloorPlan contract's
`openings[]`/`objects[]` per room are only meaningful under this one-floor-per-call
guarantee.

## Addendum (2026-09-10): the "one continuous multi-room RoomPlan session" scenario has landed

`MultiRoomCaptureCoordinator` now runs one continuous `ARSession` across an entire
multi-room walkthrough (`RoomCaptureView(frame:arSession:)`, Apple's documented
"bring your own ARSession" initializer) and fuses the captured rooms via
`StructureBuilder` into a shared coordinate frame — each room's `structure_origin_m`
is real, captured data, not fabricated adjacency. `POST /scan-sessions/{id}/rooms`
persists that fused result server-side, and both `FloorPlanImageRenderer` and
`FloorPlanPdfRenderer` render a real single fused layout (`renderFused()`) whenever
every room in the session carries `structure_origin_m`, falling back to the per-room
tiles this ADR originally described only when it doesn't (or when `?layout=tiles` is
explicitly requested).

What has NOT changed: a single `capture()` call still only ever adapts one room at a
time (the Addendum above, LIDAR-10, still applies), and this fused path is still only
simulator/fixture-verified — see `ios-app/README.md`'s verification status — not yet
proven against real LiDAR hardware.
