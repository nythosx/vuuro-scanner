# Architecture Overview

This document serves as a critical, living template designed to equip agents with a rapid and comprehensive understanding of the codebase's architecture, enabling efficient navigation and effective contribution from day one. Update this document as the codebase evolves.

## 1. Project Structure

```
[Repo Root]/
├── scan-service/              # The Scan Service API (PHP + SQLite) — the only
│   │                          # backend in this repo; no framework
│   ├── public/
│   │   └── index.php          # Single-file router + all route handlers (regex
│   │                          # path match on $method/$path, no framework)
│   ├── src/
│   │   ├── Adapters/
│   │   │   └── RoomPlanSimulatorAdapter.php  # raw_capture (RoomPlan-shaped
│   │   │                                     # JSON) -> FloorPlan contract;
│   │   │                                     # the one place capture-provider
│   │   │                                     # geometry gets validated/mapped
│   │   ├── Export/
│   │   │   ├── FloorPlanImageRenderer.php    # FloorPlan -> per-room PNG tiles
│   │   │   └── FloorPlanPdfRenderer.php      # FloorPlan -> metrics-table PDF
│   │   ├── Storage/
│   │   │   └── Database.php   # PDO/SQLite connection + PRAGMA setup
│   │   │                      # (busy_timeout, etc.) — the only place a raw
│   │   │                      # PDO connection is opened
│   │   ├── Contract/          # Reserved for the FloorPlan contract's PHP-side
│   │   │                      # types; currently empty — the contract is
│   │   │                      # enforced by convention + `contracts/
│   │   │                      # floorplan.schema.json`, not typed PHP classes
│   │   ├── ScanSessionRepository.php  # All SQLite access goes through here —
│   │   │                              # sessions, tokens, capture append,
│   │   │                              # idempotency, rate-limit buckets,
│   │   │                              # access log. No scattered SQL elsewhere.
│   │   └── autoload.php       # Hand-rolled PSR-4-ish autoloader (no Composer)
│   ├── migrations/
│   │   └── schema.sql         # Full SQLite schema, applied fresh on boot
│   ├── fixtures/              # Hand-built RoomPlan-shaped JSON (single room,
│   │                          # L-shaped/degenerate/low-confidence adversarial
│   │                          # cases) — stand-in capture input; see
│   │                          # docs/adr/0001 for why (no Mac/Xcode access)
│   ├── net/                   # Independent net — the brief's "own the net"
│   │   │                      # HTTP-only, re-derives expected results with
│   │   │                      # its own separate logic, never imports src/.
│   │   │                      # This is the merge gate, not the unit tests.
│   │   ├── verify_capture_geometry.php
│   │   ├── verify_multiroom_and_attachments.php
│   │   ├── verify_exports.php
│   │   ├── verify_acl.php
│   │   ├── verify_coverage.php
│   │   ├── verify_security_fixes.php
│   │   ├── verify_error_messages.php
│   │   ├── verify_enterprise_hardening.php   # run last — see scan-service/README.md
│   │   └── verify_post_body_read_rate_limit.php  # deliberately standalone,
│   │                                              # not chained with the above 8
│   ├── tests/                 # Fast dev-loop unit tests (no server needed)
│   │   ├── adapter_test.php
│   │   ├── repository_test.php
│   │   ├── export_renderer_test.php
│   │   └── concurrency_test.php  # real multi-process proc_open test — the
│   │                             # write-lock race can't be proven any other
│   │                             # way against php -S's single-threaded server
│   ├── Dockerfile              # Host-independent run path (brief's "local
│   │                            # plus CI... prove slices before App Store
│   │                            # or production deploy")
│   └── README.md               # Local-only (gitignored) — run instructions,
│                                # API reference, "Known limits"
├── ios-app/                    # RoomPlan capture client — CI-compiled and
│   │                          # simulator-tested, no real Mac/Xcode/device
│   │                          # access on this machine
│   ├── Sources/
│   │   ├── VuuroScanApp.swift          # Entry point; wires the whole flow
│   │   ├── Capture/
│   │   │   ├── IdentityIntakeScreen.swift    # property/unit/org + consent form
│   │   │   ├── DeviceCapability.swift        # isRoomPlanSupported gate
│   │   │   ├── UnsupportedDeviceScreen.swift # non-LiDAR fallback
│   │   │   ├── CaptureCoordinator.swift      # RoomCaptureSession lifecycle
│   │   │   └── RoomCaptureScreen.swift       # SwiftUI/UIKit bridge
│   │   ├── Export/
│   │   │   └── CapturedRoomExporter.swift    # CapturedRoom -> Scan Service JSON
│   │   ├── Networking/
│   │   │   └── ScanServiceClient.swift       # HTTP client, X-Scan-Access-Token
│   │   ├── Models/             # Codable structs mirroring the FloorPlan
│   │   │                       # contract, kept in sync by hand
│   │   ├── History/            # Local-only scan history + audit log UI
│   │   │   ├── ScanHistoryEntry.swift  # One remembered session (id, token,
│   │   │   │                           # identity, created date)
│   │   │   ├── ScanHistoryStore.swift  # UserDefaults-backed persistence —
│   │   │   │                           # no server-side listing exists by
│   │   │   │                           # design (docs/adr/0003)
│   │   │   ├── ScanHistoryView.swift   # Per-session share/export + bulk
│   │   │   │                           # "download all" across history
│   │   │   ├── ScanResultsReportView.swift  # Read-only landlord/ops report
│   │   │   │                           # for one completed scan — per-room
│   │   │   │                           # metrics, notes/photos, floor plan +
│   │   │   │                           # PDF, access log; no edit affordances
│   │   │   └── AccessLogView.swift     # GET .../access-log, in-app
│   │   ├── Diagnostics/         # Deterministic error-code mechanism
│   │   │   ├── AppError.swift          # code is DERIVED from the real
│   │   │   │                           # caught error (HTTP status/transport
│   │   │   │                           # failure), never guessed — one place
│   │   │   │                           # owns the mapping so every screen
│   │   │   │                           # shows the same code for the same
│   │   │   │                           # failure
│   │   │   └── ErrorCodeView.swift     # Renders the code + a "Copy error
│   │   │                               # details" button (clipboard only —
│   │   │                               # no backend/telemetry)
│   │   ├── Debug/               # DEBUG-only, compiled out of Release
│   │   │   ├── FakeLidarMode.swift        # synthetic capture data, so a
│   │   │   │                              # cloud/no-LiDAR simulator has
│   │   │   │                              # something to push through the
│   │   │   │                              # pipeline
│   │   │   ├── FakeCaptureGenerator.swift # what FakeLidarMode triggers
│   │   │   └── DebugScanServiceURL.swift  # overrides the 127.0.0.1:8089
│   │   │                                  # default, since a cloud simulator
│   │   │                                  # (appetize.io) can't reach loopback
│   │   ├── Design/
│   │   │   └── VuuroDesign.swift  # Brand tokens/button styles, wired
│   │   │                           # through the main flow (LIDAR-7)
│   │   ├── Settings/
│   │   │   └── AppLanguage.swift  # System/English/Nederlands enum + the
│   │   │                           # AppStorage key backing the language
│   │   │                           # dropdown on the intake screen's toolbar
│   │   └── Legal/               # Commercialization posture — see ADR 0006.
│   │       │                     # DRAFT text, not lawyer-reviewed; needs
│   │       │                     # real legal review before commercial launch
│   │       ├── LegalContent.swift        # Terms of Service + Privacy Policy
│   │       │                             # body text, versioned
│   │       ├── LegalAgreementStore.swift # Records which version + when the
│   │       │                             # user agreed (UserDefaults), stamped
│   │       │                             # automatically the moment a scan
│   │       │                             # actually starts — not a checkbox gate
│   │       └── TermsAndPrivacyView.swift # In-app reader, linked from the
│   │                                     # bottom of the intake screen
│   ├── Resources/
│   │   └── Localizable.xcstrings  # String Catalog, en source + nl — VuuroScanApp
│   │                               # applies the chosen language app-wide via
│   │                               # .environment(\.locale, ...); falls back to
│   │                               # the raw English literal for any string not
│   │                               # yet in the catalog, so gaps don't crash
│   └── README.md               # Local-only (gitignored) — verification
│                                # status, checklist for whoever opens this
│                                # in Xcode first
├── contracts/
│   └── floorplan.schema.json   # The vendor-neutral FloorPlan contract every
│                                # capture adapter converts into; the one
│                                # thing every component above ultimately
│                                # agrees on
├── docs/
│   ├── adr/                    # Architecture decision records — local-only
│   │                          # (see docs/adr/0001-0004)
│   ├── status/                 # Dated internal working notes — local-only,
│   │                          # NOT Mark-facing, frozen historical record
│   └── VUURO_SCAN_LIDAR_DIRECTION_BRIEF_JOVEN_2026-08-06.pdf  # the only
│                                # source of truth for direction on this build
├── .github/workflows/
│   └── ios-build.yml           # compile-check (iOS Simulator build via
│                                # XcodeGen on a GitHub-hosted macOS runner) +
│                                # an ad-hoc-signed IPA job gated on it
├── ARCHITECTURE.md              # This document
└── README.md                    # Top-level, Mark/developer-facing overview —
                                  # the only README pushed as such per repo
                                  # policy (see .gitignore's comment block)
