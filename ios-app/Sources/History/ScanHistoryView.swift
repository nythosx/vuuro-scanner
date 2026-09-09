
import SwiftUI

struct ScanHistoryView: View {
    var onResumeToAddRoom: ((ScanHistoryEntry) -> Void)?
    var onAttachToSession: ((ScanHistoryEntry, FloorPlan) -> Void)?

    @State private var entries: [ScanHistoryEntry] = ScanHistoryStore.shared.all()
    @State private var isFetchingToAttach: Set<String> = []
    @State private var attachErrors: [String: AppError] = [:]
    @State private var perEntryImageURLs: [String: URL] = [:]
    @State private var perEntryPDFURLs: [String: URL] = [:]
    @State private var bulkImageURLs: [URL] = []
    @State private var bulkPDFURLs: [URL] = []
    @State private var isBulkFetchingImages = false
    @State private var isBulkFetchingPDFs = false
    @State private var appError: AppError?
    @State private var errorMessage: String?
    @State private var pendingDeleteEntry: ScanHistoryEntry?
    @State private var pendingServerDeleteEntry: ScanHistoryEntry?
    @State private var showImportSheet = false
    @State private var importCode = ""
    @State private var importError: String?
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue
    @FocusState private var focusedNicknameSessionId: String?

    @Environment(\.dismiss) private var dismiss

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private func nicknameBinding(for entry: ScanHistoryEntry) -> Binding<String> {
        Binding(
            get: { entry.nickname ?? "" },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.sessionId == entry.sessionId }) else { return }
                entries[index].nickname = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func commitNickname(sessionId: String) {
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        let trimmed = entries[index].nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (trimmed?.isEmpty ?? true) ? nil : trimmed
        entries[index].nickname = stored
        ScanHistoryStore.shared.updateNickname(sessionId: sessionId, nickname: stored)
    }

    private func reloadEntries() {
        if let focusedNicknameSessionId {
            commitNickname(sessionId: focusedNicknameSessionId)
        }
        entries = ScanHistoryStore.shared.all()
    }

