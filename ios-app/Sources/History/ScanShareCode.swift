import Foundation

enum ScanShareCode {
    private static let prefix = "VUURO-SCAN-1:"

    static func encode(_ entry: ScanHistoryEntry) -> String? {
        guard let data = try? JSONEncoder().encode(entry) else { return nil }
        return prefix + data.base64EncodedString()
    }

    static func decode(_ code: String) -> ScanHistoryEntry? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefixRange = trimmed.range(of: prefix) else { return nil }
        let afterPrefix = trimmed[prefixRange.upperBound...]
        let base64 = afterPrefix.components(separatedBy: .whitespacesAndNewlines).first ?? ""
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(ScanHistoryEntry.self, from: data)
    }
}
