# ADR 0002 — Floor plan exports are per-room tiles, not a spatially stitched building layout

Status: decided, for as long as multi-room sessions are built the way ADR 0001 and the
current Scan Service build them (one `POST /scan-sessions/{id}/capture` call per room).

## Context

PHASES.md Phase 3 wants "PDF/PNG exports" of "the floor plan and metrics." The natural
reading of "floor plan" is a single drawing showing every room laid out relative to each
other, the way a real architectural floor plan does.

That is not what this repo can honestly produce yet, and the reason is architectural,
not a missing feature: a multi-room session here (`ScanSessionRepository::appendCapture`)
is built from **separate RoomPlan capture sessions**, one per room, stitched together
only at the metrics/JSON level (`rooms[]` in one `FloorPlan`). Each RoomPlan
`RoomCaptureSession` tracks its own ARKit world coordinate frame from when it starts.
Two separate sessions — even two rooms in the same unit, scanned minutes apart — have no
shared origin or orientation. There is no honest way to place room 2's outline next to
room 1's outline on one canvas and claim the result reflects their real spatial
relationship, because nothing in the data says what that relationship is.

(The one case where a true shared-frame layout *would* be honest — one continuous
RoomPlan session that walks through multiple rooms without stopping, which RoomPlan
does support — is not how this repo's multi-room flow works today. If that changes,
this ADR's constraint changes with it — see Follow-up.)

## Decision

`rooms[].outline_m` (added alongside this ADR) is **room-local only**: each room's
polygon is translated so its own bounding box starts at (0,0). It is explicit in the
contract schema and in code comments that two rooms' `outline_m` values must never be
assumed to share an origin.

Floor plan PNG export therefore renders each room as its own accurately-scaled tile
(correct shape, correct relative proportions *within* that room), arranged left-to-right
on one sheet with its label, area, and confidence — not fused into one building outline.
This is "an indicative per-room floor plan sheet," not "the floor plan of the unit," and
is labeled that way in the export itself and in `scan-service/README.md`, per hard
constraint #2's spirit (honest labeling isn't only about NEN2580 certification language
— it's about not implying spatial precision that was never captured).

PDF export is a metrics table (per-room area/perimeter/confidence, disclaimers, identity)
and does not attempt a spatial layout at all — it doesn't need to make this claim in the
first place.

## Why this is still worth shipping now, not blocked

- It's real, usable value: a landlord gets an accurate per-room shape and honest metrics
  today, which is strictly better than the guessed/vague square-metre problem the brief
  names as the reason this product exists.
- It doesn't foreclose a real fused floor plan later. `outline_m` staying room-local is
  the honest data to have either way — a future world-locked continuous capture flow
  would still produce room-local outlines per room, just with an additional shared
  transform on top, which can be added without reshaping this field.

## Follow-up (not blocking, tracked for whenever it's worth revisiting)

If/when the iOS capture flow moves to one continuous multi-room RoomPlan session per
unit (rather than one session per room), revisit this ADR: that flow could carry a real
shared coordinate frame, and `outline_m` could gain an optional room-to-unit transform
so exports can honestly fuse rooms into one spatial layout. Don't backfill that
transform speculatively before the capture flow that could produce it honestly exists.
