#if DEBUG
import Foundation

enum DebugScanServiceURL {
    static var resolved: URL? {
        if let raw = ProcessInfo.processInfo.environment["SCAN_SERVICE_BASE_URL"], let url = URL(string: raw) {
            return url
        }
        return fallback.flatMap(URL.init(string:))
    }

    private static let fallback: String? = "https://clean-monkeys-melt.loca.lt"
}
#endif
