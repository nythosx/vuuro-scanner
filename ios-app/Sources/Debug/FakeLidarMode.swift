//
//  FakeLidarMode.swift
//  VuuroScan
//
//  DEBUG-ONLY. Governs whether the post-capture flow (upload, results,
//  attachments, exports) runs on synthetic RoomPlan-shaped data instead of a
//  real LiDAR scan — see FakeCaptureGenerator.swift for what it triggers.
//  Never compiled into a Release build, so it can never reach a real user.
//
//  Checked in two places, in order:
//  1. The FAKE_LIDAR_MODE environment variable — set it to 1/true in
//     Xcode's scheme (Edit Scheme -> Run -> Arguments -> Environment
//     Variables) to flip this per-run without touching code or rebuilding
//     the artifact, e.g. switching between a "development" run (fake data,
//     no LiDAR needed) and a "production"-like run (real LiDAR) from the
//     same build.
//  2. `fallback` below, when no such variable is set. An uploaded appetize.io
//     .app has no way for us to set an environment variable at launch, so
//     this is what actually governs it there — flip it, rebuild, push.
//

#if DEBUG
import Foundation

enum FakeLidarMode {
    static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["FAKE_LIDAR_MODE"] {
            return raw == "1" || raw.lowercased() == "true"
        }
        return fallback
    }

    private static let fallback = false
}
#endif