```

## 2. High-Level System Diagram

```
[iOS device / Xcode RoomPlan simulator / appetize.io cloud simulator]
   |  guided RoomPlan capture (or FakeLidarMode synthetic data)
   v
[ios-app: CapturedRoomExporter -> ScanServiceClient]
   |  HTTP + X-Scan-Access-Token, RoomPlan-shaped JSON
   v
[scan-service/public/index.php — single-file router]
   |
   +--> [RoomPlanSimulatorAdapter] --> validates + maps raw_capture
   |                                    into the FloorPlan contract
   |
   +--> [ScanSessionRepository] --> SQLite (sessions, tokens, floor_plans,
   |         |                       idempotency_keys, rate_limit_events,
   |         |                       access_log) via [Storage/Database]
   |         v
   |    [Database::connect()] -- PRAGMA busy_timeout, BEGIN IMMEDIATE locking
   |                              for the multi-writer capture/attach race
   |
   +--> [FloorPlanImageRenderer / FloorPlanPdfRenderer] --> PNG/PDF export
   |
   v
[FloorPlan contract, per contracts/floorplan.schema.json]
   |
   +--> consumed by the Vuuro rental app later, as an API client (not built here)

[net/verify_*.php] — talks to the live HTTP API only, re-derives expected
  geometry/structure independently, never imports src/. This is the merge
  gate (the brief's "own the net" constraint), separate from tests/*_test.php (fast
  in-process unit tests) and from the manual appetize.io simulator loop above.
