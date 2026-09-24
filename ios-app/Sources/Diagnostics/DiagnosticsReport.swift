import Foundation
import UIKit

enum DiagnosticsReport {
    @MainActor
    static func build(entries: [DiagnosticsLogEntry], historyEntries: [ScanHistoryEntry], now: Date = Date()) -> String {
        let client = ScanServiceClient()
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let device = UIDevice.current
        let timestamp = ISO8601DateFormatter().string(from: now)

        var lines: [String] = []
        lines.append("Vuuro Scan diagnostics")
        lines.append("Generated: \(timestamp)")
        lines.append("")
        lines.append("== Build ==")
        lines.append("App version: \(version) (\(build))")
        lines.append("Commit: \(BuildInfo.commitSHA)")
        lines.append("Built: \(BuildInfo.buildTimestamp)")
        #if DEBUG
        lines.append("Configuration: Debug")
        #else
        lines.append("Configuration: Release")
        #endif
        lines.append("")
        lines.append("== Device ==")
        lines.append("Model: \(modelIdentifier()) (\(device.model))")
        lines.append("System: \(device.systemName) \(device.systemVersion)")
        lines.append("LiDAR / RoomPlan: \(DeviceCapability.isRoomPlanSupported ? "supported" : "not supported")")
        lines.append("Locale: \(Locale.current.identifier), app language: \(AppLanguageSettings.effectiveLocale.identifier)")
        lines.append("Time zone: \(TimeZone.current.identifier)")
        lines.append("Free storage: \(freeStorageDescription())")
        lines.append("")
        lines.append("== Network ==")
        lines.append("Connected: \(NetworkMonitor.shared.isConnected ? "yes" : "no")")
        lines.append("Scan Service: \(client.baseURL.absoluteString)\(client.isConfigured ? "" : " (not configured)")")
        lines.append("")
        lines.append("== Local data ==")
        lines.append("Scans in history: \(historyEntries.count)")
        lines.append("")

        let errors = entries.filter { $0.category == .error }
        lines.append("== Errors (\(errors.count)) ==")
        if errors.isEmpty {
            lines.append("None logged.")
        } else {
            lines.append(contentsOf: errors.map(format))
        }
        lines.append("")

        let requests = entries.filter { $0.category == .request }
        lines.append("== Network requests (\(requests.count)) ==")
        if requests.isEmpty {
            lines.append("None logged.")
        } else {
            lines.append(contentsOf: requests.map(format))
        }
        lines.append("")

        lines.append("== Full activity log (\(entries.count)) ==")
        lines.append(contentsOf: entries.map(format))

        let secrets = historyEntries.map(\.accessToken).filter { !$0.isEmpty }
        return DiagnosticsRedactor.redact(lines.joined(separator: "\n"), secrets: secrets)
    }

    @MainActor
    static func writeFile(entries: [DiagnosticsLogEntry], historyEntries: [ScanHistoryEntry]) throws -> URL {
        let now = Date()
        let text = build(entries: entries, historyEntries: historyEntries, now: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vuuro-scan-diagnostics_\(formatter.string(from: now)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func format(_ entry: DiagnosticsLogEntry) -> String {
        "[\(ISO8601DateFormatter().string(from: entry.timestamp))] \(entry.category.rawValue): \(entry.message)"
    }

    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    private static func freeStorageDescription() -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return "unknown"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
