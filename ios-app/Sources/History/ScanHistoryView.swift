
import SwiftUI

struct ScanHistoryView: View {
    var onResumeToAddRoom: ((ScanHistoryEntry) -> Void)?
    var onAttachToSession: ((ScanHistoryEntry, FloorPlan) -> Void)?

    @State private var entries: [ScanHistoryEntry] = []
    @State private var isLoadingEntries = true
    @State private var isFetchingToAttach: Set<String> = []
    @State private var isDownloadingImage: Set<String> = []
    @State private var isDownloadingPDF: Set<String> = []
    @State private var isPreparingQuickShare: Set<String> = []
    @State private var quickShareURL: URL?
    @State private var shareCodeSource: ShareCodeItemSource?
    @State private var showQuickShare = false
    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
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
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                ScanHistoryStore.shared.all()
            }.value
            entries = loaded
            isLoadingEntries = false
        }
    }

    private let client = ScanServiceClient()

    var body: some View {
        List {
            if isLoadingEntries {
                ForEach(0..<3, id: \.self) { _ in
                    HistoryRowSkeleton()
                }
            } else if entries.isEmpty {
                Text("No scans yet on this device.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Add a scan someone shared with you") {
                    importCode = ""
                    importError = nil
                    showImportSheet = true
                }
                .buttonStyle(.vuuroSecondary)
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
                        if let onAttachToSession {
                            NavigationLink {
                                SessionGalleryView(entry: entry) { editEntry, editFloorPlan in
                                    Task {
                                        await editFromGallery(editEntry, editFloorPlan, using: onAttachToSession)
                                    }
                                }
                            } label: {
                                Text(entry.nickname?.isEmpty == false ? entry.nickname! : "\(entry.propertyId) — \(entry.unitId)")
                                    .font(.headline)
                                    .foregroundStyle(VuuroColor.textPrimary)
                            }
                        } else {
                            Text(entry.nickname?.isEmpty == false ? entry.nickname! : "\(entry.propertyId) — \(entry.unitId)").font(.headline)
                        }
                        TextField("Label this scan (optional)", text: nicknameBinding(for: entry))
                            .font(.caption)
                            .focused($focusedNicknameSessionId, equals: entry.sessionId)
                            .onSubmit {
                                commitNickname(sessionId: entry.sessionId)
                                VuuroToast.shared.show("Nickname saved")
                            }
                        if let roomSummary = entry.cachedRoomSummary, !roomSummary.isEmpty {
                            Text(roomSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.purpose.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await viewFile(for: entry, pdf: false) }
                        } label: {
                            if isDownloadingImage.contains(entry.sessionId) {
                                ProgressView()
                            } else {
                                Text("View image")
                            }
                        }
                        .buttonStyle(.vuuroSecondary)
                        .disabled(isDownloadingImage.contains(entry.sessionId))
                        Button {
                            Task { await viewFile(for: entry, pdf: true) }
                        } label: {
                            if isDownloadingPDF.contains(entry.sessionId) {
                                ProgressView()
                            } else {
                                Text("View PDF")
                            }
                        }
                        .buttonStyle(.vuuroSecondary)
                        .disabled(isDownloadingPDF.contains(entry.sessionId))
                    }

                    NavigationLink("Access log") {
                        AccessLogView(sessionId: entry.sessionId, accessToken: entry.accessToken)
                    }

                    HStack(spacing: 10) {
                        if let onResumeToAddRoom {
                            Button("Scan another room") {
                                Task {
                                    let refreshed = await rotateTokenIfNeeded(entry)
                                    cleanUpTempFiles()
                                    dismiss()
                                    onResumeToAddRoom(refreshed)
                                }
                            }
                            .buttonStyle(.vuuroSecondary)
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
                            .buttonStyle(.vuuroSecondary)
                            .disabled(isFetchingToAttach.contains(entry.sessionId))
                        }
                    }

                    if onAttachToSession != nil, let attachError = attachErrors[entry.sessionId] {
                        ErrorCodeView(error: attachError)
                            .font(.caption)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await shareFile(for: entry, pdf: false) }
                        } label: {
                            if isPreparingQuickShare.contains(entry.sessionId + ":image") {
                                ProgressView()
                            } else {
                                Label("Share image", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.vuuroSecondary)
                        .disabled(isPreparingQuickShare.contains(entry.sessionId + ":image"))
                        Button {
                            Task { await shareFile(for: entry, pdf: true) }
                        } label: {
                            if isPreparingQuickShare.contains(entry.sessionId + ":pdf") {
                                ProgressView()
                            } else {
                                Label("Share PDF", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.vuuroSecondary)
                        .disabled(isPreparingQuickShare.contains(entry.sessionId + ":pdf"))
                    }

                    if let code = ScanShareCode.encode(entry) {
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                quickShareURL = nil
                                shareCodeSource = ShareCodeItemSource(
                                    code: code,
                                    subject: "Vuuro Scan access — \(entry.propertyId) / \(entry.unitId)",
                                    messageBody: "Paste this code into Vuuro Scan, under History → \"Add a scan someone shared with you\", to get full access to this scan (view, export, delete). Only share it with someone you trust."
                                )
                                showQuickShare = true
                            } label: {
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
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("New scan", systemImage: "chevron.backward")
                }
            }
        }
        .onAppear { reloadEntries() }
        .onDisappear {
            if let focusedNicknameSessionId {
                commitNickname(sessionId: focusedNicknameSessionId)
            }
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
        .sheet(isPresented: $showQuickShare) {
            if let shareCodeSource {
                ActivityShareSheet(items: [shareCodeSource])
            } else if let quickShareURL {
                ActivityShareSheet(items: [quickShareURL])
            }
        }
        .fullScreenCover(isPresented: $showQuickLook) {
            if let quickLookURL {
                QuickLookPreview(url: quickLookURL)
                    .ignoresSafeArea()
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
            DiagnosticsLog.shared.record("Session \(entry.sessionId) deleted from server", category: .info)
            appError = nil
            deleteEntry(entry)
        } catch {
            appError = AppError(site: .historyServerDelete, underlying: error)
        }
    }

    @MainActor
    private func rotateTokenIfNeeded(_ entry: ScanHistoryEntry) async -> ScanHistoryEntry {
        if let expiresAtString = entry.expiresAt, !expiresAtString.isEmpty,
           let expiresAt = ISO8601DateFormatter().date(from: expiresAtString),
           expiresAt.timeIntervalSinceNow >= 14 * 24 * 60 * 60 {
            DiagnosticsLog.shared.record("Token rotation skipped for session \(entry.sessionId): still valid until \(expiresAtString)", category: .info)
            return entry
        }
        do {
            let rotated = try await client.rotateToken(sessionId: entry.sessionId, accessToken: entry.accessToken)
            DiagnosticsLog.shared.record("Token rotated for session \(entry.sessionId), new expiry \(rotated.expiresAt)", category: .info)
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
            DiagnosticsLog.shared.record("Token rotation failed for session \(entry.sessionId): \(error.localizedDescription)", category: .error)
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
    private func editFromGallery(_ entry: ScanHistoryEntry, _ floorPlan: FloorPlan, using onAttachToSession: (ScanHistoryEntry, FloorPlan) -> Void) async {
        await Task.yield()
        let refreshed = await rotateTokenIfNeeded(entry)
        cleanUpTempFiles()
        dismiss()
        onAttachToSession(refreshed, floorPlan)
    }

    @MainActor
    private func attach(_ entry: ScanHistoryEntry, using onAttachToSession: (ScanHistoryEntry, FloorPlan) -> Void) async {
        isFetchingToAttach.insert(entry.sessionId)
        defer { isFetchingToAttach.remove(entry.sessionId) }
        do {
            let floorPlan = try await client.fetchSession(sessionId: entry.sessionId, accessToken: entry.accessToken)
            attachErrors[entry.sessionId] = nil
            cleanUpTempFiles()
            dismiss()
            onAttachToSession(entry, floorPlan)
        } catch {
            attachErrors[entry.sessionId] = AppError(site: .historySessionFetch, underlying: error)
        }
    }

    @MainActor
    private func viewFile(for entry: ScanHistoryEntry, pdf: Bool) async {
        if pdf, perEntryPDFURLs[entry.sessionId] == nil {
            await downloadPDF(for: entry)
        } else if !pdf, perEntryImageURLs[entry.sessionId] == nil {
            await downloadImage(for: entry)
        }
        let url = pdf ? perEntryPDFURLs[entry.sessionId] : perEntryImageURLs[entry.sessionId]
        guard let url else { return }
        quickLookURL = url
        showQuickLook = true
    }

    @MainActor
    private func shareFile(for entry: ScanHistoryEntry, pdf: Bool) async {
        let shareKey = entry.sessionId + (pdf ? ":pdf" : ":image")
        guard !isPreparingQuickShare.contains(shareKey) else { return }
        isPreparingQuickShare.insert(shareKey)
        defer { isPreparingQuickShare.remove(shareKey) }

        if pdf, perEntryPDFURLs[entry.sessionId] == nil {
            await downloadPDF(for: entry)
        } else if !pdf, perEntryImageURLs[entry.sessionId] == nil {
            await downloadImage(for: entry)
        }

        let url = pdf ? perEntryPDFURLs[entry.sessionId] : perEntryImageURLs[entry.sessionId]
        guard let url else { return }
        shareCodeSource = nil
        quickShareURL = url
        showQuickShare = true
    }

    @MainActor
    private func downloadImage(for entry: ScanHistoryEntry) async {
        guard !isDownloadingImage.contains(entry.sessionId) else { return }
        isDownloadingImage.insert(entry.sessionId)
        defer { isDownloadingImage.remove(entry.sessionId) }
        do {
            let data = try await client.fetchFloorPlanImage(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).png")
            try data.write(to: url)
            perEntryImageURLs[entry.sessionId] = url
            appError = nil
            VuuroToast.shared.show("Image downloaded")
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func downloadPDF(for entry: ScanHistoryEntry) async {
        guard !isDownloadingPDF.contains(entry.sessionId) else { return }
        isDownloadingPDF.insert(entry.sessionId)
        defer { isDownloadingPDF.remove(entry.sessionId) }
        do {
            let data = try await client.fetchFloorPlanPDF(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).pdf")
            try data.write(to: url)
            perEntryPDFURLs[entry.sessionId] = url
            appError = nil
            VuuroToast.shared.show("PDF downloaded")
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
                DiagnosticsLog.shared.record("Bulk image download skipped session \(entry.sessionId): \(error.localizedDescription)", category: .error)
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
                DiagnosticsLog.shared.record("Bulk PDF download skipped session \(entry.sessionId): \(error.localizedDescription)", category: .error)
            }
        }
        bulkPDFURLs = urls
        errorMessage = urls.isEmpty ? "No floor plan PDFs were available to download." :
            (skipped > 0 ? "Downloaded \(urls.count) PDF(s); skipped \(skipped) session(s) with no capture yet." : nil)
    }
}

private struct HistoryRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Property — Unit").font(.headline)
            Text("Purpose").font(.subheadline).foregroundStyle(.secondary)
            Text("Jan 1, 2026 at 12:00 PM").font(.caption).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
