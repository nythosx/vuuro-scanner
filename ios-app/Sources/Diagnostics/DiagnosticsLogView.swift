

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
                        Label("Export", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            .onAppear { refreshExport() }
            .onChange(of: log.entries.count) { _, _ in refreshExport() }
            .onDisappear { cleanUpExport() }
        }
    }

    @MainActor
    private func refreshExport() {
        guard !log.entries.isEmpty else {
            cleanUpExport()
            return
        }
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