```

The Scan Service is the only thing every other component agrees with: `ios-app` produces `raw_capture` JSON and consumes the resulting `FloorPlan`; the independent net proves the API's behavior from the outside, sharing no code with the adapter/repository/renderer it's checking.

## 3. Core Components

### 3.1. Frontend

One client surface, not a web frontend to the Scan Service in the SPA sense:

- **`ios-app/`** — the real product client (SwiftUI). Guided RoomPlan capture, identity/consent intake, multi-room "unit story" flow, results/export. CI-compiled and appetize.io-simulator-verified; never run on a real device or real LiDAR hardware yet (no Mac/Xcode access on the dev machine).

### 3.2. Backend Services

#### 3.2.1. Scan Service API (`scan-service/public/index.php`, `scan-service/src/`)

Name: Scan Service

Description: The single backend in this repo. Plain PHP, no framework — `public/index.php` is a hand-rolled router matching `$method`/`preg_match($path)` per route, calling straight into `ScanSessionRepository` (all SQLite access), `RoomPlanSimulatorAdapter` (raw capture -> `FloorPlan`), and the two `Export/` renderers. Every session-scoped route after creation requires an `X-Scan-Access-Token` header (`docs/adr/0003`). Handles session lifecycle (create, rotate-token, capture, photo uploads, photos, notes, exports, access-log), idempotent capture retries, per-session/per-IP rate limiting, and a request body size cap enforced ahead of PHP's own `post_max_size`. Photo uploads (`POST .../photo-uploads`) store real image bytes to local disk under `data/photos/{session_id}/`, content-sniffed via `finfo`, not just accept a url the client had to host elsewhere first.

Technologies: PHP 8.1+ (`declare(strict_types=1)` throughout), PDO/SQLite, no framework, no Composer dependency (hand-rolled `autoload.php`).

Deployment: `php -d post_max_size=30M -d upload_max_filesize=26M -d display_errors=0 -S 127.0.0.1:8089 public/index.php` locally (dev only — `php -S` is single-threaded), or the repo's `Dockerfile` (FrankenPHP + Caddy, a real concurrent server, per `scan-service/Dockerfile`) for a host-independent run (the brief's "no silent production leap" constraint: "local plus CI... prove slices" — not tied to this one Windows machine).

#### 3.2.2. Capture Adapter (`src/Adapters/RoomPlanSimulatorAdapter.php`)

Name: RoomPlan-shaped capture adapter

Description: Converts client-supplied `raw_capture` JSON (shaped like Apple's `CapturedRoom` export — `floors[].polygonCorners`, `walls[]`, `doors[]`, `windows[]`, per-surface `confidence`) into the vendor-neutral `FloorPlan` contract, computing area/perimeter/coverage along the way. Provider-neutral by design (`docs/adr/0001`): RoomPlan, the RoomPlan simulator, Android, or a third-party SDK are all meant to be adapters behind this same contract, not special-cased in the core. Every client-controlled field here (surface arrays, `confidence`, `polygonCorners` entries) is defensively type-checked before use — the bulk of the hardening findings in `docs/status/2026-08-14-internal-notes.md` were type-confusion crashes found by systematically walking this exact input surface.

Technologies: PHP, no external geometry library — shoelace-formula area/perimeter math is hand-written (and independently re-implemented in `net/verify_capture_geometry.php`, on purpose, so the net never shares a bug with the adapter it's checking).

Deployment: In-process with the Scan Service, not a separate service.

#### 3.2.3. Export Renderers (`src/Export/FloorPlanImageRenderer.php`, `src/Export/FloorPlanPdfRenderer.php`)

Name: Floor plan exporters

Description: `FloorPlanImageRenderer` draws each room as its own accurately-scaled PNG tile (bounded at `MAX_CANVAS_DIMENSION_PX`, 4000px) — deliberately per-room, not a spatially fused building layout, since separate RoomPlan capture sessions have no shared coordinate frame (`docs/adr/0002`). `FloorPlanPdfRenderer` produces a per-room metrics table (bounded at `MAX_PAGES`, 200), escaping `\`/`(`/`)` and stripping non-ASCII before writing any client-influenced text into a PDF string literal — no content-stream injection vector.

Technologies: PHP's bundled GD (`imagestring()`/canvas functions) for PNG; a hand-rolled minimal PDF writer for PDF (no external PDF library).

Deployment: In-process with the Scan Service.

#### 3.2.4. iOS Capture Client (`ios-app/Sources/`)

Name: VuuroScan iOS app

Description: SwiftUI app wiring identity/consent intake -> device-capability check (`DeviceCapability.isRoomPlanSupported`) -> one or more guided RoomPlan captures stitched onto one scan session -> optional photo/note attachments -> results. `Sources/Debug/` (compiled out of Release) provides `FakeLidarMode` (synthetic capture data, since neither a Mac nor a cloud simulator has real LiDAR) and `DebugScanServiceURL` (points at a tunnel reachable from a cloud simulator, since `127.0.0.1` isn't). CI-compiled and appetize.io-verified end to end (capture -> upload -> results -> PDF export); real-device/real-LiDAR behavior is still unverified. Every user-facing failure is wrapped by `Sources/Diagnostics/AppError.swift` into a short code (e.g. `VS-CAPTURE_UPLOAD-500`) derived directly from the real caught error, with a one-tap "Copy error details" action — the mechanism whoever is running the app (Mark, on a real device) uses to report a failure precisely enough to act on, with no telemetry/backend involved.

Technologies: Swift, SwiftUI, RoomPlan/ARKit (per public API docs — never compiled against the real SDK locally).

Deployment: `.github/workflows/ios-build.yml`'s `compile-check` job (XcodeGen + `xcodebuild` for the iOS Simulator on a GitHub-hosted macOS runner) produces the `.app` used for appetize.io testing; a downstream `needs: compile-check` job produces an ad-hoc-signed IPA.

## 4. Data Stores

### 4.1. Scan Service SQLite database (`scan-service/data/scan_service.sqlite`, gitignored)

Name: Scan Service database

Type: SQLite (via PDO), schema in `migrations/schema.sql`, applied fresh on boot.

Purpose: Sessions (identity, purpose, occupied/consent, access token + expiry), floor plan contract JSON per session, idempotency-key claims/fingerprints, rate-limit event buckets, and the access-log audit trail (`action`/`outcome`/`occurred_at` only — no token or caller IP ever written to it). All access goes through `ScanSessionRepository`, chosen specifically so a later swap to MySQL/Postgres is a storage-layer change, not a rewrite (`docs/adr/0001`).

### 4.2. Contract schema (`contracts/floorplan.schema.json`)

Name: FloorPlan contract

Type: JSON Schema file, not a runtime data store, but the thing every component above (adapter output, iOS Models/, the independent net's assertions) is validated against or mirrors by hand.

Purpose: The one vendor-neutral shape every capture provider converts into and every consumer reads from — designed API-first, before any real consumer exists.

## 5. External Integrations / APIs

None in the running system. This repo makes no outbound calls to any third-party API at runtime — no LLM, no payment, no analytics.

Two adjacent tools are development/testing aids only, not integrations the running Scan Service or iOS app depend on:

- **appetize.io** — a cloud-streamed iOS Simulator used manually to test CI-built `.app` artifacts end to end, since no Mac/Xcode is reachable on the dev machine. Not called by any code in this repo.
- **localtunnel** (`npx localtunnel --port 8089`) — used ad hoc to expose the local Scan Service to appetize.io's cloud simulator during a test session, via `DebugScanServiceURL`'s DEBUG-only fallback. Never a production dependency.

## 6. Deployment & Infrastructure

Cloud Provider: None. Everything here targets local/CI proof only — no App Store or production deploy required for this build's current arc (the brief's "no silent production leap" constraint).

Key Services Used: Docker (`scan-service/Dockerfile`, host-independent Scan Service run path). GitHub Actions (`.github/workflows/ios-build.yml`) for the iOS side — a macOS runner generates an Xcode project via XcodeGen and builds `ios-app/` for the Simulator (`compile-check`), then a downstream job produces an ad-hoc-signed IPA.

CI/CD Pipeline: `.github/workflows/ios-build.yml` is the iOS-side CI (compile-check, device-compile-check, and simulator tests on a GitHub-hosted macOS runner). `.github/workflows/scan-service-ci.yml` and `.gitlab-ci.yml` are the Scan Service merge gates, both running `scan-service/tests/*_test.php` and the independent `net/verify_*.php` chain — GitLab (self-hosted Windows-shell runner) is where merges actually happen, GitHub Actions mirrors it.

Monitoring & Logging: None beyond the Scan Service's own `access_log` table (authorization attempts, granted/denied) and PHP's own error log. No external logging/monitoring service.

## 7. Security Considerations

Authentication: Per-session `X-Scan-Access-Token` (random UUID, returned once at session creation), required on every session-scoped route after creation. Not a user/org account system — see `docs/adr/0003` for exactly what this does and deliberately does not solve (no login, no tenant isolation beyond per-session possession, no transport security guarantee — this repo runs over plain HTTP locally).

Authorization: Possession of the correct session token, checked with `hash_equals()` everywhere a token is compared. Token expiry + a 7-day `rotate-token` grace window are enforced (`ScanSessionRepository::ROTATE_GRACE_PERIOD_SECONDS`, confirmed with Mark 2026-08-14).

Data Encryption: None in this build — plain HTTP locally, no TLS termination in this repo. A real deployment would need TLS in front of this; not something this repo's ADR claims to have solved. On the iOS side, `ios-app/Sources/History/ScanHistoryStore.swift` stores each remembered session's access token in the iOS Keychain (via `KeychainTokenStore`), with the plaintext `accessToken` field blanked in the local UserDefaults history blob. The plaintext-in-UserDefaults limit this document previously flagged has since been closed.

Key Security Tools/Practices:

- **Consent gate at creation**: `occupied: true` requires `consent_obtained: true` on `POST /scan-sessions` or the request is rejected (`403 consent_required`) — no path to create a session for an occupied unit without recording consent.
- **Rate limiting**: per-session and per-caller-IP fixed-window buckets on session creation, capture, exports (PNG/PDF independently), failed-auth attempts, and the raw request-body read itself (before any route/auth check) — see `scan-service/README.md`'s "Known limits" for exact budgets.
- **Idempotent capture retries**: a claimed `Idempotency-Key` fingerprints the request body; a retry with the same key + same body replays cleanly, a reuse with a *different* body is rejected (`409 idempotency_key_reused`) instead of silently dropping or double-applying the second write.
- **Write-lock concurrency**: `ScanSessionRepository::withWriteLock()` wraps capture/photo/note appends in `BEGIN IMMEDIATE` (not PDO's deferred `beginTransaction()`) — closes a real, previously-silent data-loss race between two concurrent writers to the same session's `floor_plans` row.
- **PDF injection hardening**: `FloorPlanPdfRenderer` escapes `\`/`(`/`)` and strips non-ASCII before writing client-influenced text into a PDF string literal.
- **Type-confusion hardening**: every client-controlled field reaching a strictly-typed PHP function or an `array_merge()`/`array_map()` call is validated first — a whole class of crash-to-500 and silent-corruption bugs found by systematically walking the input surface (`docs/status/2026-08-13` and `2026-08-14` notes).

## 8. Development & Testing Environment

Local Setup Instructions: See `scan-service/README.md` "Run it (native PHP, no Docker)" and "Run it (Docker, host-independent)". No Mac/Xcode locally for `ios-app/` — see its README's verification-status section for exactly what is and isn't proven without one.

Testing Frameworks:
- Scan Service: hand-rolled PHP test scripts, no framework. `tests/*_test.php` (fast, in-process: `adapter_test.php`, `repository_test.php`, `export_renderer_test.php`, `concurrency_test.php`) and `net/verify_*.php` (the independent, HTTP-only merge gate — 8 chained scripts + 1 deliberately standalone, see `scan-service/README.md`).
- iOS: no local test runner (no Xcode). Verification today is CI compile-check + manual appetize.io simulator runs, not automated tests.

Code Quality Tools: None automated yet (no linter/formatter config found in this repo for either PHP or Swift). Correctness is enforced by the independent net's re-derivation approach, not static analysis.

## 9. Future Considerations / Roadmap

- **iOS real-device verification** — the single biggest open item. Everything in `ios-app/` is CI-compiled and appetize.io-simulator-verified, never run on a Mac, a real device, or against real LiDAR hardware. See `ios-app/README.md`'s checklist for whoever opens this in Xcode first.
- **~~`ios-app-with-design/` promotion decision~~** — resolved 2026-09-03 (LIDAR-7): folded its one differentiator (brand tokens) into `ios-app/Sources/Design/VuuroDesign.swift`, unwired, and retired the copy. It had no CI coverage and had drifted from `ios-app/`'s real bug fixes.
- **Laser-pairing spike** — deliberately deferred with a written rationale and integration sketch; revisit only if a named pilot or Mark asks for ground-truth measurement validation (`docs/adr/0004`).
- **Real fused multi-room floor plan layout** — blocked on the capture flow moving to one continuous multi-room RoomPlan session per unit rather than one session per room; `outline_m` staying room-local today is the honest data to have either way (`docs/adr/0002`).
- **Real Vuuro account auth** — the per-session token model is designed to compose underneath a future account system once Vuuro API coupling is decided, not to be replaced wholesale (`docs/adr/0003`).
- **Scan Service CI** — closed. Both `.github/workflows/scan-service-ci.yml` and `.gitlab-ci.yml` run the full net/unit gate; GitLab is the canonical merge gate. `verify_enterprise_hardening.php` must run last (its rate-limit flood would otherwise starve the other scripts), and `verify_post_body_read_rate_limit.php` is deliberately standalone on a separate port for the same reason.

## 10. Project Identification

Project Name: Vuuro Scan

Repository: `feature/vuuro-scan` branch (single working branch for this whole build, not yet merged to `main`); mirrored to a GitHub repo used only as the CI build target for `.github/workflows/ios-build.yml`.

Primary Contact/Team: Mark Oosterom (product owner) / Joven (this build).

Date of Last Update: 2026-08-27.

## 11. Glossary / Acronyms

FloorPlan contract: The vendor-neutral JSON shape (`contracts/floorplan.schema.json`) every capture adapter converts into and every consumer (iOS app, future Vuuro rental app) reads from.

Independent net: `scan-service/net/verify_*.php` — HTTP-only scripts that re-derive expected results with their own separately-written logic and never import the code they're checking. The merge gate, per the brief's hard constraint: "You own the net under the work... A real independent check that runs without me, built from different assumptions than the code it guards, and whose verdict you cannot merge past."

Evidence over theatre: the brief's hard constraint — "Structure them in three buckets: verified working, implemented but not yet verified, at risk." Never round "CI-compiled and simulator-tested" up to "verified," never let "fixture" and "real capture" blur together. Drives the wording in `ios-app/README.md` and this document's own verification-status language.

FakeLidarMode / DebugScanServiceURL: DEBUG-only iOS tools (`ios-app/Sources/Debug/`) that make appetize.io cloud-simulator testing possible without real LiDAR hardware or a publicly reachable Scan Service. Compiled out of Release builds; never reach a real user.

Access token / rotate-token: The per-session capability token model closing the "anyone with the link" gap (`docs/adr/0003`). `rotate-token` is the only way to renew a session's token before or shortly after expiry (within a 7-day grace window).

RoomPlan simulator fixture: Hand-built JSON (`scan-service/fixtures/`) shaped to mirror Apple's real `CapturedRoom` export format, used as Phase 1 capture input in place of an unreachable Xcode RoomPlan simulator (`docs/adr/0001`).
