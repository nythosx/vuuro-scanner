

#if DEBUG
import Foundation

enum FakeLidarMode {
    static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["FAKE_LIDAR_MODE"] {
            return raw == "1" || raw.lowercased() == "true"
        }
        return fallback
    }

    private static let fallback = true
}
#endif
