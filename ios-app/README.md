# iOS app — written, not compiled or run

No Mac or Xcode is reachable on the machine this repo is being developed on. The Swift
under `Sources/` was written against RoomPlan/SwiftUI's public API from documentation
and memory, but **has never been opened in Xcode, compiled, or run.** Treat everything
in `Sources/` as a design draft, not verified working code, until someone with a Mac
actually builds it. Per CLAUDE.md hard constraint #7 (evidence over theatre), this goes
in the "implemented but not yet verified" bucket of the daily update — never "verified"
— until that happens.

## What's here

- `Sources/VuuroScanApp.swift` — entry point; wires device-capability check → guided
  capture → export → upload → result display. Uses a hardcoded placeholder identity —
  there is no property/unit picker or Vuuro auth yet, deliberately out of scope.
- `Sources/Capture/DeviceCapability.swift` — the single place that checks
  `RoomCaptureSession.isSupported` (hard constraint #5: device honesty). Every capture
  entry point must go through this before touching `RoomCaptureSession`.
- `Sources/Capture/UnsupportedDeviceScreen.swift` — the designed fallback screen for
  non-LiDAR devices.
- `Sources/Capture/CaptureCoordinator.swift`, `RoomCaptureScreen.swift` — RoomPlan
  session lifecycle and the SwiftUI/UIKit bridge (`RoomCaptureView` has no SwiftUI-native
  equivalent as of this writing, per public docs).
- `Sources/Export/CapturedRoomExporter.swift` — converts a finished `CapturedRoom` into
  the exact JSON shape `scan-service/src/Adapters/RoomPlanSimulatorAdapter.php` expects.
  **This file carries the biggest unverified assumption in this repo: that
  `CapturedRoom.Surface` exposes `polygonCorners` for a floor outline.** See the comment
  at the top of that file.
- `Sources/Networking/ScanServiceClient.swift` — HTTP client for the Scan Service
  endpoints (`../scan-service/README.md`), including the `X-Scan-Access-Token` header
  required by every call after session creation
  (`../docs/adr/0003-privacy-acl-session-tokens.md`).
- `Sources/Models/` — Codable structs mirroring `../contracts/floorplan.schema.json`,
  kept in sync by hand (no schema-to-Swift generation yet — an open decision, not solved
  here).

## Checklist for whoever opens this in Xcode first (Mark, or anyone with a Mac)

1. Create an actual Xcode project/target and add `Sources/` to it — none exists yet,
   since there's no way to generate or validate an `.xcodeproj` without Xcode itself.
2. Confirm `CapturedRoom.Surface.polygonCorners` is real (see the note in
   `CapturedRoomExporter.swift`). If it isn't, fix the exporter — and check whether
   `RoomPlanSimulatorAdapter.php`'s expected shape and
   `scan-service/fixtures/roomplan_captured_room_single_room.json` need to change to
   match reality. Fix the adapter/fixture to match the real SDK, not the other way
   around.
3. Confirm `RoomBuilder`, `CapturedRoomData`, and the `RoomCaptureSessionDelegate` /
   `RoomCaptureViewDelegate` method signatures used in `CaptureCoordinator.swift` and
   `RoomCaptureScreen.swift` against the actual SDK for the target iOS version.
4. Run a real capture (device or Xcode's RoomPlan simulator) and confirm the exported
   JSON actually reaches the Scan Service (`../scan-service/README.md` for how to run
   it) and comes back as a valid `FloorPlan` — i.e. actually close the loop this file
   only currently claims to close.
5. Once it builds, consider a GitHub Actions macOS runner to at least compile-check this
   code in CI going forward — not required to start using this checklist, worth adding
   once there's verified-building Swift code to protect from regressing silently.
6. `VuuroScanApp.swift`'s placeholder identity hardcodes `occupied: false`. Before this
   touches any real occupied unit, replace it with a real consent step in the UI — see
   the comment at that call site and `docs/adr/0003-privacy-acl-session-tokens.md`.

This is a draft to accelerate that first Xcode session, not a substitute for it.
