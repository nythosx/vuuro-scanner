import QuickLook
import SwiftUI
import UIKit

struct ScanResultsReportView: View {
    let entry: ScanHistoryEntry
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var floorPlan: FloorPlan?
    @State private var isLoading = true
    @State private var appError: AppError?

    @State private var floorPlanImage: UIImage?
    @State private var isLoadingImage = false
    @State private var imageFailed = false

    @State private var shareImageURL: URL?
    @State private var pdfURL: URL?

    @State private var showImageShare = false
    @State private var showPDFShare = false
    @State private var showPDFPreview = false
    @State private var isFetchingPDF = false

    @State private var showForgetConfirmation = false
    @State private var showServerDeleteConfirmation = false

    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private let client = ScanServiceClient()

    private static func headerDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        formatter.locale = AppLanguageSettings.effectiveLocale
        return formatter
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    if isLoading {
                        loadingState
                    } else if let floorPlan {
                        floorPlanCard(floorPlan: floorPlan)
                        roomsSection(floorPlan: floorPlan)
                        unitAttachmentsSection(floorPlan: floorPlan)
                    }

                    accessLogRow
                    actionButtons

                    if let appError {
                        ErrorCodeView(error: appError)
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
        .task { await load() }
        .sheet(isPresented: $showImageShare) {
            if let shareImageURL {
                ActivityShareSheet(items: [shareImageURL])
            }
        }
        .sheet(isPresented: $showPDFShare) {
            if let pdfURL {
                ActivityShareSheet(items: [pdfURL])
            }
        }
        .fullScreenCover(isPresented: $showPDFPreview) {
            if let pdfURL {
                QuickLookPreview(url: pdfURL) {
                    showPDFPreview = false
                }
                .ignoresSafeArea()
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("Couldn't load the PDF.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("Close") {
                            showPDFPreview = false
                        }
                        .buttonStyle(.vuuroPrimary)
                        .frame(maxWidth: 200)
                    }
                }
            }
        }
        .alert("Forget this scan?", isPresented: $showForgetConfirmation) {
            Button("Forget", role: .destructive) {
                ScanHistoryStore.shared.remove(sessionId: entry.sessionId)
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local record on this device only. Server data isn't affected.")
        }
        .alert("Delete from server?", isPresented: $showServerDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteFromServer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the session's rooms, photos, and notes. This cannot be undone.")
        }
    }

    private var navBar: some View {
        VuuroNavBar(
            title: navTitle,
            leading: {
                VuuroNavButton("Close") { dismiss() }
            },
            trailing: {
                Menu {
                    Button {
                        Task { await shareImage() }
                    } label: {
                        Label("Share image", systemImage: "photo")
                    }
                    Button {
                        Task { await sharePDF() }
                    } label: {
                        Label("Share PDF", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VuuroColor.accent)
                        .frame(width: 30, height: 30, alignment: .trailing)
                        .contentShape(Rectangle())
                }
            }
        )
    }

    private var navTitle: String {
        if let nickname = entry.nickname, !nickname.isEmpty {
            return nickname
        }
        return "Scan report"
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(VuuroColor.lime.opacity(0.20))
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(VuuroColor.goodText)
            }
            .frame(width: 64, height: 64)

            Text(heroTitle)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(VuuroColor.textPrimary)

            Text(heroSubtitle)
                .font(.system(size: 15))
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            HStack(spacing: 8) {
                Text(entry.purpose.displayName)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(VuuroColor.accent.opacity(0.12), in: Capsule())

                Text(Self.headerDateFormatter().string(from: entry.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .padding(.horizontal, 20)
    }

    private var heroTitle: String {
        let count = floorPlan?.rooms.count ?? 0
        return count <= 1 ? "Room captured" : "Unit captured"
    }

    private var heroSubtitle: String {
        guard let floorPlan else { return "Loading capture…" }
        let count = floorPlan.rooms.count
        let total = floorPlan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
        return "\(count) room\(count == 1 ? "" : "s") · \(String(format: "%.1f m² total", total))"
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VuuroSkeleton(cornerRadius: 6).frame(width: 140, height: 14)
            VuuroSkeleton(cornerRadius: 14).frame(maxWidth: .infinity).frame(height: 220)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func floorPlanCard(floorPlan: FloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Floor plan")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)
                Spacer(minLength: 0)
                VuuroBadge(
                    "\(floorPlan.rooms.count) room\(floorPlan.rooms.count == 1 ? "" : "s")",
                    style: .info
                )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VuuroColor.bgInset)

                if isLoadingImage {
                    ProgressView().tint(VuuroColor.accent)
                } else if let floorPlanImage {
                    Image(uiImage: floorPlanImage)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else if imageFailed {
                    imageFailedPlaceholder
                } else {
                    ProgressView().tint(VuuroColor.accent)
                }
            }
            .frame(height: 220)

            HStack(spacing: 8) {
                Button {
                    Task { await shareImage() }
                } label: {
                    Text("Save image")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vuuroOutlineSmall)

                Button {
                    Task { await openPDF() }
                } label: {
                    if isFetchingPDF {
                        ProgressView().tint(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("View PDF")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.vuuroOutlineSmall)
                .disabled(isFetchingPDF)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var imageFailedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 26))
                .foregroundStyle(VuuroColor.textTertiary)
            Text("Couldn't render the floor plan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VuuroColor.textSecondary)
            Button("Retry") {
                Task { await loadImage() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(VuuroColor.accent)
        }
    }

    @ViewBuilder
    private func roomsSection(floorPlan: FloorPlan) -> some View {
        if floorPlan.rooms.isEmpty {
            Text("No rooms captured for this scan.")
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(VuuroColor.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
                .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        } else {
            ForEach(floorPlan.rooms, id: \.roomId) { room in
                RoomResultCard(
                    room: room,
                    showsRibbon: false,
                    isFused: floorPlan.rooms.count > 1,
                    photos: floorPlan.photos.filter { $0.roomId == room.roomId },
                    notes: floorPlan.notes.filter { $0.roomId == room.roomId },
                    session: entry.asResumableSession()
                )
            }
        }
    }

    @ViewBuilder
    private func unitAttachmentsSection(floorPlan: FloorPlan) -> some View {
        let unitPhotos = floorPlan.photos.filter { $0.roomId == nil }
        let unitNotes = floorPlan.notes.filter { $0.roomId == nil }

        if !unitPhotos.isEmpty || !unitNotes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Whole unit")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)

                RoomAttachmentsList(
                    session: entry.asResumableSession(),
                    photos: unitPhotos,
                    notes: unitNotes
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var accessLogRow: some View {
        NavigationLink {
            AccessLogView(sessionId: entry.sessionId, accessToken: entry.accessToken)
        } label: {
            HStack {
                Text("Access log")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(VuuroColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VuuroColor.textSecondary)
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
        .padding(.bottom, 12)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button("Forget this scan", role: .destructive) {
                showForgetConfirmation = true
            }
            .buttonStyle(.vuuroGhostSmall)

            Button("Delete from server", role: .destructive) {
                showServerDeleteConfirmation = true
            }
            .buttonStyle(.vuuroDestructiveSmall)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let sessionFetch = Task { @MainActor in
            do {
                floorPlan = try await client.fetchSession(
                    sessionId: entry.sessionId,
                    accessToken: entry.accessToken
                )
                appError = nil
            } catch is CancellationError {
                DiagnosticsLog.shared.record("Session fetch cancelled for \(entry.sessionId)", category: .info)
            } catch {
                appError = AppError(site: .historySessionFetch, underlying: error)
            }
        }
        let imageFetch = Task { @MainActor in
            await loadImage()
        }
        await sessionFetch.value
        await imageFetch.value
    }

    @MainActor
    private func loadImage() async {
        if floorPlanImage != nil { return }

        imageFailed = false
        let alreadyCached = FloorPlanImageCache.shared.cachedData(
            sessionId: entry.sessionId,
            unit: exportUnit
        ) != nil
        isLoadingImage = !alreadyCached
        defer { isLoadingImage = false }

        let data = await FloorPlanImageCache.shared.prefetch(
            sessionId: entry.sessionId,
            accessToken: entry.accessToken,
            unit: exportUnit,
            client: client
        ).value

        guard let data, let image = UIImage(data: data) else {
            appError = AppError(
                site: .resultImageLoad,
                underlying: FloorPlanImageCache.shared.lastError(
                    sessionId: entry.sessionId,
                    unit: exportUnit
                )
            )
            imageFailed = true
            return
        }
        floorPlanImage = image
    }

    @MainActor
    private func shareImage() async {
        if let existing = shareImageURL, FileManager.default.fileExists(atPath: existing.path) {
            showImageShare = true
            return
        }
        do {
            let data = try await client.fetchFloorPlanImage(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                unit: exportUnit,
                label: entry.nickname
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floorplan-\(entry.sessionId).png")
            try data.write(to: url, options: .atomic)
            shareImageURL = url
            showImageShare = true
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func sharePDF() async {
        if pdfURL == nil {
            await fetchPDF()
        }
        guard pdfURL != nil else { return }
        showPDFShare = true
    }

    @MainActor
    private func openPDF() async {
        if pdfURL == nil {
            await fetchPDF()
        }
        guard pdfURL != nil else { return }
        showPDFPreview = true
    }

    @MainActor
    private func fetchPDF() async {
        guard !isFetchingPDF else { return }
        isFetchingPDF = true
        defer { isFetchingPDF = false }
        do {
            let data = try await client.fetchFloorPlanPDF(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                unit: exportUnit,
                label: entry.nickname
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floorplan-\(entry.sessionId).pdf")
            try data.write(to: url, options: .atomic)
            pdfURL = url
            appError = nil
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .resultPDFLoad, underlying: error)
        }
    }

    @MainActor
    private func deleteFromServer() async {
        do {
            try await client.deleteSession(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken
            )
            DiagnosticsLog.shared.record(
                "Session \(entry.sessionId) deleted from server (report view)",
                category: .info
            )
            ScanHistoryStore.shared.remove(sessionId: entry.sessionId)
            onDelete?()
            dismiss()
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "Server delete cancelled for session \(entry.sessionId)",
                category: .info
            )
        } catch {
            appError = AppError(site: .historyServerDelete, underlying: error)
        }
    }
}