//
//  ScanHistoryView.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Lists scan sessions this device remembers creating (ScanHistoryStore —
//  local-only, see its header for why), with per-session floor plan
//  image/PDF download and a link to that session's access log, plus a
//  bulk "download all" action across the whole local history.
//
//  Per-session, not per-room: the Scan Service renders one PNG (rooms tiled
//  on one sheet) and one PDF (one metrics table) per session, not a separate
//  file per room — see ../../docs/adr/0002-export-coordinate-frame.md for why.
//

import SwiftUI

struct ScanHistoryView: View {
    /// LIDAR-4: see ios-app/'s copy of this file for why this exists.
    var onResumeToAddRoom: ((ScanHistoryEntry) -> Void)?

    @State private var entries: [ScanHistoryEntry] = ScanHistoryStore.shared.all()
    @State private var perEntryImageURLs: [String: URL] = [:]
    @State private var perEntryPDFURLs: [String: URL] = [:]
    @State private var bulkImageURLs: [URL] = []
    @State private var bulkPDFURLs: [URL] = []
    @State private var isBulkFetchingImages = false
    @State private var isBulkFetchingPDFs = false
    @State private var appError: AppError?
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    private let client = ScanServiceClient()

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No scans yet on this device.")
                    .font(VuuroFont.body())
                    .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
            }

            ForEach(entries) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(entry.propertyId) — \(entry.unitId)")
                            .font(VuuroFont.display(17))
                            .foregroundStyle(VuuroColor.textPrimary)
                        Text(entry.purpose.displayName)
                            .font(VuuroFont.body(13))
                            .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(VuuroFont.body(11))
                            .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                    }
                    .padding(.vertical, 2)

                    HStack {
                        Button("Download image") {
                            Task { await downloadImage(for: entry) }
                        }
                        .buttonStyle(.vuuroSecondary)
                        Spacer()
                        if let url = perEntryImageURLs[entry.sessionId] {
                            ShareLink(item: url) {
                                Label("Save", systemImage: "square.and.arrow.up")
                            }
                        }
                    }

                    HStack {
                        Button("Download PDF") {
                            Task { await downloadPDF(for: entry) }
                        }
                        .buttonStyle(.vuuroSecondary)
                        Spacer()
                        if let url = perEntryPDFURLs[entry.sessionId] {
                            ShareLink(item: url) {
                                Label("Save", systemImage: "square.and.arrow.up")
                            }
                        }
                    }

                    NavigationLink("Access log") {
                        AccessLogView(sessionId: entry.sessionId, accessToken: entry.accessToken)
                    }
                    .font(VuuroFont.body(15))
                    .foregroundStyle(VuuroColor.primary)

                    if let onResumeToAddRoom {
                        Button("Scan another room") {
                            dismiss()
                            onResumeToAddRoom(entry)
                        }
                        .buttonStyle(.vuuroSecondary)
                    }

                    // ScanHistoryStore.remove(sessionId:) already existed but
                    // was never called from anywhere in the app — ported
                    // from ios-app/'s copy of this file (2026-09), same
                    // designed-but-unwired pattern as this project's other
                    // real findings.
                    //
                    // Labeled "Forget", not "Delete" — this only removes the
                    // local ScanHistoryStore entry (see its header: there's
                    // no server-side listing to delete from, and the session
                    // itself still exists with its data intact).
                    Button("Forget this scan (device only)", role: .destructive) {
                        deleteEntry(entry)
                    }
                    .buttonStyle(.vuuroSecondary)
                }
            }

            if !entries.isEmpty {
                Section("Bulk export") {
                    Button {
                        Task { await downloadAllImages() }
                    } label: {
                        if isBulkFetchingImages {
                            ProgressView()
                        } else {
                            Text("Download all images")
                        }
                    }
                    .buttonStyle(.vuuroPrimary)
                    .disabled(isBulkFetchingImages)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if !bulkImageURLs.isEmpty {
                        ShareLink(items: bulkImageURLs) {
                            Label("Save all images", systemImage: "square.and.arrow.up.on.square")
                        }
                    }

                    Button {
                        Task { await downloadAllPDFs() }
                    } label: {
                        if isBulkFetchingPDFs {
                            ProgressView()
                        } else {
                            Text("Download all PDFs")
                        }
                    }
                    .buttonStyle(.vuuroPrimary)
                    .disabled(isBulkFetchingPDFs)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if !bulkPDFURLs.isEmpty {
                        ShareLink(items: bulkPDFURLs) {
                            Label("Save all PDFs", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                }
            }

            if let appError {
                ErrorCodeView(error: appError)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(VuuroColor.textPrimary.opacity(0.6)).font(VuuroFont.body(13))
            }
        }
        .tint(VuuroColor.primary)
        .scrollContentBackground(.hidden)
        .background(VuuroColor.surfaceMuted)
        .navigationTitle("Scan history")
        .onAppear { entries = ScanHistoryStore.shared.all() }
        .onDisappear { cleanUpTempFiles() }
    }

    // Every download below writes into the shared tmp directory, which iOS
    // doesn't clear on any predictable schedule — same lesson as
    // ResultSummaryView's cleanUpExportedFiles(). Cleaned up together here
    // since this screen can accumulate many more files than that one did.
    private func cleanUpTempFiles() {
        let all = Array(perEntryImageURLs.values) + Array(perEntryPDFURLs.values) + bulkImageURLs + bulkPDFURLs
        for url in all {
            try? FileManager.default.removeItem(at: url)
        }
        perEntryImageURLs = [:]
        perEntryPDFURLs = [:]
        bulkImageURLs = []
        bulkPDFURLs = []
    }

    @MainActor
    private func deleteEntry(_ entry: ScanHistoryEntry) {
        if let url = perEntryImageURLs[entry.sessionId] {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = perEntryPDFURLs[entry.sessionId] {
            try? FileManager.default.removeItem(at: url)
        }
        perEntryImageURLs[entry.sessionId] = nil
        perEntryPDFURLs[entry.sessionId] = nil

        // See ios-app/'s copy of this file: bulk downloads live in a flat
        // array, not keyed by session, so "Forget" left this entry's file
        // untouched there and still shareable via "Save all images/PDFs".
        let imageFilename = "floorplan-\(entry.sessionId).png"
        let pdfFilename = "floorplan-\(entry.sessionId).pdf"
        for url in bulkImageURLs where url.lastPathComponent == imageFilename {
            try? FileManager.default.removeItem(at: url)
        }
        bulkImageURLs.removeAll { $0.lastPathComponent == imageFilename }
        for url in bulkPDFURLs where url.lastPathComponent == pdfFilename {
            try? FileManager.default.removeItem(at: url)
        }
        bulkPDFURLs.removeAll { $0.lastPathComponent == pdfFilename }

        ScanHistoryStore.shared.remove(sessionId: entry.sessionId)
        entries = ScanHistoryStore.shared.all()
    }

    @MainActor
    private func downloadImage(for entry: ScanHistoryEntry) async {
        do {
            let data = try await client.fetchFloorPlanImage(sessionId: entry.sessionId, accessToken: entry.accessToken)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).png")
            try data.write(to: url)
            perEntryImageURLs[entry.sessionId] = url
            appError = nil
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func downloadPDF(for entry: ScanHistoryEntry) async {
        do {
            let data = try await client.fetchFloorPlanPDF(sessionId: entry.sessionId, accessToken: entry.accessToken)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).pdf")
            try data.write(to: url)
            perEntryPDFURLs[entry.sessionId] = url
            appError = nil
        } catch {
            appError = AppError(site: .historyPDFDownload, underlying: error)
        }
    }

    @MainActor
    private func downloadAllImages() async {
        isBulkFetchingImages = true
        defer { isBulkFetchingImages = false }
        var urls: [URL] = []
        var skipped = 0
        for entry in entries {
            do {
                let data = try await client.fetchFloorPlanImage(sessionId: entry.sessionId, accessToken: entry.accessToken)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).png")
                try data.write(to: url)
                urls.append(url)
            } catch {
                // A session with no capture yet has no image to export —
                // skip it rather than failing the whole batch over one
                // not-yet-captured session.
                skipped += 1
            }
        }
        bulkImageURLs = urls
        errorMessage = urls.isEmpty ? "No floor plan images were available to download." :
            (skipped > 0 ? "Downloaded \(urls.count) image(s); skipped \(skipped) session(s) with no capture yet." : nil)
    }

    @MainActor
    private func downloadAllPDFs() async {
        isBulkFetchingPDFs = true
        defer { isBulkFetchingPDFs = false }
        var urls: [URL] = []
        var skipped = 0
        for entry in entries {
            do {
                let data = try await client.fetchFloorPlanPDF(sessionId: entry.sessionId, accessToken: entry.accessToken)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).pdf")
                try data.write(to: url)
                urls.append(url)
            } catch {
                skipped += 1
            }
        }
        bulkPDFURLs = urls
        errorMessage = urls.isEmpty ? "No floor plan PDFs were available to download." :
            (skipped > 0 ? "Downloaded \(urls.count) PDF(s); skipped \(skipped) session(s) with no capture yet." : nil)
    }
}
