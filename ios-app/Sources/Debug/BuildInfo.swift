
import Foundation

enum BuildInfo {
    static var commitSHA: String {
        Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String ?? "unknown"
    }

    static var buildTimestamp: String {
        Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String ?? "unknown"
    }

    static var scanServiceBaseURL: String {
        let client = ScanServiceClient()
        return client.isConfigured ? client.baseURL.absoluteString : "Scan Service not configured"
    }

    static var summary: String {
        "\(commitSHA) · built \(buildTimestamp) · \(scanServiceBaseURL)"
    }
}
