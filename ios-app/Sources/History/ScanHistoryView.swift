import SwiftUI

struct ScanHistoryView: View {
    var onResumeToAddRoom: ((ScanHistoryEntry) -> Void)?
    var onAttachToSession: ((ScanHistoryEntry, FloorPlan) -> Void)?
    var onStartScan: (() -> Void)?

    @State private var entries: [ScanHistoryEntry] = []
    @State private var isLoadingEntries = true
    @State private var reloadToken = UUID()
    @State private var searchText = ""
    @State private var selectedFilter: HistoryFilter = .all

    @State private var selectedEntryForReport: ScanHistoryEntry?
    @State private var pendingDeleteEntry: ScanHistoryEntry?
    @State private var pendingServerDeleteEntry: ScanHistoryEntry?
    @State private var renameEntry: ScanHistoryEntry?
    @State private var renameDraft = ""

    @State private var showImportView = false
    @State private var isFetchingToAttach: Set<String> = []
    @State private var isPreparingQuickShare: Set<String> = []
    @State private var quickShareURL: URL?
    @State private var shareCodeSource: ShareCodeItemSource?
    @State private var showQuickShare = false
    @State private var attachErrors: [String: AppError] = [:]

    @State private var perEntryImageURLs: [String: URL] = [:]
    @State private var perEntryPDFURLs: [String: URL] = [:]
    @State private var bulkImageURLs: [URL] = []
    @State private var bulkPDFURLs: [URL] = []
    @State private var isBulkFetchingImages = false
    @State private var isBulkFetchingPDFs = false
    @State private var bulkImageProgress: (done: Int, total: Int)?
    @State private var bulkPDFProgress: (done: Int, total: Int)?

    @State private var appError: AppError?
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    private let client = ScanServiceClient()

    private var filteredEntries: [ScanHistoryEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            guard selectedFilter.matches(entry.purpose) else { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [
                entry.propertyId,
                entry.unitId,
                entry.organisationId,
                entry.nickname ?? "",
            ].joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    private var heroSubtitle: String {
        if entries.isEmpty { return "Nothing captured yet." }
        let count = entries.count
        return "\(count) scan\(count == 1 ? "" : "s") on this device."
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameEntry != nil },
            set: { if !$0 { renameEntry = nil } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "History",
                leading: {
                    VuuroNavButton("Home", icon: "chevron.left") { dismiss() }
                },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroHero(greeting: nil, title: "Your scans", subtitle: heroSubtitle)
                    searchBar
                    filterChipRow
                    content
                    actionsSection

                    if let appError {
                        ErrorCodeView(error: appError)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer().frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { reloadEntries() }
        .sheet(item: $selectedEntryForReport) { entry in
            NavigationStack {
                ScanResultsReportView(
                    entry: entry,
                    onDelete: { reloadEntries() }
                )
            }
        }




        .sheet(isPresented: $showImportView) {
            NavigationStack {
                ImportScanView(
                    onCancel: { showImportView = false },
                    onImported: { entry in
                        ScanHistoryStore.shared.add(entry)
                        showImportView = false
                        reloadEntries()
                    }
                )
            }
        }
        .sheet(isPresented: $showQuickShare) {
            if let shareCodeSource {
                ActivityShareSheet(items: [shareCodeSource])
            } else if let quickShareURL {
                ActivityShareSheet(items: [quickShareURL])
            }
        }
        .alert("Forget this scan?", isPresented: forgetBinding) {
            Button("Forget", role: .destructive) {
                if let pendingDeleteEntry {
                    deleteEntry(pendingDeleteEntry)
                }
                pendingDeleteEntry = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteEntry = nil }
        } message: {
            Text("This removes the local record on this device only. The session data itself isn't deleted.")
        }
        .alert("Delete this scan from the server?", isPresented: serverDeleteBinding) {
            Button("Delete", role: .destructive) {
                if let pendingServerDeleteEntry {
                    Task { await deleteFromServer(pendingServerDeleteEntry) }
                }
                pendingServerDeleteEntry = nil
            }
            Button("Cancel", role: .cancel) { pendingServerDeleteEntry = nil }
        } message: {
            Text("This permanently deletes the session's rooms, photos, and notes. This cannot be undone.")
        }
        .alert("Rename scan", isPresented: renameBinding) {
            TextField("Optional label", text: $renameDraft)
            Button("Save") {
                if let entry = renameEntry {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let stored = trimmed.isEmpty ? nil : trimmed
                    ScanHistoryStore.shared.updateNickname(sessionId: entry.sessionId, nickname: stored)
                    reloadEntries()
                }
                renameEntry = nil
            }
            Button("Cancel", role: .cancel) {
                renameEntry = nil
            }
        }
    }

    private var forgetBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteEntry != nil },
            set: { if !$0 { pendingDeleteEntry = nil } }
        )
    }

