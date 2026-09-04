//
//  RoomTypeGuessSettings.swift
//  VuuroScan
//
//  User-facing on/off switch for the live room-type guess (RoomTypeClassifier)
//  — set on the intake screen, not Debug-only like FakeLidarMode/
//  DebugScanServiceURL. Off means the guess is never computed during capture
//  (no live prompt) and never included in the upload — not just hidden.
//

import Foundation

enum RoomTypeGuessSettings {
    private static let key = "roomTypeGuessEnabled"

    static var isEnabled: Bool {
        get {
            // Defaults to on — UserDefaults.bool(forKey:) already returns
            // false for a never-set key, so this registers the real default
            // explicitly rather than relying on that accidentally-off value.
            if UserDefaults.standard.object(forKey: key) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}
