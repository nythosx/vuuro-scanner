import Foundation
import os

enum PerfSpan: String, CaseIterable {
    case launchToHome = "launch_to_home"
    case historyLoad = "history_load"
    case scanStartToReady = "scan_start_to_ready"
    case roomProcessing = "room_processing"
    case roomUpload = "room_upload"
    case resultPlanImage = "result_plan_image"
    case dollhouseBuild = "dollhouse_build"
    case usdzExport = "usdz_export"
}

enum PerfTrace {
    private static let signposter = OSSignposter(subsystem: "com.vuuro.scan", category: "Performance")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var openSpans: [PerfSpan: (start: CFAbsoluteTime, state: OSSignpostIntervalState)] = [:]

    static func begin(_ span: PerfSpan) {
        let state = signposter.beginInterval("span", id: signposter.makeSignpostID(), "\(span.rawValue, privacy: .public)")
        lock.lock()
        let replaced = openSpans.updateValue((CFAbsoluteTimeGetCurrent(), state), forKey: span)
        lock.unlock()
        if let replaced {
            signposter.endInterval("span", replaced.state, "replaced")
        }
    }

    @discardableResult
    static func end(_ span: PerfSpan, detail: String? = nil) -> Double? {
        lock.lock()
        let entry = openSpans.removeValue(forKey: span)
        lock.unlock()
        guard let entry else { return nil }
        let ms = (CFAbsoluteTimeGetCurrent() - entry.start) * 1000
        signposter.endInterval("span", entry.state, "\(span.rawValue, privacy: .public)")
        DiagnosticsLog.shared.record(message(span: span, ms: ms, detail: detail), category: .info)
        return ms
    }

    static func cancel(_ span: PerfSpan) {
        lock.lock()
        let entry = openSpans.removeValue(forKey: span)
        lock.unlock()
        if let entry {
            signposter.endInterval("span", entry.state, "cancelled")
        }
    }

    static func isOpen(_ span: PerfSpan) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openSpans[span] != nil
    }

    static func message(span: PerfSpan, ms: Double, detail: String?) -> String {
        let base = "PERF \(span.rawValue) \(Int(ms.rounded())) ms"
        guard let detail, !detail.isEmpty else { return base }
        return base + " (\(detail))"
    }
}