    private let client = ScanServiceClient()

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No scans yet on this device.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Add a scan someone shared with you") {
                    importCode = ""
                    importError = nil
                    showImportSheet = true
                }
            }

            Section("Export unit") {
                Picker("Measurement unit", selection: $exportUnitRaw) {
                    ForEach(MeasurementUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit.rawValue)
                    }
                }
            }

            ForEach(entries) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.nickname?.isEmpty == false ? entry.nickname! : "\(entry.propertyId) — \(entry.unitId)").font(.headline)
                        TextField("Label this scan (optional)", text: nicknameBinding(for: entry))
                            .font(.caption)
                            .focused($focusedNicknameSessionId, equals: entry.sessionId)
                            .onSubmit { commitNickname(sessionId: entry.sessionId) }
                        Text(entry.purpose.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Download image") {
                            Task { await downloadImage(for: entry) }
                        }
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

                    if let onResumeToAddRoom {
                        Button("Scan another room") {
                            Task {
                                let refreshed = await rotateTokenIfNeeded(entry)
                                dismiss()
                                onResumeToAddRoom(refreshed)
                            }
                        }
                    }

                    if let onAttachToSession {
                        Button {
                            Task {
                                let refreshed = await rotateTokenIfNeeded(entry)
                                await attach(refreshed, using: onAttachToSession)
                            }
                        } label: {
                            if isFetchingToAttach.contains(entry.sessionId) {
                                ProgressView()
                            } else {
                                Text("Add a photo or note")
                            }
                        }
                        .disabled(isFetchingToAttach.contains(entry.sessionId))

                        if let attachError = attachErrors[entry.sessionId] {
                            ErrorCodeView(error: attachError)
                                .font(.caption)
                        }
                    }

                    if let code = ScanShareCode.encode(entry) {
                        VStack(alignment: .leading, spacing: 2) {
                            ShareLink(item: code) {
                                Label("Share access with someone else", systemImage: "person.badge.plus")
                            }
                            Text("Anyone who receives this code gets full access to this scan — view, export, and delete. Only send it somewhere secure.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Forget this scan (device only)", role: .destructive) {
                        pendingDeleteEntry = entry
                    }

                    Divider()

                    Button(role: .destructive) {
                        pendingServerDeleteEntry = entry
                    } label: {
                        Label("Delete permanently from server", systemImage: "exclamationmark.triangle.fill")
                    }
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
                    .disabled(isBulkFetchingImages)

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
                    .disabled(isBulkFetchingPDFs)

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
                Text(errorMessage).foregroundStyle(.secondary).font(.caption)
            }
        }
        .navigationTitle("Scan history")
        .onAppear { reloadEntries() }
        .onDisappear {
            if let focusedNicknameSessionId {
                commitNickname(sessionId: focusedNicknameSessionId)
            }
            cleanUpTempFiles()
        }
        .onChange(of: focusedNicknameSessionId) { oldValue, _ in
            if let oldValue {
                commitNickname(sessionId: oldValue)
            }
        }
        .alert("Forget this scan?", isPresented: Binding(
            get: { pendingDeleteEntry != nil },
            set: { if !$0 { pendingDeleteEntry = nil } }
        )) {
            Button("Forget", role: .destructive) {
                if let pendingDeleteEntry {
                    deleteEntry(pendingDeleteEntry)
                }
                pendingDeleteEntry = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteEntry = nil }
        } message: {
            Text("This removes the local record on this device only — the session data itself isn't deleted, but you won't be able to reopen it from History again.")
        }
        .alert("Delete this scan from the server?", isPresented: Binding(
            get: { pendingServerDeleteEntry != nil },
            set: { if !$0 { pendingServerDeleteEntry = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pendingServerDeleteEntry {
                    Task { await deleteFromServer(pendingServerDeleteEntry) }
                }
                pendingServerDeleteEntry = nil
            }
            Button("Cancel", role: .cancel) { pendingServerDeleteEntry = nil }
        } message: {
            Text("This permanently deletes the session's rooms, photos, and notes from the Scan Service. This cannot be undone.")
        }
        .sheet(isPresented: $showImportSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $importCode)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 120)
                    } header: {
                        Text("Paste the code")
                    } footer: {
                        Text("Ask the other person to open this scan in their own History, tap \"Share access with someone else\", and send you the code.")
                    }
                    if let importError {
                        Text(importError).foregroundStyle(.red).font(.caption)
                    }
                    Section {
                        Button("Add this scan") { importScan() }
                            .disabled(importCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("Add a shared scan")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showImportSheet = false }
                    }
                }
            }
        }
    }

    private func importScan() {
        guard let decoded = ScanShareCode.decode(importCode) else {
            importError = "That code doesn't look right — check that you copied the whole thing."
            return
        }
        ScanHistoryStore.shared.add(decoded)
        reloadEntries()
        showImportSheet = false
    }

    @MainActor
    private func deleteFromServer(_ entry: ScanHistoryEntry) async {
        let entry = await rotateTokenIfNeeded(entry)
        do {
            try await client.deleteSession(sessionId: entry.sessionId, accessToken: entry.accessToken)
            #if DEBUG
            DiagnosticsLog.shared.record("Session \(entry.sessionId) deleted from server", category: .info)
            #endif
            appError = nil
            deleteEntry(entry)
        } catch {
            appError = AppError(site: .historyServerDelete, underlying: error)
        }
    }

    // A resumed/attached session's stored token can be close to (or past) its
    // 90-day expiry with no other path to renew it (see AppError.swift's
    // header and ScanSessionRepository.php's ROTATE_GRACE_PERIOD_SECONDS) —
    // this device never proactively rotates otherwise, so the only chance is
    // right before the token is actually used again.
    @MainActor
    private func rotateTokenIfNeeded(_ entry: ScanHistoryEntry) async -> ScanHistoryEntry {
        if let expiresAtString = entry.expiresAt, !expiresAtString.isEmpty,
           let expiresAt = ISO8601DateFormatter().date(from: expiresAtString),
           expiresAt.timeIntervalSinceNow >= 14 * 24 * 60 * 60 {
            #if DEBUG
            DiagnosticsLog.shared.record("Token rotation skipped for session \(entry.sessionId): still valid until \(expiresAtString)", category: .info)
            #endif
            return entry
        }
        do {
            let rotated = try await client.rotateToken(sessionId: entry.sessionId, accessToken: entry.accessToken)
            #if DEBUG
            DiagnosticsLog.shared.record("Token rotated for session \(entry.sessionId), new expiry \(rotated.expiresAt)", category: .info)
            #endif
            let updated = ScanHistoryEntry(
                sessionId: entry.sessionId,
                accessToken: rotated.accessToken,
                propertyId: entry.propertyId,
                unitId: entry.unitId,
                organisationId: entry.organisationId,
                purpose: entry.purpose,
                createdAt: entry.createdAt,
                expiresAt: rotated.expiresAt,
                nickname: entry.nickname
            )
            ScanHistoryStore.shared.add(updated)
            reloadEntries()
            return updated
        } catch {
            #if DEBUG
            DiagnosticsLog.shared.record("Token rotation failed for session \(entry.sessionId): \(error.localizedDescription)", category: .error)
            #endif
            return entry
        }
    }

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
        attachErrors[entry.sessionId] = nil
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
        reloadEntries()
    }

    @MainActor
    private func attach(_ entry: ScanHistoryEntry, using onAttachToSession: (ScanHistoryEntry, FloorPlan) -> Void) async {
        isFetchingToAttach.insert(entry.sessionId)
        defer { isFetchingToAttach.remove(entry.sessionId) }
        do {
            let floorPlan = try await client.fetchSession(sessionId: entry.sessionId, accessToken: entry.accessToken)
            attachErrors[entry.sessionId] = nil
            dismiss()
            onAttachToSession(entry, floorPlan)
        } catch {
            attachErrors[entry.sessionId] = AppError(site: .historySessionFetch, underlying: error)
        }
    }

    @MainActor
    private func downloadImage(for entry: ScanHistoryEntry) async {
        do {
            let data = try await client.fetchFloorPlanImage(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
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
            let data = try await client.fetchFloorPlanPDF(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
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
                let data = try await client.fetchFloorPlanImage(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).png")
                try data.write(to: url)
                urls.append(url)
            } catch {
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
                let data = try await client.fetchFloorPlanPDF(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
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
