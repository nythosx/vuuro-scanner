# Proposal: real multi-room fusion (LIDAR-5 / LIDAR-11)

Research + design only — no capture-flow code changed by this doc. Written before touching
`CaptureCoordinator`/`RoomCaptureScreen` because the real architecture required is bigger
than either card's own description states, and one finding below changes what LIDAR-4
("resume a session to add a room") can honestly promise going forward.

## What's blocking LIDAR-5 (fused 2D) and LIDAR-11 (3D dollhouse) today

Confirmed in code, not assumed: `RoomCaptureScreen.makeUIView` creates a plain
`RoomCaptureView(frame: .zero)`, which owns and creates its own internal `ARSession`
(`CaptureCoordinator.swift`'s own comment already flags "Multi-room stitching (Phase 2)
needs a real look... once Xcode access exists — not assumed here"). Every time this screen
is presented — including LIDAR-4's "resume a past session to scan another room" — it's a
fresh `RoomCaptureView` instance, so a fresh `ARSession`, so no shared world-tracking origin
between rooms. `docs/adr/0002` already documents the consequence: every room's `outline_m`
is room-local with no shared frame, so exports are per-room tiles, never a fused layout.

## What Apple actually provides (researched, not assumed)

Apple's RoomPlan has a real merge API for exactly this — [`StructureBuilder`](https://developer.apple.com/documentation/roomplan/structurebuilder)
/ [`capturedStructure(from:)`](https://developer.apple.com/documentation/roomplan/structurebuilder/capturedstructure(from:)),
introduced at WWDC23 ([Explore enhancements to RoomPlan](https://developer.apple.com/videos/play/wwdc2023/10192/)).
Pattern: run `RoomBuilder` per room as today to get each `CapturedRoom`, then hand the
array of `CapturedRoom` results to `StructureBuilder().capturedStructure(from:)` to get one
merged `CapturedStructure` — but **only if every room in that array was captured under one
continuous, unbroken `ARSession`.**

That "continuous session" requirement is not a minor detail — a developer on Apple's own
forums ([thread 733945](https://developer.apple.com/forums/thread/733945)) hit exactly the
bug this doc is trying to prevent us from also hitting: their rooms merged stacked on top of
each other instead of positioned correctly, because their "next room" button dismissed and
recreated the view controller — a new `RoomCaptureView`, and therefore a new `ARSession`,
between rooms. Their fix: own the `ARSession` explicitly, construct
`RoomCaptureView(frame:arSession:)` with it once, and reuse that same view/session instance
across every room in the walkthrough — `roomCaptureView?.captureSession.stop(pauseARSession: false)`
between rooms so tracking never resets, only truly stopping (and pausing the ARSession) once
the whole unit is finished.

**This is precisely the bug our current `RoomCaptureScreen` would hit if wired to LIDAR-4's
resume flow as-is** — LIDAR-4 re-presents a brand new `RoomCaptureScreen` (new `RoomCaptureView`,
new `ARSession`) every time, whether that's the same continuous visit or a resume from
History days later. Passing those `CapturedRoom` results into `StructureBuilder` today would
produce exactly the misaligned/stacked output that forum thread describes — worse than
today's honest per-room tiles, because it would *look* like a real fused layout while being
wrong.

**Correcting that mechanically is necessary but not sufficient — a second, independently
confirmed report shows the same "own the ARSession, reuse it" fix can still misalign.** A
Feb 2025 Apple Developer Forums thread ([763244](https://developer.apple.com/forums/thread/763244))
describes exactly the correct setup above — same `ARSession` instance passed into
`RoomCaptureView`, `stop(pauseARSession: false)` between rooms, never recreated — and the
world origin still silently shifts to wherever the next room's `RoomCaptureSession.run()`
starts. No Apple staff response in that thread; it's an open, unresolved report as of this
writing. This means "reuse the ARSession" is the documented correct approach, but not a
guaranteed fix — this needs to be treated as a real risk to validate on Mark's device early,
not assumed solved once the plumbing is right.

## The real constraint LIDAR-4 needs to inherit: fusion needs one continuous visit (more precisely than "relocalization is unreliable")

Apple documents two ways rooms can share a coordinate frame: a continuous `ARSession`, or
**ARSession relocalization** (saving an `ARWorldMap` from the end of one session and loading
it back to resume tracking in the same space later). Checked the actual constraint here
directly rather than relying on general "unreliable" reports: a DTS engineer's answer in
[thread 744206](https://developer.apple.com/forums/thread/744206) states an `ARWorldMap`
stores features from the *entire* prior session run, and relocalization can succeed from
anywhere previously visited — not just the exact exit point. The real, sharper limit: **you
cannot successfully relocalize into an area the first session never physically visited.**
The DTS engineer's direct example: skip the bedroom on visit one, and visit two cannot scan
just the bedroom and merge it in — ARKit has nothing from that room to match against. That's
a narrower, more defensible constraint than a blanket "unreliable, avoid it," and it
directly describes LIDAR-4's actual use case (adding a room to a unit already partly
visited) more precisely than my first pass gave it credit for.

Two more concrete, Apple-unresolved risks that apply even to the in-scope same-visit case,
and need to be designed around rather than discovered mid-implementation:
- **Attached data (photos/notes/object anchors) is not auto-transformed after a merge.**
  [Thread 760952](https://developer.apple.com/forums/thread/760952): when
  `StructureBuilder().capturedStructure(from:)` repositions an earlier room into the merged
  structure's shared frame, any point-of-interest data tied to that room (the reporter's
  case: camera-origin-relative points) is *not* moved along with it — the reporter's own
  attempt to reapply the room's transform manually was confirmed insufficient in the thread,
  and no Apple fix exists. Direct implication for us: LIDAR-6's photo/note attachment
  (currently room-local) would need its own, separately-verified position-remapping step
  after any structure merge — not a "should just work" side effect of adopting
  `StructureBuilder`.
- **An undocumented room-count ceiling exists.** [`CaptureError.exceedSceneSizeLimit`](https://developer.apple.com/documentation/roomplan/roomcapturesession/captureerror/exceedscenesizelimit)
  is a real, documented enum case; forum reports ([744976](https://developer.apple.com/forums/thread/744976),
  [804371](https://developer.apple.com/forums/thread/804371), [775945](https://developer.apple.com/forums/thread/775945))
  converge on roughly 10-11 rooms in one continuous multi-room capture triggering it
  (`ARWorldMap` reportedly growing to ~58MB at that point, iPhone-specific — iPad reportedly
  grows slower), with no official documented numeric limit and long-unanswered reports.
  Needs a defensive cap or warning in the walkthrough UI once this is built, not left to
  surface as a raw crash mid-scan.

Conclusion: **true fusion (LIDAR-5/11) should be scoped to rooms captured in one continuous,
same-visit walkthrough only** — but the reasoning is now sharper than "relocalization is
unreliable": we don't own a persisted `ARSession`/`ARWorldMap` across app launches at all
today, and even Apple's own same-visit merge path has two open, Apple-unresolved gaps (POI
transform, scene-size ceiling) plus a reported world-origin-shift bug that the "correct"
fix doesn't fully close. LIDAR-4's resume-from-History flow stays exactly what it is today —
a way to add another independently-tiled room to the same unit later — and should **not** be
extended to claim fused coordinates for those later-added rooms, consistent with ADR-0002's
"never fabricate room adjacency/orientation that was never actually captured."

## Proposed shape (not yet built)

1. **A continuous multi-room capture flow, separate from single-room capture and from
   LIDAR-4's resume-a-past-session flow.** One `CaptureCoordinator` instance owns one
   explicit `ARSession` (not the view's default) and one `RoomCaptureView(frame:arSession:)`
   for the whole walkthrough. "Add another room" calls `captureSession.stop(pauseARSession: false)`
   then re-runs the session for the next room — the screen itself stays presented across
   rooms; it is never dismissed and re-presented mid-walkthrough (that dismiss/recreate step
   is exactly what broke the forum example above).
2. `CaptureCoordinator` accumulates `[CapturedRoom]` across the walkthrough instead of one
   `capturedRoom`. Only when the user says "Done with this unit" does it call
   `StructureBuilder().capturedStructure(from:)` once, over the full array.
3. **New export shape needed**: today's `FloorPlanExporter`/`CapturedRoomExporter` maps one
   `CapturedRoom` at a time. A `CapturedStructure` carries its own merged geometry — the
   export/adapter boundary needs a second, additive path for structure-level export (fused
   `outline_m` per room but in one shared frame) without breaking today's per-room contract
   that photos/notes/history/LIDAR-6 all depend on.
4. **Schema**: additive only, same convention as LIDAR-10 — a per-room `origin_m: [x, z]`
   (this room's placement within the unit's shared frame) alongside the existing room-local
   `outline_m`, so today's consumers (PNG/PDF renderers, History) keep working unchanged
   until they're deliberately updated to draw the fused view.
5. **LIDAR-4 stays as-is** for the separate-visit case; its resume flow is not wired into
   this new continuous flow. A unit can have both: some rooms fused (captured together in
   one walkthrough) and some tiled (added later via resume) — the UI needs to be honest
   about which rooms in a unit got which treatment, not present a false single fused map.
6. **Photo/note position remapping after merge** needs to be its own explicit, separately-
   verified step (see the POI-transform gap above) — not assumed to fall out of adopting
   `StructureBuilder` for free.
7. **A defensive room-count warning/cap** in the walkthrough UI (see the scene-size-limit
   risk above), so hitting that ceiling mid-scan is a handled state, not a crash.

## Explicitly unverified without hardware

Everything above is built against Apple's own documented API surface and multiple
independent real-world practitioner reports (including two open, Apple-unresolved forum
threads — world-origin shift on room 2+, POI transform not carrying through a merge), not
guessed — but none of it has run against the real SDK on a device, and Apple itself has not
resolved either of those two reports as of this writing. Specific unknowns flagged rather
than assumed away:
- Exact `RoomCaptureView(frame:arSession:)` initializer signature and whether it's
  available/stable on the RoomPlan version this project targets.
- Whether the world-origin-shift bug (thread 763244) reproduces on Mark's device/iOS
  version at all — it may be device- or iOS-version-specific and could already be fixed
  silently since that Feb 2025 report.
- Real accuracy of `StructureBuilder`'s merge on an actual multi-room walk beyond "it ran
  without crashing."
- Whether `CapturedStructure`'s own model exposes per-room `origin_m`-equivalent data
  directly, or whether that needs to be derived from each room's transform ourselves.
- The actual room-count ceiling on Mark's specific device (iPhone vs. iPad reportedly
  differ significantly per the forum reports).

Same standing rule as the rest of this repo's iOS work: written to the best-known public
API shape, real verification happens on Mark's device, not assumed here. Given the
world-origin-shift report has no confirmed fix, the very first same-visit two-room test
should specifically check room 2's position relative to room 1, not just that both rooms
individually captured cleanly.

## Open questions for Mark

1. Does "multi-room" for LIDAR-5/11 mean one continuous in-person walkthrough only (per
   this doc's scoping), or is a rooms-added-over-multiple-visits fused view still wanted —
   which would mean accepting ARSession relocalization's known reliability problems, or
   waiting for a better Apple API?
2. Is a unit allowed to mix fused rooms (one walkthrough) and tiled rooms (added later via
   LIDAR-4) — with the UI clearly distinguishing them — or should that mixed state be
   blocked/discouraged?
3. Priority: is this worth starting now, or does it wait until LIDAR-2 (Mark's own
   single-room device proof) and the current backlog are further along, given this is a
   genuinely larger, riskier piece of work than any card shipped so far?