    private var serverDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingServerDeleteEntry != nil },
            set: { if !$0 { pendingServerDeleteEntry = nil } }
        )
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VuuroColor.textSecondary)
            TextField("Search by property, unit, or label", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(VuuroColor.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(VuuroColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(VuuroColor.bgCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var filterChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(selectedFilter == filter ? .white : VuuroColor.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedFilter == filter ? VuuroColor.accent : VuuroColor.bgCard,
                                in: Capsule()
                            )
                            .overlay {
                                if selectedFilter != filter {
                                    Capsule().stroke(VuuroColor.borderMed, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingEntries {
            loadingState
        } else if filteredEntries.isEmpty {
            emptyState
        } else {
            ForEach(filteredEntries) { entry in
                HistoryCard(
                    entry: entry,
                    onTap: { selectedEntryForReport = entry },
                    onAction: { action in handle(action, for: entry) }
                )
            }

            ForEach(filteredEntries) { entry in
                if let attachError = attachErrors[entry.sessionId] {
                    ErrorCodeView(error: attachError)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    VuuroSkeleton(cornerRadius: 6).frame(width: 180, height: 16)
                    VuuroSkeleton(cornerRadius: 6).frame(width: 130, height: 13)
                    VuuroSkeleton(cornerRadius: 6).frame(maxWidth: .infinity).frame(height: 30)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VuuroColor.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
                .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                VuuroColor.accent.opacity(0.10),
                                VuuroColor.lime.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "house")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(VuuroColor.accent)
            }
            .frame(width: 100, height: 100)

            Text(entries.isEmpty ? "No scans yet" : "No matching scans")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)

            Text(entries.isEmpty
                 ? "Your scans will appear here. Start by capturing your first room."
                 : "Try a different search or filter.")
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            if entries.isEmpty, let onStartScan {
                Button("Scan first room", action: onStartScan)
                    .buttonStyle(.vuuroPrimarySmall)
                    .frame(maxWidth: 200)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VuuroSectionLabel(text: "Actions")

            VStack(spacing: 10) {
                Button {
                    showImportView = true
                } label: {
                    Text("Add a shared scan")
                }
                .buttonStyle(.vuuroGhostSmall)

                Button {
                    Task { await downloadAllImages() }
                } label: {
                    if isBulkFetchingImages {
                        HStack(spacing: 6) {
                            ProgressView().tint(VuuroColor.textPrimary)
                            if let bulkImageProgress {
                                Text("\(bulkImageProgress.done) of \(bulkImageProgress.total)")
                            }
                        }
                    } else {
                        Text("Download all images")
                    }
                }
                .buttonStyle(.vuuroGhostSmall)
                .disabled(isBulkFetchingImages || entries.isEmpty)

                if !bulkImageURLs.isEmpty {
                    ShareLink(items: bulkImageURLs) {
                        Label("Save all images", systemImage: "square.and.arrow.up.on.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                }

                Button {
                    Task { await downloadAllPDFs() }
                } label: {
                    if isBulkFetchingPDFs {
                        HStack(spacing: 6) {
                            ProgressView().tint(VuuroColor.textPrimary)
                            if let bulkPDFProgress {
                                Text("\(bulkPDFProgress.done) of \(bulkPDFProgress.total)")
                            }
                        }
                    } else {
                        Text("Download all PDFs")
                    }
                }
                .buttonStyle(.vuuroGhostSmall)
                .disabled(isBulkFetchingPDFs || entries.isEmpty)

                if !bulkPDFURLs.isEmpty {
                    ShareLink(items: bulkPDFURLs) {
                        Label("Save all PDFs", systemImage: "square.and.arrow.up.on.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func handle(_ action: HistoryCardAction, for entry: ScanHistoryEntry) {
        switch action {
        case .openReport:
            selectedEntryForReport = entry
        case .rename:
            renameEntry = entry
            renameDraft = entry.nickname ?? ""
        case .scanAnotherRoom:
            Task {
                guard let refreshed = await rotateTokenIfNeeded(entry) else { return }
                cleanUpTempFiles()
                dismiss()
                onResumeToAddRoom?(refreshed)
            }
        case .attachPhoto:
            Task {
                guard let refreshed = await rotateTokenIfNeeded(entry) else { return }
                await attach(refreshed)
            }
        case .shareImage:
            Task { await shareFile(for: entry, pdf: false) }
        case .sharePDF:
            Task { await shareFile(for: entry, pdf: true) }
        case .shareCode:
            shareAccessCode(for: entry)
        case .accessLog:
            break
        case .forget:
            pendingDeleteEntry = entry
        case .deleteFromServer:
            pendingServerDeleteEntry = entry
        }
    }

    private func shareAccessCode(for entry: ScanHistoryEntry) {
        guard let code = ScanShareCode.encode(entry) else { return }
        quickShareURL = nil
        shareCodeSource = ShareCodeItemSource(
            code: code,
            subject: "Vuuro Scan access — \(entry.propertyId) / \(entry.unitId)",
            messageBody: "Paste this code into Vuuro Scan, under History → \"Add a scan someone shared with you\", to get full access to this scan (view, export, delete). Only share it with someone you trust."
        )
        showQuickShare = true
    }

    private func reloadEntries() {
        let token = UUID()
        reloadToken = token
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                ScanHistoryStore.shared.all()
            }.value
            guard reloadToken == token else { return }
            entries = loaded
            isLoadingEntries = false
        }
    }

    @MainActor
    private func deleteFromServer(_ entry: ScanHistoryEntry) async {
        guard let refreshed = await rotateTokenIfNeeded(entry) else { return }
        do {
            try await client.deleteSession(sessionId: refreshed.sessionId, accessToken: refreshed.accessToken)
            DiagnosticsLog.shared.record("Session \(refreshed.sessionId) deleted from server", category: .info)
            appError = nil
            deleteEntry(refreshed)
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "Server delete cancelled for session \(refreshed.sessionId)",
                category: .info
            )
        } catch {
            appError = AppError(site: .historyServerDelete, underlying: error)
        }
    }

    @MainActor
    private func rotateTokenIfNeeded(_ entry: ScanHistoryEntry) async -> ScanHistoryEntry? {
        guard !entry.accessToken.isEmpty else {
            appError = AppError(site: .historyTokenMissing, underlying: nil)
            return nil
        }
        if let expiresAtString = entry.expiresAt, !expiresAtString.isEmpty,
           let expiresAt = ISO8601DateFormatter().date(from: expiresAtString),
           expiresAt.timeIntervalSinceNow >= 14 * 24 * 60 * 60 {
            return entry
        }
        do {
            let rotated = try await client.rotateToken(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken
            )
            DiagnosticsLog.shared.record(
                "Token rotated for session \(entry.sessionId), new expiry \(rotated.expiresAt)",
                category: .info
            )
            let updated = ScanHistoryEntry(
                sessionId: entry.sessionId,
                accessToken: rotated.accessToken,
                propertyId: entry.propertyId,
                unitId: entry.unitId,
                organisationId: entry.organisationId,
                purpose: entry.purpose,
                createdAt: entry.createdAt,
                expiresAt: rotated.expiresAt,
                nickname: entry.nickname,
                cachedRoomSummary: entry.cachedRoomSummary,
                occupied: entry.occupied,
                consentObtained: entry.consentObtained
            )
            ScanHistoryStore.shared.add(updated)
            reloadEntries()
            return updated
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "Token rotation cancelled for session \(entry.sessionId)",
                category: .info
            )
            return nil
        } catch {
            DiagnosticsLog.shared.record(
                "Token rotation failed for session \(entry.sessionId): \(error.localizedDescription)",
                category: .error
            )
            appError = AppError(site: .historySessionFetch, underlying: error)
            return nil
        }
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

        let imageName = "floorplan-\(entry.sessionId).png"
        let pdfName = "floorplan-\(entry.sessionId).pdf"

        for url in bulkImageURLs where url.lastPathComponent == imageName {
            try? FileManager.default.removeItem(at: url)
        }
        bulkImageURLs.removeAll { $0.lastPathComponent == imageName }

        for url in bulkPDFURLs where url.lastPathComponent == pdfName {
            try? FileManager.default.removeItem(at: url)
        }
        bulkPDFURLs.removeAll { $0.lastPathComponent == pdfName }

        ScanHistoryStore.shared.remove(sessionId: entry.sessionId)
        reloadEntries()
    }

    @MainActor
    private func attach(_ entry: ScanHistoryEntry) async {
        guard !isFetchingToAttach.contains(entry.sessionId) else { return }
        isFetchingToAttach.insert(entry.sessionId)
        defer { isFetchingToAttach.remove(entry.sessionId) }
        do {
            let floorPlan = try await client.fetchSession(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken
            )
            attachErrors[entry.sessionId] = nil
            cleanUpTempFiles()
            dismiss()
            onAttachToSession?(entry, floorPlan)
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "Attach fetch cancelled for session \(entry.sessionId)",
                category: .info
            )
        } catch {
            attachErrors[entry.sessionId] = AppError(site: .historySessionFetch, underlying: error)
        }
    }

    @MainActor
    private func shareFile(for entry: ScanHistoryEntry, pdf: Bool) async {
        let key = entry.sessionId + (pdf ? ":pdf" : ":image")
        guard !isPreparingQuickShare.contains(key) else { return }
        isPreparingQuickShare.insert(key)
        defer { isPreparingQuickShare.remove(key) }

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
        guard !entry.accessToken.isEmpty else {
            appError = AppError(site: .historyTokenMissing, underlying: nil)
            return
        }
        do {
            let data = try await client.fetchFloorPlanImage(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                unit: currentExportUnit,
                label: entry.nickname
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floorplan-\(entry.sessionId).png")
            try data.write(to: url, options: .atomic)
            perEntryImageURLs[entry.sessionId] = url
            appError = nil
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "Image download cancelled for session \(entry.sessionId)",
                category: .info
            )
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func downloadPDF(for entry: ScanHistoryEntry) async {
        guard !entry.accessToken.isEmpty else {
            appError = AppError(site: .historyTokenMissing, underlying: nil)
            return
        }
        do {
            let data = try await client.fetchFloorPlanPDF(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                unit: currentExportUnit,
                label: entry.nickname
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floorplan-\(entry.sessionId).pdf")
            try data.write(to: url, options: .atomic)
            perEntryPDFURLs[entry.sessionId] = url
            appError = nil
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "PDF download cancelled for session \(entry.sessionId)",
                category: .info
            )
        } catch {
            appError = AppError(site: .historyPDFDownload, underlying: error)
        }
    }

    @MainActor
    private func downloadAllImages() async {
        guard !isBulkFetchingImages else { return }
        isBulkFetchingImages = true
        bulkImageProgress = (0, entries.count)
        defer {
            isBulkFetchingImages = false
            bulkImageProgress = nil
        }

        var urls: [URL] = []
        var skipped = 0
        for (index, entry) in entries.enumerated() {
            do {
                let data = try await client.fetchFloorPlanImage(
                    sessionId: entry.sessionId,
                    accessToken: entry.accessToken,
                    unit: currentExportUnit,
                    label: entry.nickname
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("floorplan-\(entry.sessionId).png")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            } catch is CancellationError {
                DiagnosticsLog.shared.record(
                    "Bulk image download cancelled after \(urls.count) image(s)",
                    category: .info
                )
                return
            } catch {
                skipped += 1
                DiagnosticsLog.shared.record(
                    "Bulk image download skipped session \(entry.sessionId): \(error.localizedDescription)",
                    category: .error
                )
            }
            bulkImageProgress = (index + 1, entries.count)
        }
        bulkImageURLs = urls
        if urls.isEmpty {
            errorMessage = "No floor plan images were available to download."
        } else if skipped > 0 {
            errorMessage = "Downloaded \(urls.count) image(s); skipped \(skipped) session(s)."
        } else {
            errorMessage = nil
        }
    }

    @MainActor
    private func downloadAllPDFs() async {
        guard !isBulkFetchingPDFs else { return }
        isBulkFetchingPDFs = true
        bulkPDFProgress = (0, entries.count)
        defer {
            isBulkFetchingPDFs = false
            bulkPDFProgress = nil
        }

        var urls: [URL] = []
        var skipped = 0
        for (index, entry) in entries.enumerated() {
            do {
                let data = try await client.fetchFloorPlanPDF(
                    sessionId: entry.sessionId,
                    accessToken: entry.accessToken,
                    unit: currentExportUnit,
                    label: entry.nickname
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("floorplan-\(entry.sessionId).pdf")
                try data.write(to: url, options: .atomic)
                urls.append(url)
            } catch is CancellationError {
                DiagnosticsLog.shared.record(
                    "Bulk PDF download cancelled after \(urls.count) PDF(s)",
                    category: .info
                )
                return
            } catch {
                skipped += 1
                DiagnosticsLog.shared.record(
                    "Bulk PDF download skipped session \(entry.sessionId): \(error.localizedDescription)",
                    category: .error
                )
            }
            bulkPDFProgress = (index + 1, entries.count)
        }
        bulkPDFURLs = urls
        if urls.isEmpty {
            errorMessage = "No floor plan PDFs were available to download."
        } else if skipped > 0 {
            errorMessage = "Downloaded \(urls.count) PDF(s); skipped \(skipped) session(s)."
        } else {
            errorMessage = nil
        }
    }

    private func cleanUpTempFiles() {
        let all = Array(perEntryImageURLs.values)
            + Array(perEntryPDFURLs.values)
            + bulkImageURLs
            + bulkPDFURLs
        for url in all {
            try? FileManager.default.removeItem(at: url)
        }
        perEntryImageURLs = [:]
        perEntryPDFURLs = [:]
        bulkImageURLs = []
        bulkPDFURLs = []
    }

    private var currentExportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: UserDefaults.standard.string(forKey: "scanExportMeasurementUnit") ?? "")
            ?? .metric
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case listing
    case checkIn
    case checkOut
    case renovation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .listing: return "Listing"
        case .checkIn: return "Check-in"
        case .checkOut: return "Check-out"
        case .renovation: return "Renovation"
        }
    }

    func matches(_ purpose: ScanPurpose) -> Bool {
        switch self {
        case .all: return true
        case .listing: return purpose == .listing
        case .checkIn: return purpose == .checkIn
        case .checkOut: return purpose == .checkOut
        case .renovation: return purpose == .renovation
        }
    }
}

enum HistoryCardAction {
    case openReport
    case rename
    case scanAnotherRoom
    case attachPhoto
    case shareImage
    case sharePDF
    case shareCode
    case accessLog
    case forget
    case deleteFromServer
}

private struct HistoryCard: View {
    let entry: ScanHistoryEntry
    let onTap: () -> Void
    let onAction: (HistoryCardAction) -> Void

    private static func metaFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        formatter.locale = AppLanguageSettings.effectiveLocale
        return formatter
    }

    private var displayName: String {
        if let nickname = entry.nickname, !nickname.isEmpty {
            return nickname
        }
        return "\(entry.propertyId) — \(entry.unitId)"
    }

    private var metaLine: String {
        "\(entry.purpose.displayName) · \(Self.metaFormatter().string(from: entry.createdAt))"
    }

    private var pills: ([String], Int) {
        RoomSummary.pills(for: entry.cachedRoomSummary)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(VuuroColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(metaLine)
                            .font(.system(size: 13))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VuuroBadge("Ready", style: .good)
                }

                let parsed = pills
                if !parsed.0.isEmpty || parsed.1 > 0 {
                    Rectangle()
                        .fill(VuuroColor.borderSoft)
                        .frame(height: 1)
                        .padding(.top, 12)

                    HStack(spacing: 6) {
                        ForEach(parsed.0, id: \.self) { pill in
                            Text(pill)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(VuuroColor.neutralText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        if parsed.1 > 0 {
                            Text("+\(parsed.1)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(VuuroColor.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .contextMenu {
            Button {
                onAction(.rename)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                onAction(.scanAnotherRoom)
            } label: {
                Label("Scan another room", systemImage: "plus.viewfinder")
            }
            Button {
                onAction(.attachPhoto)
            } label: {
                Label("Add photo or note", systemImage: "camera")
            }
            Divider()
            Button {
                onAction(.shareImage)
            } label: {
                Label("Share image", systemImage: "square.and.arrow.up")
            }
            Button {
                onAction(.sharePDF)
            } label: {
                Label("Share PDF", systemImage: "doc")
            }
            Button {
                onAction(.shareCode)
            } label: {
                Label("Share access", systemImage: "person.badge.plus")
            }
            Divider()
            Button {
                onAction(.forget)
            } label: {
                Label("Forget (device only)", systemImage: "eye.slash")
            }
            Button(role: .destructive) {
                onAction(.deleteFromServer)
            } label: {
                Label("Delete from server", systemImage: "trash")
            }
        }
    }
}

private struct ImportScanView: View {
    let onCancel: () -> Void
    let onImported: (ScanHistoryEntry) -> Void

    @State private var code = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Add shared scan",
                leading: {
                    VuuroNavButton("Cancel", action: onCancel)
                },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroHero(
                        greeting: nil,
                        title: "Paste a share code",
                        subtitle: "Ask the other person for the code from their History."
                    )

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $code)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 140)
                            .padding(12)
                            .scrollContentBackground(.hidden)
                            .focused($isFocused)
                        if code.isEmpty {
                            Text("VUURO-SCAN-1:...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(VuuroColor.textTertiary)
                                .padding(.top, 20)
                                .padding(.leading, 17)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(VuuroColor.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
                    .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
                    .padding(.horizontal, 20)

                    if let error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(VuuroColor.danger)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Button("Add this scan") {
                        importScan()
                    }
                    .buttonStyle(.vuuroPrimary)
                    .disabled(trimmedCode.isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    Spacer().frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isFocused = true }
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importScan() {
        guard let decoded = ScanShareCode.decode(code) else {
            error = "That code doesn't look right — check that you copied the whole thing."
            return
        }
        error = nil
        onImported(decoded)
    }
}