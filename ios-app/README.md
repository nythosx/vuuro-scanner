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
   php -d post_max_size=16M -d display_errors=0 -S 0.0.0.0:8089 public/index.php
   ```
   Find your Mac's LAN IP: `ipconfig getifaddr en0` (try `en1` if that's blank).
6. In Xcode, **Edit Scheme -> Run -> Arguments -> Environment Variables**, add:
   - `SCAN_SERVICE_BASE_URL` = `http://<your-mac-lan-ip>:8089`
   - Leave `FAKE_LIDAR_MODE` unset (or set it to `0`) — this is what forces the app
     down the real RoomPlan path instead of `FakeCaptureGenerator`'s synthetic data.
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

**Does not prove**: multi-room "unit story" fusion into one spatially-coherent floor
plan — still one RoomPlan session per room today, with no shared coordinate frame
(`docs/adr/0002-export-coordinate-frame.md`); App Store distribution or signing (this
test only needs ad-hoc/local Xcode signing, nothing more).

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
