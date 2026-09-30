#if DEBUG
import Foundation

enum DebugScanServiceURL {
    static var resolved: URL? {
        if let raw = ProcessInfo.processInfo.environment["SCAN_SERVICE_BASE_URL"], let url = URL(string: raw) {
            return url
        }
        if let raw = UserDefaults.standard.string(forKey: "SCAN_SERVICE_BASE_URL"), !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return fallback.flatMap(URL.init(string:))
    }

    #if targetEnvironment(simulator)
    private static let fallback: String? = "https://vuuroscan-joven.loca.lt"
    #else
    private static let fallback: String? = nil
    #endif
}
#endif
