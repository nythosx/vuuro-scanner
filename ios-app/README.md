# Vuuro Scan — iOS App (`ios-app/`)

## Verification status

- **CI-compiled**: `.github/workflows/ios-build.yml` generates the Xcode project via
  XcodeGen and builds this app for the iOS Simulator on a GitHub-hosted macOS runner
  (`compile-check`), then a downstream job produces an ad-hoc-signed IPA.
- **Simulator-verified end to end**: manually tested on appetize.io's cloud-streamed
  iOS Simulator, using `Sources/Debug/FakeLidarMode` (synthetic RoomPlan-shaped capture
  data, since a cloud simulator has no LiDAR) and `Sources/Debug/DebugScanServiceURL`
  (pointed at a `localtunnel` URL, since the cloud simulator can't reach a local
  machine's `127.0.0.1`). Confirmed working: capture -> upload -> results -> PDF export.
- **NOT yet verified**: real RoomPlan capture on real LiDAR hardware. Nothing in this
  app has touched a real LiDAR sensor yet — this is the single biggest open item. See
  the checklist below.

Evidence over theatre: never round "CI-compiled and simulator-tested" up to "verified."
Fixture/simulator proof and real-capture proof are not the same claim.

## Branding

`Sources/Design/VuuroDesign.swift` holds vuuro.com's brand tokens (colors, fonts, button
styles) — folded in from the retired `ios-app-with-design/` tree (LIDAR-7, 2026-09-03),
now wired through the main flow (intake, capture, rooms, attachments, result, history,
the read-only scan report). Wire any remaining screen to
`.vuuroPrimary`/`.vuuroSecondary`/`.vuuroCard()`.

## Localization

`Resources/Localizable.xcstrings` is a SwiftUI String Catalog (English source + Dutch),
registered as a target resource in `project.yml`. A dropdown in the top-right corner of
the first screen (New scan) lets the user pick System default / English / Nederlands at
runtime — `VuuroScanApp` stores the choice in `@AppStorage` and applies it app-wide via
`.environment(\.locale, ...)`, no relaunch needed. Existing `Text("literal")` calls need
no code change — SwiftUI resolves plain string literals against the catalog
automatically; anything not yet in the catalog just falls back to its English text.

Coverage: as of 2026-09-16, every static (non-interpolated) string passed to
`Text`/`Button`/`Label`/`Toggle`/`TextField`/`.navigationTitle` across `Sources/` has a
catalog entry — verified by diffing a grep of all such literals against the catalog's
keys, not just spot-checked. Interpolated strings (e.g. `Text("Room \(index + 1)")`) are
intentionally NOT in the catalog — SwiftUI's auto-generated key for those depends on
Swift's format-specifier inference (`%lld` vs `%@` vs `%f`) per interpolated type, which
can't be hand-replicated reliably without Xcode's own extraction tool; they render fine,
just always in English until someone runs "Extract to String Catalog" in Xcode and fills
in translations for them. Date/time text must use `Text(date, format:)`, never
`Text(date.formatted(...))` — the latter reads `Locale.autoupdatingCurrent`, not this
app's `\.locale` environment override, so it silently ignores the in-app language choice.

## Terms of Service & Privacy Policy

A disclosure line + "Read Terms of Service & Privacy Policy" link sit at the bottom of
the first screen (`Sources/Legal/`, see `docs/adr/0006`). Agreement is automatic on use
(no blocking checkbox), recorded locally the moment a scan actually starts. **The legal
text itself is a draft, not lawyer-reviewed** — read the ADR before treating it as
launch-ready; it explains exactly what's covered and what still needs a real lawyer,
translation, and (if needed) server-side proof-of-agreement before commercial launch.

The body font is vuuro.com's real typeface, Open Sans (OFL-licensed), bundled as a single
variable font at `Resources/Fonts/OpenSans-Variable.ttf` — `project.yml`'s `resources:`
entry makes `xcodegen generate` copy it into the app bundle automatically, no manual
Xcode step needed. It's declared in `Info.plist`'s `UIAppFonts` (via `project.yml`) so
the system exposes its full weight axis, not just the default instance that
`CTFontManagerRegisterFontsForURL` alone would expose; `VuuroFontRegistration.registerBundledFonts()`
(called from `VuuroScanApp.init`) additionally registers it for `.process` scope as a
belt-and-suspenders fallback. `VuuroFont` calls `.weight(_:)` on it directly, which
resolves against the font's own weight axis. `Resources/Fonts/OFL.txt` is the required
license text — keep it alongside the font file if this ever needs to be redistributed
outside this repo.

## Checklist: opening this in Xcode for the first time (real-device test)

### Prereqs

- A Mac with Xcode installed.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — this
  repo ships `project.yml`, not a committed `.xcodeproj`.
- An iPhone or iPad with a LiDAR sensor — iPhone 12 Pro or newer Pro/Pro Max models, or
  iPad Pro (2020 or newer). See `Sources/Capture/DeviceCapability.swift`'s
  `isRoomPlanSupported` gate; anything else routes to `UnsupportedDeviceScreen`.
