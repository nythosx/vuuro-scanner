# Vuuro Scan — Scan Service

## What this is

Vuuro Scan is a branded property reality-capture product: floor plans, measurements,
photos and notes, bound to Vuuro property/unit/organisation identity from day one. It
is a product in its own right — not a sidecar photo tool, not a plumbing job for the
rental app. Full context: `docs/VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf`
(Mark's kickoff brief, 6 Aug 2026 — read it before doing anything else if this is a
fresh session). See `PHASES.md` for the three-phase arc (proof of capture / unit story
/ pilot hardening) with a concrete "done means" per phase. This file is a working
distillation of that brief plus the direction already agreed with Mark before his
low-availability window started. **There is no second document drop this window** —
the brief plus this file plus repo access is the
complete kickoff package. If something is missing, decide with a short rationale, keep
moving, and surface it in the daily update. Do not wait on more material.

## Who's involved

- **Joven (me/the agent operating this repo)** — owns this track. Ownership role, not a
  ticket queue: open decisions are mine to take with a short written rationale, defaults
  can be challenged with a better argument, hard constraints cannot be silently stepped
  over.
- **Mark Oosterom** — is less available for ~3 weeks starting the week of 10 Aug 2026.
  Needs to be able to assume the net holds without checking in. Reachable for real
  blockers same day (tag him or Moustafa), not for routine decisions.

## Before writing any product code: the open bar question

Mark's brief ends with: *"Take it and make it yours - after you answer the open bar
question from my last message."* That question (from an earlier message, on the
code-quality-agent track, not yet answered as of this repo's creation):

> Put yourself in my position: what would you need to see from an engineer before you
> trusted them with a solo greenfield window like this? Build the bar yourself, then
> tell me honestly where you stand against it today — including the gap, if there is
> one. If the stack is new to you, say that plainly.

This is a real gate, not rhetorical — answer it (in the team channel, or wherever Mark's
updates go) early, honestly, including where the LiDAR/RoomPlan/ARKit/iOS stack is new
territory. Don't let it block starting the Scan Service contract work below, but don't
skip it either.

## North star

Own property reality capture for Vuuro. Scan once on site; the listing, the inspection
record, and the renovation baseline all eventually drink from the same capture.
Indicative Dutch residential metrics with honest labeling (NEN2580-*inspired*, never
presented as certified). A clear reason landlords prefer listing and operating on
Vuuro, not just another photo tool.

- **Geometry** — floor plans and measurements that belong to the unit
- **API-ready** — Scan Service contract first; the Vuuro rental app wires in later
- **Honest m²** — indicative metrics, never fake certification
- **Ops memory** — check-in, check-out, renovation baselines are first-class capture
  purposes, not afterthought tags

## Hard constraints (non-negotiable — everything else is mine to shape)

1. **Identity-native captures.** Every scan session carries property, unit, and
   organisation identifiers in the data model and API. An orphan capture is a bug.
2. **Honest measurement language.** Never present mobile LiDAR/RoomPlan output as
   certified NEN2580 unless a certified/QC path actually ran. Disclaimers are product,
   not polish — label the difference in UI and exports.
3. **Privacy by design.** Consent for occupied units, tenant-scoped storage, audited
   access. No "anyone with the link" defaults for interior geometry, ever.
4. **API-first Vuuro coupling.** Design Scan Service results so the Vuuro rental
   codebase can consume them over API *later*. Deep edits inside the rental app are not
   a prerequisite for proving capture. When coupling happens, it happens through the
   contract, not ad hoc.
5. **Device honesty.** Detect LiDAR/RoomPlan capability. Unsupported devices get a
   clear message and a designed fallback path — never a crash, never a silent empty
   feature.
6. **Own the net under the work.** Not "be more careful." A real independent check that
   runs without Mark, built from *different assumptions* than the code it guards, and
   whose verdict cannot be merged past. See "The net" below — this is the direct carry-
   forward of the code-quality-agent lesson, and Mark is explicit that this is the
   measured gap this workstream exists to close.
7. **Evidence over theatre.** Daily updates in the channel, three buckets: **verified
   working** / **implemented but not yet verified** / **at risk**. Not a polished status
   story — the split is the point, it's how Mark stays light-touch without losing the
   truth.
8. **No silent production leap.** Local + CI (+ the independent net) prove each slice
   before App Store or production deploy. Store launch is earned, not assumed in week
   one. No App Store or production server deploy is required to get going at all —
   local proof plus a clean Scan Service API is enough for the first arc.

## The net — carrying the code-quality-agent lesson forward

This is not optional polish, it's a named hard constraint (#6 above). The lesson from
the code-quality-agent track: a test suite that only checks what you were thinking
about when you wrote the fix will not catch the adjacent case the fix itself breaks —
"the reported case closes, the case beside it opens" was the exact recurring failure
shape found by independent review there, repeatedly, including in the fixes for the
fixes. Concretely here, that means:

- Build an independent verification pass (same spirit as the T1 code-quality agent,
  pointed at *this* product) that does not share the assumptions of the Scan Service
  code it's checking — e.g. it re-derives expected room dimensions/areas from a known
  fixture independently rather than re-running the same reconstruction path and
  comparing to itself.
