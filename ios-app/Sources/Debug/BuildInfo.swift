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