- A free Apple ID signed into Xcode. A paid Apple Developer account is **not** required
  for this test — see "Apple Developer account" below.
- The Mac and the device on the same Wi-Fi network.

### Steps

1. Generate the Xcode project:
   ```
   cd ios-app
   xcodegen generate
   ```
2. Open `VuuroScan.xcodeproj` in Xcode.
3. Fix code signing. `project.yml` ships with `CODE_SIGN_STYLE: Manual` and a blank
   `DEVELOPMENT_TEAM` — deliberately left blank since no Apple Developer Team ID was
   available when this was built (see the comment in `project.yml`). In Xcode: select
   the `VuuroScan` target -> **Signing & Capabilities** -> switch Signing Style to
   **Automatic** -> pick your personal team from the dropdown. This is a local
   Xcode-only override — do not commit it back to `project.yml`.
4. Select your real device (not a Simulator) as the run destination.
5. Run the Scan Service on this same Mac, bound to all interfaces so the phone can
   reach it over Wi-Fi (binding to `127.0.0.1` only would make it unreachable from a
   separate physical device):
   ```
   cd scan-service
   php -d post_max_size=30M -d upload_max_filesize=26M -d display_errors=0 -S 0.0.0.0:8089 public/index.php
   ```
   Find your Mac's LAN IP: `ipconfig getifaddr en0` (try `en1` if that's blank).
6. In Xcode, **Edit Scheme -> Run -> Arguments -> Environment Variables**, add:
   - `SCAN_SERVICE_BASE_URL` = `http://<your-mac-lan-ip>:8089`
   - `FAKE_LIDAR_MODE` = `0` — **must be set explicitly.** As of the appetize.io
     debug-testing pass, `FakeLidarMode`'s fallback (used when the env var is unset)
     defaults to `true` and `DebugScanServiceURL`'s fallback points at a debug
     tunnel URL, specifically so appetize.io sessions work with zero per-session
     config. Leaving `FAKE_LIDAR_MODE` unset for a real-device Xcode run will
     silently route through `FakeCaptureGenerator`'s synthetic data instead of real
     RoomPlan — see `Sources/Debug/FakeLidarMode.swift` and
     `Sources/Debug/DebugScanServiceURL.swift`.

   These env vars only work for a Debug build run directly from Xcode
   (`Sources/Debug/DebugScanServiceURL.swift`, compiled out of Release). Any build
   that isn't launched through Xcode Run — TestFlight, an ad-hoc `.ipa`, an App Store
   build — instead reads the `SCAN_SERVICE_BASE_URL` **build setting** in
   `project.yml` (baked into Info.plist as `ScanServiceBaseURL` at build time). To
   point one of those at a real server: override that build setting per
   configuration (an `.xcconfig` file, a CI env var passed to `xcodebuild`, or an
   Xcode Cloud environment variable), pointing at an HTTPS host — `NSAppTransportSecurity`
   here only exempts local/private network ranges and loopback
   (`NSAllowsLocalNetworking`), not arbitrary internet cleartext, so a real deployed
   Scan Service needs TLS or its own ATS exception added first. Until one of those is
   set, every build defaults to `http://127.0.0.1:8089`, same as today.
7. Build and run on the device. If prompted, trust the developer certificate on the
   device itself (Settings -> General -> VPN & Device Management).
8. Walk through the real flow on the device: identity/consent intake -> guided RoomPlan
   capture of an actual room -> finish capture -> confirm it uploads -> results screen
   shows the floor plan -> try both the PNG and PDF export.
9. Keep the Terminal window running the PHP server visible while you do this — its
   default per-request access log is independent proof the app is round-tripping to
   the real server, not just rendering local UI state.

### What this proves, and doesn't

**Proves**: real Apple RoomPlan geometry, captured on real LiDAR hardware, flowing
through the real adapter/pipeline into the Scan Service, for the first time.

**Does not prove**: App Store distribution or signing (this test only needs
ad-hoc/local Xcode signing, nothing more). Multi-room "unit story" fusion into one
spatially-coherent floor plan does exist today — `MultiRoomCaptureCoordinator` walks a
structure across rooms in one continuous ARSession and fuses them into a shared
coordinate frame (`docs/adr/0002-export-coordinate-frame.md`) — but that fusion path is
still only simulator/fixture-verified, same as everything else on this list, until it's
been run through on real LiDAR hardware.

### Apple Developer account

Not required for this test. Xcode can build-and-run to a physical device on a personal
(free) Apple ID for local debugging — the app just needs re-signing from Xcode roughly
every 7 days if it stays installed that long. A paid account only matters later, for
TestFlight/App Store distribution.

### When you're done

Take screenshots or a screencast of each step above, labeled explicitly, e.g.
`"REAL RoomPlan — iPhone 15 Pro, iOS 17.5"`, plus the branch and commit you built from
(`git rev-parse --short HEAD` from the repo root) — so it's unambiguous this isn't
`FakeLidarMode`/simulator output.
