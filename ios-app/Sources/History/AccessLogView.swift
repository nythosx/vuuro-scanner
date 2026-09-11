
import SwiftUI

struct AccessLogView: View {
    let sessionId: String
    let accessToken: String

    @State private var isLoading = false
    @State private var log: [AccessLogEntry] = []
    @State private var appError: AppError?

    @Environment(\.dismiss) private var dismiss

    private let client = ScanServiceClient()

    var body: some View {
        ScrollView {
            VStack(spacing: VuuroMetrics.contentSpacing) {
                if isLoading {
                    ProgressView()
                        .padding()
                } else if log.isEmpty && appError == nil {
                    Text("No access attempts recorded yet.")
                        .font(VuuroFont.body(13))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(log) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.action)
                                        .font(VuuroFont.body(14.5, weight: .semibold))
                                        .foregroundStyle(VuuroColor.textPrimary)
                                    Text(record.occurredAt)
                                        .font(VuuroFont.body(12))
                                        .foregroundStyle(VuuroColor.textSecondary)
                                }
                                Spacer()
                                VuuroBadge(record.outcome, style: Self.isSuccessOutcome(record.outcome) ? .good : .warning)
                            }
                            .padding(.vertical, 10)
                            if record.id != log.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .vuuroCard()
                }

                if let appError {
                    ErrorCodeView(error: appError)
                }
            }
            .padding()
        }
        .background(VuuroColor.surfaceMuted)
        .navigationTitle("Access log")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
        }
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
