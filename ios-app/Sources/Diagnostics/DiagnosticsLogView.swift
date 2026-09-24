import SwiftUI

struct DiagnosticsLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var exportURL: URL?
    @State private var exportFailed = false

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("No activity logged yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                    Text("\(entry.category.rawValue) · \(entry.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLanguageSettings.effectiveLocale)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Activity log")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
                .accessibilityIdentifier("diagnostics.done")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VuuroColor.accent)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("diagnostics.share")
                } else {
                    Label(exportFailed ? "Export failed" : "Export", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { refreshExport() }
        .onChange(of: log.entries.count) { _, _ in refreshExport() }
        .onDisappear { cleanUpExport() }
    }

    @MainActor
    private func refreshExport() {
        cleanUpExport()
        do {
            exportURL = try DiagnosticsReport.writeFile(
                entries: log.entries,
                historyEntries: ScanHistoryStore.shared.all()
            )
            exportFailed = false
        } catch {
            exportFailed = true
        }
    }

    private func cleanUpExport() {
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL)
        }
        exportURL = nil
    }
}