- Every fix or new capability needs a regression test for the reported case **and** a
  deliberately adversarial test for the adjacent case the fix didn't explicitly target
  — construct it and run it before calling something done, not after someone else
  finds it.
- A test that locks in the wrong answer (asserts a false positive/negative as required
  behaviour) is worse than no test — don't write those; if a known limitation is being
  accepted rather than fixed, document the tradeoff in a comment, don't pin it as a
  requirement that blocks a future real fix.
- This net is a real merge gate — nothing merges past a red verdict, including my own
  work. MRs are not ceremony here.

## Technical direction already agreed with Mark

From the last exchange before this brief landed (Mark: *"Good. Go ahead... Keep going
that way."*):

- **The scanner is a pluggable provider, not the core of the system.** The internal
  data model is vendor-neutral. Adapters exist for Apple RoomPlan, the RoomPlan
  simulator, Android later, and third-party SDKs if that door opens. The backend only
  ever knows about our own `FloorPlan` contract — never where the geometry came from.
- **No LiDAR-capable device is available and none will be purchased for this window.**
  Development proceeds against **Xcode's RoomPlan simulator**. Mark has explicitly
  signed off on this: *"the simulator carries the contract and the pipeline, so you are
  not blocked now. For this window, treat end-to-end simulator proof (capture in,
  FloorPlan out, property/unit/org IDs bound) as valid for the first arc."* Do not
  treat lack of hardware as a blocker — it isn't one, by direct agreement. If real-
  device validation becomes necessary later, raise it as a deliberate decision, not a
  silent gap.
- **iOS first; RoomPlan-class room capture is the MVP spine** (decided, see below).

## Decided vs. open vs. out of scope

**Decided (settled — don't relitigate without a strong new finding):**
- iOS first; RoomPlan-class room capture is the MVP spine.
- A dedicated Scan Service (bounded context) handles ingest/processing/storage and
  exposes results over API. This is a separate service, not a module bolted onto the
  rental app.
- Vuuro rental-app coupling is later and API-based. This window proves capture and the
  contract; it does not require rental-codebase surgery.
- Listing enrichment and property identity are the first business value — not CAD
  parity.
- Export priority for early value: floor plan image/PDF and metrics through the Scan
  Service API, before exotic CAD formats.
- No further written packs from Mark during his low-availability window.

**Open, defaults set (mine to challenge with a better argument, not vibes):**
- RoomPlan-only stitching vs. early custom ARKit mesh for multi-room.
- How much preview runs on-device vs. authoritative metrics computed on the backend.
- Pure Apple stack vs. a specialised reconstruction/export SDK.
- Build-only vs. partner/white-label hybrid later.
- Exact libraries, repo layout, auth shape of the Scan Service API, and the thin demo
  consumer used until Vuuro actually couples.

**Out of scope this arc:**
- Official certified NEN2580 as a product.
- Android parity, Matterport-class marketing tours.
- The code-quality-agent (T1) track — now a side track, background only, unless Mark
  explicitly pulls me back to it. See "Sibling project" below for its one open item.

## The arc (three movements, not a schedule — pace and order inside them are mine)

1. **Proof of capture** — one room scanned on a capable device (or simulator, per the
   sign-off above), uploaded to the Scan Service, bound to property/unit/org IDs, basic
   dimensions readable end to end through the API contract.
2. **Unit story** — multi-room session, backend floor plan plus indicative areas,
   photos and notes, served as a coherent unit package by the Scan Service API.
3. **Pilot hardening** — coverage/quality cues, PDF/PNG exports, privacy/ACL polish,
   optional laser spike, inspection purpose tags. Ready for a small landlord pilot once
   Vuuro API coupling is live.

## Working rhythm while Mark is less available

- Short start-of-day note: what I'm picking up.
- End-of-day update in the three buckets above (verified / implemented-not-verified /
  at risk).
- Real blockers flagged the same day they're hit — tag Mark or Moustafa.
- Code pushed to GitLab daily on this repo.
- MRs gate on the independent net's verdict. Nothing merges past red, including mine.

## Repo

- GitLab: `git@gitlab.com:vuuro/scanner.git` — role: Maintainer.
- Named `scanner` on purpose (Mark's framing): *"LiDAR is one provider, not the
  product. The product is Vuuro Scan."* Don't let the repo name narrow the product
  thinking.
- Default branch: `main`.
- Local git identity for this repo is set to `Lagahit Joven Andrei` /
  `jovenandrei0324@gmail.com` (matches Mark's GitLab account instructions, may differ
  from this machine's global git identity — that's intentional, don't "fix" it).

## Sibling project (t1-code-quality-joven)

Lives at `../t1-code-quality-joven` on this machine. Now background/side-track per the
brief — don't pull work back into it unless Mark explicitly asks. One known open item
there, explicitly deprioritized by Mark (*"Park it unless it is quick... Vuuro Scan is
the main track now"*): the `NO_SECRETS_IN_CODE` unquoted value-class regex still
matches whitespace, so an ordinary prose line in a README (`password: change me before
you deploy`) comes back as a P0 finding. Real, low effort, but not worth context-
switching for unless it's genuinely quick and Vuuro Scan work isn't waiting.
