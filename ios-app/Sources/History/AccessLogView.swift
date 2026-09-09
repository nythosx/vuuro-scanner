
import SwiftUI

struct AccessLogView: View {
    let sessionId: String
    let accessToken: String

    @State private var isLoading = false
    @State private var log: [AccessLogEntry] = []
    @State private var appError: AppError?

    private let client = ScanServiceClient()

    var body: some View {
        List {
            if isLoading {
                ProgressView()
            } else if log.isEmpty && appError == nil {
                Text("No access attempts recorded yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(log) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.action).font(.headline)
                    Text(record.outcome)
                        .font(.caption)
                        .foregroundStyle(Self.isSuccessOutcome(record.outcome) ? .green : .orange)
                    Text(record.occurredAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let appError {
                ErrorCodeView(error: appError)
            }
        }
        .navigationTitle("Access log")
        .task { await load() }
    }

    private static func isSuccessOutcome(_ outcome: String) -> Bool {
        ["granted", "granted_grace_rotation", "stored"].contains(outcome)
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.fetchAccessLog(sessionId: sessionId, accessToken: accessToken)
            log = response.accessLog
            appError = nil
        } catch {
            appError = AppError(site: .accessLog, underlying: error)
        }
    }
}
