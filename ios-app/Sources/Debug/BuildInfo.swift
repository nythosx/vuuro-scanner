
import Foundation

enum BuildInfo {
    static var commitSHA: String {
        Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String ?? "unknown"
    }

    static var buildTimestamp: String {
        Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String ?? "unknown"
    }

    static var scanServiceBaseURL: String {
        #if DEBUG
        return DebugScanServiceURL.resolved?.absoluteString ?? "http://127.0.0.1:8089"
        #else
        return "http://127.0.0.1:8089"
        #endif
    }

    static var summary: String {
        "\(commitSHA) · built \(buildTimestamp) · \(scanServiceBaseURL)"
    }
}
