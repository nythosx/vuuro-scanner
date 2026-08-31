//
//  DebugScanServiceURL.swift
//  VuuroScan
//
//  DEBUG-ONLY. Overrides ScanServiceClient's default 127.0.0.1:8089 base URL
//  — needed because a cloud-streamed simulator (e.g. appetize.io) can't
//  reach this machine's own loopback address at all ("Connection refused"),
//  confirmed live when FakeLidarMode's synthetic capture tried to upload.
//  Never compiled into a Release build.
//
//  Checked in two places, in order, same pattern as FakeLidarMode:
//  1. The SCAN_SERVICE_BASE_URL environment variable — set it in Xcode's
//     scheme to override per-run without touching code.
//  2. `fallback` below. Point it at a tunnel (e.g. `localtunnel --port 8089`
//     or ngrok) reaching this machine's local Scan Service, rebuild, and
//     push when testing against appetize.io. Reset to nil before any build
//     meant for a real-device test — a stale tunnel URL just fails closed,
//     but it's still dead weight to ship.
//

#if DEBUG
import Foundation

enum DebugScanServiceURL {
    static var resolved: URL? {
        if let raw = ProcessInfo.processInfo.environment["SCAN_SERVICE_BASE_URL"], let url = URL(string: raw) {
            return url
        }
        return fallback.flatMap(URL.init(string:))
    }

    private static let fallback: String? = "https://early-chicken-hug.loca.lt"
}
#endif
