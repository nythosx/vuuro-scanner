//
//  DiagnosticsLogView.swift
//  VuuroScan
//
//  Toggled from the floating button in ScanFlowView. Shows DiagnosticsLog's
//  entries newest-first and exports them as a plain-text file through the
//  standard share sheet — same "one-tap copy details, exactly as generated,
//  no retyping it by hand" principle as ErrorCodeView, extended from one
//  error to the whole session's activity.
//

import SwiftUI

struct DiagnosticsLogView: View {
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if log.entries.isEmpty {
                    Text("No activity logged yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                        Text("\(entry.category.rawValue) · \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Activity log")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            prepareExport()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(log.entries.isEmpty)
                    }
                }
            }
            // Same lesson as every other export in this app (ResultSummaryView,
            // ScanHistoryView): the tmp file this writes doesn't get cleared by
            // iOS on any predictable schedule, so it's cleaned up on dismiss.
            .onDisappear { cleanUpExport() }
        }
    }

    @MainActor
    private func prepareExport() {
        let formatted = log.entries.map { entry in
            "[\(entry.timestamp.formatted(date: .abbreviated, time: .standard))] \(entry.category.rawValue): \(entry.message)"
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vuuro-scan-activity-log.txt")
        try? formatted.write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
    }

    private func cleanUpExport() {
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL)
        }
        exportURL = nil
    }
}
