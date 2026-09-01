//
//  DiagnosticsLog.swift
//  VuuroScan
//
//  Mark's real-device reports so far have relied on him manually
//  screenshotting an error screen and describing what led up to it — this is
//  what lets him export the actual sequence instead. Every AppError anywhere
//  in the app logs itself here (see AppError's init), plus CaptureCoordinator
//  state transitions and RoomPlan's own real-time coaching instructions
//  (e.g. "move closer to wall"), so a report like his 2026-09-01 world-
//  tracking failure comes with what RoomPlan was telling him right before it
//  happened, not just the final error.
//

import Foundation

struct DiagnosticsLogEntry: Identifiable {
    enum Category: String {
        case error = "ERROR"
        case state = "STATE"
        case instruction = "INSTRUCTION"
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

    private init() {}

    func record(_ message: String, category: DiagnosticsLogEntry.Category) {
        entries.append(DiagnosticsLogEntry(timestamp: Date(), category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
