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
            } else if log.isEmpty && errorMessage == nil {
                Text("No access attempts recorded yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(log) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.action).font(.headline)
                    Text(record.outcome)
                        .font(.caption)
                        .foregroundStyle(record.outcome == "granted" ? .green : .orange)
                    Text(record.occurredAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
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
