# Proposal: how the rental platform (athomevastgoed, staffhousing, vuuro) would consume Scan Service

## Status

Proposed — not accepted. This is the "you write a proposal Mark can accept or change" card
(LIDAR-9). Nothing in the rental platform (`vastgoed-app` or whatever its actual repo is
called) has been cloned, read, or edited to write this — every claim below is inferred
from the Scan Service contract this repo already owns, not from the platform codebase.
Where an answer depends on that codebase, it's listed under "Open questions" instead of
guessed.

## Why this is a proposal and not an implementation

Scan Service is API-first on purpose (root `README.md`'s roadmap: "prove capture and the
contract first, couple later on purpose"). LIDAR-9's own instructions are explicit: no
rental-app code on this card, no `website_id`/tenant-filter invention, no claim that a
floor plan is "live on three sites." This document is the join written from the Scan
Service side only, for Mark's platform team to accept, change, or defer.

## 1. Endpoints a rental-app client would call, in order

A rental-app backend acting as a Scan Service client — not the phone, not a browser —
would use this sequence for a single unit:

1. `POST /scan-sessions` — happens today from the iOS app at capture time, not from the
   rental platform. The rental platform never creates a session itself; it *receives*
   the `id` + `access_token` a capture already produced (see open question 1 below on
   how that handoff should happen).
2. `GET /scan-sessions/{id}` — fetch the current `FloorPlan` (rooms, photos, notes,
   coverage) to render or re-render a listing. Safe to poll or call on-demand; nothing
   about it is one-shot.
3. `GET /scan-sessions/{id}/export/floorplan.png` and
   `GET /scan-sessions/{id}/export/floorplan.pdf` — the pre-rendered tile image and
   metrics-table PDF, if the platform wants to embed/link these directly rather than
   composing its own layout from `FloorPlan.rooms[].outline_m`.
4. `GET /scan-sessions/{id}/access-log` — only if the platform wants to surface (or
   itself audit) who/what has touched this session's data; not required for a basic
   listing.

Every route above except session creation requires `X-Scan-Access-Token`
(`docs/adr/0003-privacy-acl-session-tokens.md`) — the rental platform's backend must
store and present that token on every call, the same as the iOS app does today. There is
deliberately no "list sessions for property X" endpoint (ADR 0003, "Consequences"): the
platform must persist `(session_id, access_token)` itself at the point a capture is
associated with one of its listings. Nothing in Scan Service can enumerate sessions for
it.

## 2. Identity fields the session already carries, and what needs mapping

`ScanIdentity` / `POST /scan-sessions` already carries `property_id`, `unit_id`,
`organisation_id`, `purpose` (listing / check_in / check_out / renovation / other),
`occupied`, `consent_obtained` — all free-text strings on the Scan Service side, opaque
to it. The rental platform is what gives those strings meaning.

What Mark's platform team needs to map, since Scan Service doesn't know or guess any of
this:

- Their own house/unit id scheme (whatever `athomevastgoed`/`staffhousing`/`vuuro`
  actually key listings by) → the `property_id`/`unit_id` values passed at capture time.
  Scan Service treats these as opaque strings today; if the platform's real ids have a
  different shape (numeric, UUID, slug), that's fine as long as whoever triggers the
  capture (currently: whoever runs the iOS app) is given the *platform's* id to type in,
  not an id invented on the scan side.
- `organisation_id` → presumably which of the three sites (or which underlying tenant/
  landlord account) owns this unit. Scan Service has no concept of "site" at all — this
  is the field that would need to carry that distinction, or a new field would need to
  be proposed if `organisation_id` isn't the right shape for it.
- Nothing here proposes adding a `website_id` field — that's explicitly out of scope for
  this card, and premature without knowing how the platform actually models "which
  site(s) does this listing appear on."

## 3. What a listing should show: per-room tiles vs. a fused plan

Today, every session's export is **per-room tiles**, never a fused building layout
(`docs/adr/0002-export-coordinate-frame.md`) — separate RoomPlan capture sessions don't
share a coordinate frame, so there is nothing honest to stitch yet.

Proposed listing behavior, both states already distinguishable from the `FloorPlan`
response alone (no new field needed):

- **Tiles-only** (today's reality): show each room's tile image individually — e.g. a
  small gallery keyed by `rooms[].label`, each with its own `floor_area_m2`/
  `perimeter_m` caption. Do **not** attempt to lay tiles out spatially relative to each
  other; that would silently claim adjacency/orientation Scan Service never captured
  (same rule ADR 0002 already enforces server-side).
- **Fused plan** (once LIDAR-4/a later fusion card ships a real shared coordinate frame):
  the platform would swap to rendering one continuous drawing instead. This is a
  rendering-mode switch on the platform's side, not a contract-breaking change — the
  proposal is that Scan Service would signal which mode applies (e.g. a
  `layout: "tiles" | "fused"` field at the FloorPlan level, not yet implemented) rather
  than the platform having to infer it from room count or geometry itself.
- Either way: every size shown must carry the same "indicative — NEN2580-inspired, not
  certified" language the iOS summary screen already shows
  (`ios-app/Sources/VuuroScanApp.swift`'s `ResultSummaryView`) — this proposal treats
  that disclosure as non-negotiable wherever the platform surfaces a measurement, not
  just in the app.

## 4. What must stay private

Hard constraint, not a suggestion: an occupied unit's interior is not "anyone with the
link." Concretely:

- The platform must never expose a Scan Service `access_token` to the browser/end user —
  all Scan Service calls should happen server-to-server, with the platform's own
  authenticated listing pages proxying/caching what they need to show publicly (room
  dimensions, the tile image) while keeping the token itself server-side only.
- `occupied: true` sessions (ADR 0003) already required consent at capture time — the
  proposal is that the platform should carry that `occupied`/`consent_obtained` state
  forward into its own access rules for who can view photos/notes from that session, not
  just room dimensions. Room size numbers are plausibly always safe to show publicly on
  a listing; interior photos of an occupied unit are the more sensitive case and
  deserve the platform's own tighter default (e.g. staff-only, or blurred, until a
  listing goes live) — this is explicitly an open question for Mark's platform team
  below, not a rule this document invents unilaterally.
- Scan Service's own audit log (`access-log`) records action/outcome/timestamp only,
  never the token or caller IP (ADR 0003) — if the platform wants stronger attribution
  (which staff member, which listing view triggered a fetch), that has to live in the
  platform's own logging, since Scan Service's token model has no per-caller identity to
  attribute to.

## 5. What to keep in the contract so a later 3D view is an add-on

Nothing in this proposal asks for 3D/mesh work now (LIDAR-11 is explicitly gated behind
fused 2D). The forward-compatible ask is narrower: whatever endpoint eventually serves a
listing's floor plan data to the platform should be additive-friendly, the same way
`contracts/floorplan.schema.json` already is (LIDAR-10 added `openings`/`height_m`/
`volume_m3_indicative`/`objects` without breaking existing consumers). Concretely: the
platform should treat unknown fields on a `FloorPlan`/`Room` response as forward-
compatible, not something to reject — that's what lets a later 3D artifact (mesh
reference, dollhouse asset URL) get added to the same contract instead of requiring a new
endpoint just for that.

## 6. Open questions only Mark's platform team can answer

1. **Handoff mechanism**: how does `(session_id, access_token)` actually reach the
   platform after an iOS capture? Options this proposal does not choose between: the
   scanning staff member pastes/scans a code into the platform manually; the iOS app
   calls a platform-side webhook directly; a shared queue/table between the two systems.
   This is entirely the platform team's call — Scan Service has no opinion and no
   existing mechanism for it today.
2. **Site membership**: how does the platform decide which of the three sites
   (athomevastgoed / staffhousing / vuuro) a given unit's listing shows on — one, some,
   or all? Scan Service has no `website_id`-shaped concept to map to until this is
   answered.
3. **Occupied-unit visibility policy**: what should actually happen on the public listing
   for an occupied unit before/after a tenant moves out — hide interior photos entirely,
   staff-only preview, or something else? Section 4 above deliberately doesn't answer
   this.
4. **Tenant/landlord id shape**: are `property_id`/`unit_id` the platform's own real
   database ids, or would the platform prefer Scan Service accept an opaque external
   reference id it doesn't otherwise interpret? Either works on the Scan Service side;
   the platform team should say which is less friction for them.
5. **Refresh cadence**: if a unit gets rescanned later (LIDAR-4's "come back a different
   day"), does the platform expect the same listing to just reflect the latest
   `GET /scan-sessions/{id}` on next fetch (no action needed — this already works), or
   does it need a push/webhook notification that a session changed? Scan Service has no
   push mechanism today; only polling is possible as things stand.

## Done when

This proposal exists in-repo (this file) for Mark to respond to. Per this card's own
"Done when": verified once Mark has actually said yes / change / defer — not simply once
this document exists.
