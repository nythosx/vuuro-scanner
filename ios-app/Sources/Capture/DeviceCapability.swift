//
//  DeviceCapability.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Hard constraint #5 (CLAUDE.md): "Detect LiDAR/RoomPlan capability.
//  Unsupported devices get a clear message and a designed fallback path —
//  never a crash, never a silent empty feature." This file is the single
//  place that check happens; every entry point into capture must go through
//  DeviceCapability.current before touching RoomCaptureSession.
//

import RoomPlan

enum DeviceCapability {
    /// `RoomCaptureSession.isSupported` is Apple's documented capability
    /// check (true only on LiDAR-equipped devices). This assumption is
    /// unverified against the real SDK on this machine — confirm it's still
    /// the correct API the first time this is opened in Xcode, and fix this
    /// file (not silently work around it) if the real API differs.
    static var isRoomPlanSupported: Bool {
        RoomCaptureSession.isSupported
    }

    /// Human-readable reason shown on the fallback screen. Kept separate
    /// from the boolean check so the UI text and the capability check can't
    /// drift out of sync silently.
    static var unsupportedReason: String {
        if isRoomPlanSupported {
            return ""
        }
        return "This device doesn't have the LiDAR sensor Vuuro Scan's guided room capture needs. " +
            "Scanning is available on iPhone 12 Pro or newer Pro models, and iPad Pro (2020 or newer)."
    }
}
