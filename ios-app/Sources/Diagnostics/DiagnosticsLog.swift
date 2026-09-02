//
//  DiagnosticsLog.swift
//  VuuroScan
//
//  Mark's real-device reports so far have relied on him manually
//  screenshotting an error screen and describing what led up to it — this is
//  what lets him export the actual sequence instead. Every AppError anywhere
//  in the app logs itself here (see AppError's init), plus CaptureCoordinator
//  state transitions, RoomPlan's own real-time coaching instructions
//  (e.g. "move closer to wall"), and every ScanServiceClient request's method/
//  path/response code, so a report like his 2026-09-01 world-tracking failure
//  comes with what RoomPlan was telling him and what the network was doing
//  right before it happened, not just the final error.
//
//  #if DEBUG on the whole file, not just the call sites that use it — per
//  Mark's 2026-09-01 request ("Debug-only, no telemetry"). An earlier pass
//  built this without any DEBUG gate at all, so it (and the floating button
//  that opens it) would have compiled straight into a Release build and
//  stayed visible to a real tenant. Caught before ever shipping.
//

#if DEBUG
import Foundation

struct DiagnosticsLogEntry: Identifiable {
    enum Category: String {
        case info = "INFO"
        case error = "ERROR"
        case state = "STATE"
        case instruction = "INSTRUCTION"
        case request = "REQUEST"
    }

    let id = UUID()
    let timestamp: Date
    let category: Category
    let message: String
}

@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @Published private(set) var entries: [DiagnosticsLogEntry] = []

    // Same defensive-cap pattern as MAX_PHOTOS_PER_SESSION etc. server-side —
    // this is an in-memory, session-lifetime log (intentionally not
    // persisted; see ScanHistoryStore for why some things are and this
    // isn't), so unbounded growth is a real risk on a long test session.
    private let maxEntries = 300

    // First line of every exported log, per Mark's 2026-09-02 request: build
    // info attached automatically instead of relying on him to ask for it.
    private init() {
        record(BuildInfo.summary, category: .info)
    }

    func record(_ message: String, category: DiagnosticsLogEntry.Category) {
        entries.append(DiagnosticsLogEntry(timestamp: Date(), category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
#endif
