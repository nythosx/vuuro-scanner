# 0002. Floor plan exports are per-room tiles, not a fused layout

## Status

Accepted.

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
