import Foundation
import RoomPlan

enum CaptureErrorText {
    static func message(for error: Error, partialAvailable: Bool, isUnitScan: Bool) -> String {
        let nsError = error as NSError
        DiagnosticsLog.shared.record("Capture ended with error \(type(of: error)) \(String(describing: error)) [\(nsError.domain) \(nsError.code)]: \(nsError.localizedDescription)", category: .error)
        if isWorldTrackingFailure(error) {
            let reason = vuuroLocalized("The scan stopped because the phone lost track of the room. This happens when the app goes to the background, a call comes in, the screen locks, or the camera is covered or in the dark. Keep Vuuro Scan open and on screen while you scan.")
            return partialAvailable ? reason + " " + vuuroLocalized("You can save what was captured and scan the rest as a new room.") : reason
        }
        if case RoomCaptureSession.CaptureError.exceedSceneSizeLimit = error {
            if isUnitScan {
                return partialAvailable
                    ? vuuroLocalized("This unit has grown too large to track in one scan. Save what's captured so far, then start a new unit scan for the remaining rooms.")
                    : vuuroLocalized("This unit has grown too large to track in one scan. Start a new unit scan for the remaining rooms.")
            }
            return partialAvailable
                ? vuuroLocalized("This space is too large to scan in one go. Save what's captured, then scan the rest as a separate room.")
                : vuuroLocalized("This space is too large to scan in one go. Try scanning it as two smaller parts.")
        }
        let reason = vuuroLocalized("The scan stopped unexpectedly. Keep Vuuro Scan open and on screen, make sure the room is well lit, and try again.")
        return partialAvailable ? reason + " " + vuuroLocalized("You can save what was captured and scan the rest as a new room.") : reason
    }

    private static func isWorldTrackingFailure(_ error: Error) -> Bool {
        if case RoomCaptureSession.CaptureError.worldTrackingFailure = error {
            return true
        }
        return (error as NSError).localizedDescription.lowercased().contains("world tracking")
    }
}
