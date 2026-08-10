# Vuuro Scan — Phases

Three movements from the kickoff brief (`docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf`,
section 6, "The arc ahead"). **These are movements, not a schedule** — pace and order
inside each one are mine to set. Nothing here is a fixed deadline; it's the shape of
what "done" looks like at each stage, so progress can be reported against something
concrete in the three-bucket daily format (verified / implemented-not-verified /
at risk).

## Phase 1 — Proof of capture

One room scanned on a capable device (Xcode's RoomPlan simulator is explicitly
sanctioned for this — see `CLAUDE.md`), uploaded to the Scan Service, bound to
property/unit/org IDs, with basic dimensions readable end to end through the API
contract.

**Done means:**
- A scan session always carries property, unit, and organisation identifiers — no
  orphan captures, by construction, not by convention (hard constraint #1).
- The Scan Service ingests one room's capture and returns a result shaped by our own
  vendor-neutral `FloorPlan` contract, not a RoomPlan-specific payload.
- Basic dimensions for that one room are readable back out through the API, end to end.
- The independent net (see below) has a check for this slice that doesn't share the
  Scan Service's own assumptions.

## Phase 2 — Unit story

Multi-room session, backend floor plan plus indicative areas, photos and notes, as a
coherent unit package served by the Scan Service API.

**Done means:**
- A full unit (multiple rooms) is captured in one session and stitched into a single
  floor plan result, not per-room fragments.
- Indicative areas are computed and labeled honestly (NEN2580-*inspired*, never
  presented as certified — hard constraint #2).
- Photos and notes attach to the same unit package, not a separate side-channel.
- The whole unit result is retrievable as one coherent API response.

## Phase 3 — Pilot hardening

Coverage/quality cues, PDF/PNG exports, privacy/ACL polish, optional laser spike,
inspection purpose tags. Ready for a small landlord pilot once Vuuro API coupling is
live.

**Done means:**
- Capture quality/coverage feedback exists (so a landlord knows a scan is usable before
  they walk away from the unit).
- PDF/PNG export of the floor plan and metrics — export priority is image/PDF before
  any exotic CAD format (decided, not open).
- Privacy/ACL is real: occupied-unit consent, tenant-scoped storage, audited access, no
  "anyone with the link" defaults (hard constraint #3) — polished, not newly introduced
  here; it should already exist from Phase 1.
- Purpose tags (listing / check-in / check-out / renovation) are first-class, not
  afterthought metadata.
- Optional: a laser-pairing spike, if it earns its place.
- Pilot-ready is gated on Vuuro API coupling being live — this phase does not itself
  require an App Store or production deploy (hard constraint #8); local + CI + the
  independent net proving each slice is enough until that's a deliberate decision.

## Not a phase — always on

Two things from the brief apply across all three phases, not as a phase of their own:

- **The net.** An independent verification pass, built from different assumptions than
  the Scan Service code it checks, gates every merge from Phase 1 onward. Build it
  early — it's the direct carry-forward of the code-quality-agent lesson, and Mark
  named it the special condition for this whole workstream.
- **API-first contract discipline.** The Vuuro rental app is not a client yet, but every
  phase is built as if it already were. Coupling is a later, deliberate step through
  the contract — not a reason to skip designing the contract properly now.
