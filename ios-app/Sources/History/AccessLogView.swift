//
//  AccessLogView.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Surfaces GET /scan-sessions/{id}/access-log for one session — the same
//  audit trail the web-viewer already exercises (../../web-viewer/), now
//  reachable from the app itself instead of only from that dev tool.
//

import SwiftUI

struct AccessLogView: View {
    let sessionId: String
    let accessToken: String

    @State private var isLoading = false
    @State private var log: [AccessLogEntry] = []
    @State private var errorMessage: String?

    private let client = ScanServiceClient()

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .tint(VuuroColor.primary)
            } else if log.isEmpty && errorMessage == nil {
                Text("No access attempts recorded yet.")
                    .font(VuuroFont.body())
                    .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
            }

            ForEach(log) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.action)
                        .font(VuuroFont.display(15))
                        .foregroundStyle(VuuroColor.textPrimary)
                    Text(record.outcome)
                        .font(VuuroFont.body(12))
                        // accentLime reads poorly as text (see ResultSummaryView's
                        // own quality-score color note) — granted stays neutral,
                        // only a denied attempt gets called out.
                        .foregroundStyle(record.outcome == "granted" ? VuuroColor.textPrimary.opacity(0.6) : VuuroColor.danger)
                    Text(record.occurredAt)
                        .font(VuuroFont.body(11))
                        .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                }
                .padding(.vertical, 2)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(VuuroColor.danger).font(VuuroFont.body(13))
            }
        }
        .tint(VuuroColor.primary)
        .scrollContentBackground(.hidden)
        .background(VuuroColor.surfaceMuted)
        .navigationTitle("Access log")
        .task { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.fetchAccessLog(sessionId: sessionId, accessToken: accessToken)
            log = response.accessLog
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the access log: \(error.localizedDescription)"
        }
    }
}
