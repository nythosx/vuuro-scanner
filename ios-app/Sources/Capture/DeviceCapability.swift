
import RoomPlan

enum DeviceCapability {

    static var isRoomPlanSupported: Bool {
        RoomCaptureSession.isSupported
    }

    static var unsupportedReason: String {
        if isRoomPlanSupported {
            return ""
        }
        return "This device doesn't have the LiDAR sensor Vuuro Scan's guided room capture needs. " +
            "Scanning is available on iPhone 12 Pro or newer Pro models, and iPad Pro (2020 or newer)."
    }
}
