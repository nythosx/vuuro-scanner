//
//  BuildInfo.swift
//  VuuroScan
//
//  DEBUG-ONLY. Mark's 2026-09-02 request: since he's the only runtime with
//  real hardware, every screenshot he sends should carry "version plus who
//  am I talking to" — commit SHA, build time, and the Scan Service base URL
//  this build is actually pointed at — instead of him having to ask.
//
//  GitCommitSHA and BuildTimestamp come from Info.plist keys injected by a
//  Debug-only Run Script build phase (see project.yml's postbuildScripts) —
//  XcodeGen's declarative `info.properties` can't shell out to git, so
//  those keys don't exist until that script runs at build time.
//

#if DEBUG
import Foundation

enum BuildInfo {
    static var commitSHA: String {
        Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String ?? "unknown"
    }

    static var buildTimestamp: String {
        Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String ?? "unknown"
    }

    static var scanServiceBaseURL: String {
        DebugScanServiceURL.resolved?.absoluteString ?? "http://127.0.0.1:8089"
    }

    static var summary: String {
        "\(commitSHA) · built \(buildTimestamp) · \(scanServiceBaseURL)"
    }
}
#endif
