import ARKit
import QuickLook
import SwiftUI
import UIKit

struct ScanResultsReportView: View {
    let entry: ScanHistoryEntry
    var onDelete: (() -> Void)? = nil
    var onContinueScan: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var floorPlan: FloorPlan?
    @State private var isLoading = true
    @State private var appError: AppError?

    @State private var floorPlanImage: UIImage?
    @State private var isLoadingImage = false
    @State private var imageFailed = false

    @State private var shareImageURL: URL?
    @State private var pdfURL: URL?

    @State private var showPDFPreview = false
    @State private var isFetchingPDF = false
    @State private var planRevision = 0

    @State private var showForgetConfirmation = false
    @State private var showServerDeleteConfirmation = false
    @State private var showDeletionRequestConfirmation = false
    @State private var isRequestingDeletion = false
    @State private var deletionStatus: ScanServiceClient.RequestDeletionResponse?

    @State private var pendingObjectChanges: [ObjectChangeKey: PendingObjectChange] = [:]
    @State private var isSavingChanges = false
    @State private var saveSuccessVisible = false
    @State private var missingItemTarget: MissingItemTarget?
    @State private var updatingRoomTypeIds: Set<String> = []
    @State private var splitTarget: SplitTarget?
    @State private var isUndoingSplit = false
    @State private var floorTargetRoom: FloorPlan.Room?
    @State private var deleteTargetRoom: FloorPlan.Room?
    @State private var roomFloorDraft = ""
    @State private var loadingPlanTarget: PlanTarget?
    @State private var previewImage: PreviewImage?
    @State private var showContinueChoices = false
    @State private var showContinueNewFloor = false
    @State private var continueNewFloorName = ""
    @State private var placementTarget: PlacementTarget?
    @State private var showUnsavedChangesAlert = false

    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue
    @AppStorage("reportUses3D") private var reportUses3D: Bool = false
    @State private var isExportingUSDZ = false
    @State private var usdzURL: URL?

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private let client = ScanServiceClient()

    private var lastActivityDate: Date {
        guard let captured = floorPlan.flatMap({ ScanHistoryStore.parseServerDate($0.capturedAt) }) else {
            return entry.lastActivityAt
        }
        return max(entry.lastActivityAt, captured)
    }

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
                        if !floorPlan.rooms.isEmpty {
                            reportPlanViewPicker
                            if reportUses3D {
                                DollhouseContainerView(
                                    rooms: floorPlan.rooms,
                                    onShowPlan: { reportUses3D = false }
                                )
                                .padding(.bottom, 12)
                            } else {
                                if RoomGridSection.shows(for: floorPlan.rooms) {
                                    RoomGridSection(
                                        rooms: floorPlan.rooms,
                                        sessionId: entry.sessionId,
                                        accessToken: entry.accessToken,
                                        unit: exportUnit,
                                        refreshKey: "\(planRevision)",
                                        identifierPrefix: "report",
                                        imageActionLabel: "Save image",
                                        imageActionIdentifier: "report.saveImage",
                                        isFetchingPDF: isFetchingPDF,
                                        onOpen: { image in previewImage = PreviewImage(image: image) },
                                        onImageAction: { Task { await shareImage() } },
                                        onViewPDF: { Task { await openPDF() } }
                                    )
                                } else {
                                    floorPlanCard(floorPlan: floorPlan)
                                }
                            }
                        }
                        if !reportUses3D {
                            placementBanner
                        }
                        if onContinueScan != nil && DeviceCapability.canCaptureRooms {
                            continueScanButton
                        }
                        roomsSection(floorPlan: floorPlan)
                        unitAttachmentsSection(floorPlan: floorPlan)
                    }

                    if !pendingObjectChanges.isEmpty {
                        saveChangesBar
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
        .confirmationDialog("Continue this scan", isPresented: $showContinueChoices, titleVisibility: .visible) {
            ForEach(continueFloorOptions, id: \.self) { floor in
                Button(floor.isEmpty ? "Add rooms" : "Add rooms on \(floor)") {
                    onContinueScan?(floor)
                }
                .accessibilityIdentifier("report.continueFloor.\(floor)")
            }
            Button("Add a new floor…") {
                continueNewFloorName = ""
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    showContinueNewFloor = true
                }
            }
            .accessibilityIdentifier("report.continueNewFloor")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("report.continueCancel")
        } message: {
            Text(verbatim: continueScanMessage)
        }
        .alert("Which floor?", isPresented: $showContinueNewFloor) {
            TextField("e.g. Attic, 1st floor", text: $continueNewFloorName)
                .accessibilityIdentifier("report.continueNewFloorField")
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Continue") {
                let trimmed = FloorValidation.sanitized(continueNewFloorName)
                guard !trimmed.isEmpty else { return }
                onContinueScan?(trimmed)
            }
            .accessibilityIdentifier("report.continueNewFloorContinue")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("report.continueNewFloorCancel")
        } message: {
            Text("Name the floor you're about to scan.")
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
                        .accessibilityIdentifier("report.pdfErrorClose")
                        .buttonStyle(.vuuroPrimary)
                        .frame(maxWidth: 200)
                    }
                }
            }
        }
        .fullScreenCover(item: $previewImage) { preview in
            ImagePreviewView(image: preview.image) {
                previewImage = nil
            }
        }
        .sheet(item: $missingItemTarget) { target in
            MissingItemSheet(
                session: entry.asResumableSession(),
                room: target.room,
                onSaved: { updated in
                    floorPlan = updated
                    cacheRoomBreakdown(updated)
                    missingItemTarget = nil
                    discardRenderedExports()
                    Task { await loadImage() }
                    VuuroToast.shared.show(vuuroLocalized("Missing item added"))
                },
                onCancel: { missingItemTarget = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $splitTarget) { target in
            RoomSplitSheet(
                session: entry.asResumableSession(),
                room: target.room,
                onSaved: { updated, mode in applySplitResult(updated, mode: mode) },
                onCancel: { splitTarget = nil }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $placementTarget) { target in
            if let plan = floorPlan {
                GroupPlacementView(
                    session: entry.asResumableSession(),
                    floorPlan: plan,
                    groupId: target.movingGroupId,
                    floor: target.floor,
                    onFinished: { updated in
                        placementTarget = nil
                        applyRoomChange(updated)
                    },
                    onCancel: { placementTarget = nil }
                )
            }
        }
        .modifier(RoomActionAlerts(
            floorTarget: $floorTargetRoom,
            deleteTarget: $deleteTargetRoom,
            floorDraft: $roomFloorDraft,
            onSaveFloor: { room, floor in Task { await moveRoom(room, toFloor: floor) } },
            onDelete: { room in Task { await deleteRoom(room) } }
        ))
        .alert("Forget this scan?", isPresented: $showForgetConfirmation) {
            Button("Forget", role: .destructive) {
                ScanHistoryStore.shared.remove(sessionId: entry.sessionId)
                onDelete?()
                dismiss()
            }
            .accessibilityIdentifier("report.forgetConfirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("report.forgetCancel")
        } message: {
            Text("This removes the local record on this device only. Server data isn't affected.")
        }
        .alert("Delete from server?", isPresented: $showServerDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteFromServer() }
            }
            .accessibilityIdentifier("report.serverDeleteConfirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("report.serverDeleteCancel")
        } message: {
            Text("This permanently deletes the session's rooms, photos, and notes. This cannot be undone.")
        }
        .alert("Request deletion?", isPresented: $showDeletionRequestConfirmation) {
            Button("Request deletion", role: .destructive) {
                Task { await requestDeletion() }
            }
            .accessibilityIdentifier("report.requestDeletionConfirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("report.requestDeletionCancel")
        } message: {
            Text("This flags the scan for deletion. It will be removed after a 7-day grace period. Useful for tenants asking for their data to be deleted without immediate admin action.")
        }
        .alert("Unsaved changes", isPresented: $showUnsavedChangesAlert) {
            Button("Save and close") {
                Task {
                    appError = nil
                    await saveObjectChanges()
                    if appError == nil {
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("report.unsavedSaveAndClose")
            Button("Discard and close", role: .destructive) {
                pendingObjectChanges.removeAll()
                dismiss()
            }
            .accessibilityIdentifier("report.unsavedDiscardAndClose")
            Button("Stay", role: .cancel) {}
                .accessibilityIdentifier("report.unsavedStay")
        } message: {
            Text("You have unsaved edits on this scan.")
        }
    }

    private var reportPlanViewPicker: some View {
        Picker("View", selection: $reportUses3D) {
            Text("2D plan").tag(false)
            Text("3D").tag(true)
        }
        .accessibilityIdentifier("report.planViewMode")
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var navBar: some View {
        VuuroNavBar(
            title: navTitle,
            leading: {
                VuuroNavButton("Close") {
                    if pendingObjectChanges.isEmpty {
                        dismiss()
                    } else {
                        showUnsavedChangesAlert = true
                    }
                }
                    .accessibilityIdentifier("report.close")
            },
            trailing: {
                Menu {
                    Button {
                        Task { await shareImage() }
                    } label: {
                        Label("Share image", systemImage: "photo")
                    }
                    .accessibilityIdentifier("report.shareImage")
                    Button {
                        Task { await sharePDF() }
                    } label: {
                        Label("Share PDF", systemImage: "doc")
                    }
                    .accessibilityIdentifier("report.sharePDF")
                    Button {
                        Task { await prepareUSDZ(forPreview: false) }
                    } label: {
                        Label("Share 3D model", systemImage: "cube")
                    }
                    .accessibilityIdentifier("report.shareUSDZ")
                    if ARWorldTrackingConfiguration.isSupported {
                        Button {
                            Task { await prepareUSDZ(forPreview: true) }
                        } label: {
                            Label("Preview in AR", systemImage: "arkit")
                        }
                        .accessibilityIdentifier("report.previewAR")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VuuroColor.accent)
                        .frame(width: 30, height: 30, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("report.shareMenu")
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

                Text(Self.headerDateFormatter().string(from: lastActivityDate))
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

            if PlanBlock.blocks(for: floorPlan.rooms).count >= 2 {
                PlanBlocksCarousel(
                    blocks: PlanBlock.blocks(for: floorPlan.rooms),
                    sessionId: entry.sessionId,
                    accessToken: entry.accessToken,
                    unit: exportUnit,
                    refreshKey: "\(planRevision)",
                    identifierPrefix: "report",
                    onOpen: { image in previewImage = PreviewImage(image: image) }
                )
            } else {
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
                .vuuroPlanFrame()
                .overlay(alignment: .topTrailing) {
                    if floorPlanImage != nil {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .padding(8)
                            .background(VuuroColor.bgCard.opacity(0.9), in: Circle())
                            .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let floorPlanImage {
                        previewImage = PreviewImage(image: floorPlanImage)
                    }
                }
                .accessibilityIdentifier("report.floorPlanPreview")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open floor plan full screen")
            }

            if floorPlan.rooms.count > 1 {
                RoomPlanStrip(
                    rooms: floorPlan.rooms,
                    sessionId: entry.sessionId,
                    accessToken: entry.accessToken,
                    unit: exportUnit,
                    onOpen: { image in previewImage = PreviewImage(image: image) }
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task { await shareImage() }
                } label: {
                    Text("Save image")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("report.saveImage")
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
                .accessibilityIdentifier("report.viewPDF")
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
            .accessibilityIdentifier("report.retry")
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
            if floorPlan.rooms.contains(where: { ($0.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                Text(vuuroLocalized("Some rooms have no floor yet — set it so areas add up"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VuuroColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(VuuroColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(VuuroColor.accent.opacity(0.30), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            separatePlans(floorPlan)
            ForEach(RoomFloorSection.sections(for: floorPlan.rooms)) { section in
                if let title = section.title {
                    RoomFloorSectionHeader(title: title)
                }
                ForEach(section.rooms, id: \.roomId) { room in
                    roomCard(room, floorPlan: floorPlan)
                }
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
                    notes: unitNotes,
                    onChanged: { updated in applyAttachmentChange(updated) }
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
        .accessibilityIdentifier("report.accessLog")
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private struct PreviewImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private struct MissingItemTarget: Identifiable {
        let room: FloorPlan.Room
        var id: String { room.roomId }
    }

    @MainActor
    private func roomCard(_ room: FloorPlan.Room, floorPlan: FloorPlan) -> RoomResultCard {
        var delete: (() -> Void)? = nil
        if canDeleteRooms {
            delete = { deleteTargetRoom = room }
        }
        var undo: (() -> Void)? = nil
        if floorPlan.lastSplitRoomIds.contains(room.roomId) {
            undo = { startUndoSplit() }
        }
        return RoomResultCard(
            room: room,
            showsRibbon: false,
            photos: floorPlan.photos.filter { $0.roomId == room.roomId },
            notes: floorPlan.notes.filter { $0.roomId == room.roomId },
            session: entry.asResumableSession(),
            pendingObjectChanges: pendingObjectChanges,
            onObjectChange: { key, change in
                if let change {
                    pendingObjectChanges[key] = change
                } else {
                    pendingObjectChanges.removeValue(forKey: key)
                }
            },
            onAddMissingItem: {
                missingItemTarget = MissingItemTarget(room: room)
            },
            onRoomTypeChange: { value in
                Task { await updateRoomType(roomId: room.roomId, to: value) }
            },
            isUpdatingRoomType: updatingRoomTypeIds.contains(room.roomId),
            onSplitRoom: { beginSplit(room) },
            onUndoSplit: undo,
            onSetFloor: {
                roomFloorDraft = room.floor ?? ""
                floorTargetRoom = room
            },
            onDeleteRoom: delete,
            onAttachmentsChanged: { updated in applyAttachmentChange(updated) }
        )
    }

    private struct SplitTarget: Identifiable {
        let room: FloorPlan.Room
        var id: String { room.roomId }
    }

    @MainActor
    private func beginSplit(_ room: FloorPlan.Room) {
        guard pendingObjectChanges.isEmpty else {
            VuuroToast.shared.show(vuuroLocalized("Save or discard your changes before splitting a room."))
            return
        }
        splitTarget = SplitTarget(room: room)
    }

    @MainActor
    private func applySplitResult(_ updated: FloorPlan, mode: ScanServiceClient.RoomSplitMode) {
        splitTarget = nil
        applyRoomChange(updated)
        VuuroToast.shared.show(
            vuuroLocalized(mode == .split ? "Room split in two" : "Room trimmed"),
            undoLabel: vuuroLocalized("Undo"),
            duration: 8
        ) {
            startUndoSplit()
        }
    }

    @MainActor
    private func startUndoSplit() {
        guard !isUndoingSplit else { return }
        isUndoingSplit = true
        Task { await undoSplit() }
    }

    @MainActor
    private func undoSplit() async {
        defer { isUndoingSplit = false }
        do {
            let updated = try await client.undoRoomSplit(sessionId: entry.sessionId, accessToken: entry.accessToken)
            applyRoomChange(updated)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomSplit, underlying: error)
        }
    }

    @MainActor
    private var canDeleteRooms: Bool {
        (floorPlan?.rooms.count ?? 0) > 1
    }

    @MainActor
    private func moveRoom(_ room: FloorPlan.Room, toFloor floor: String?) async {
        do {
            let updated = try await client.updateRoomFloor(sessionId: entry.sessionId, accessToken: entry.accessToken, roomId: room.roomId, floor: floor)
            applyRoomChange(updated)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomFloorUpdate, underlying: error)
        }
    }

    @MainActor
    private func deleteRoom(_ room: FloorPlan.Room) async {
        do {
            let updated = try await client.deleteRoom(sessionId: entry.sessionId, accessToken: entry.accessToken, roomId: room.roomId)
            applyRoomChange(updated)
            VuuroToast.shared.show(vuuroLocalized("Room deleted"))
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomDelete, underlying: error)
        }
    }

    private func applyRoomChange(_ updated: FloorPlan) {
        floorPlan = updated
        cacheRoomBreakdown(updated)
        discardRenderedExports()
        Task { await loadImage() }
    }

    private var saveChangesBar: some View {
        HStack(spacing: 10) {
            Button {
                pendingObjectChanges.removeAll()
            } label: {
                Text("Discard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VuuroColor.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("report.discardChanges")
            .buttonStyle(.plain)
            .disabled(isSavingChanges)

            Button {
                Task { await saveObjectChanges() }
            } label: {
                if isSavingChanges {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    Text("Save changes")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .accessibilityIdentifier("report.saveChanges")
            .buttonStyle(.plain)
            .background(VuuroColor.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(isSavingChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    @MainActor
    private func updateRoomType(roomId: String, to value: String?) async {
        updatingRoomTypeIds.insert(roomId)
        defer { updatingRoomTypeIds.remove(roomId) }
        do {
            let updated = try await client.updateRoomType(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                roomId: roomId,
                roomType: value
            )
            floorPlan = updated
            cacheRoomBreakdown(updated)
            discardRenderedExports()
            await loadImage()
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomTypeUpdate, underlying: error)
        }
    }

    @MainActor
    private func applyAttachmentChange(_ updated: FloorPlan) {
        floorPlan = updated
        cacheRoomBreakdown(updated)
        discardRenderedExports()
        Task { await loadImage() }
    }

    @MainActor
    private func discardRenderedExports() {
        FloorPlanImageCache.shared.invalidate(sessionId: entry.sessionId)
        ExportNaming.removeExports(sessionId: entry.sessionId)
        planRevision += 1
        floorPlanImage = nil
        imageFailed = false
        shareImageURL = nil
        pdfURL = nil
        usdzURL = nil
    }

    @MainActor
    private func saveObjectChanges() async {
        guard !isSavingChanges, !pendingObjectChanges.isEmpty else { return }
        isSavingChanges = true
        defer { isSavingChanges = false }

        let requests: [ObjectChangeRequest] = pendingObjectChanges.map { key, change in
            ObjectChangeRequest(
                roomId: key.roomId,
                objectId: key.objectId,
                customName: change.delete == true ? nil : change.customName,
                customNameChanged: change.delete != true && change.customNameChanged,
                excluded: change.delete == true ? nil : change.excluded,
                delete: change.delete == true ? true : nil
            )
        }

        do {
            let updated = try await client.batchUpdateObjects(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                changes: requests
            )
            floorPlan = updated
            cacheRoomBreakdown(updated)
            pendingObjectChanges.removeAll()
            discardRenderedExports()
            await loadImage()
            withAnimation(.easeInOut(duration: 0.2)) { saveSuccessVisible = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { saveSuccessVisible = false }
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomTypeUpdate, underlying: error)
        }
    }

    private var continueFloorOptions: [String] {
        var seen = Set<String>()
        var floors: [String] = []
        let candidates = [entry.floor ?? ""] + (floorPlan?.rooms.map { $0.floor ?? "" } ?? [])
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(trimmed.lowercased()).inserted {
                floors.append(trimmed)
            }
        }
        floors.removeAll { $0.isEmpty }
        return floors.sorted { HomeAggregator.floorRank($0) > HomeAggregator.floorRank($1) }
    }

    private var continueScanMessage: String {
        let isUnitScan = floorPlan?.rooms.contains { $0.captureGroupId != nil && $0.structureOriginM != nil } ?? false
        if isUnitScan {
            return vuuroLocalized("If this phone recognises the rooms you already scanned, new rooms join this plan. Otherwise they get their own section, and you can place them by hand. Only scan rooms that are not in the plan yet.")
        }
        return vuuroLocalized("New rooms are added to this report as their own section. They are not joined to the rooms you already scanned, so only scan rooms that are not in the plan yet.")
    }

    private var continueScanButton: some View {
        Button {
            showContinueChoices = true
        } label: {
            Label("Continue this scan", systemImage: "plus.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.vuuroPrimary)
        .accessibilityIdentifier("report.continueScan")
        .accessibilityHint("Scan more rooms or another floor into this report")
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var placementBanner: some View {
        if let plan = floorPlan {
            PlacementBannerView(rooms: plan.rooms) { target in
                placementTarget = target
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if let deletionStatus, deletionStatus.requested {
                Text(deletionRequestedText(deletionStatus))
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("report.deletionRequestedNotice")
                Button {
                    Task { await cancelDeletionRequest() }
                } label: {
                    if isRequestingDeletion {
                        ProgressView().tint(VuuroColor.textPrimary)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Cancel deletion request", systemImage: "arrow.uturn.backward.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("report.cancelDeletionRequest")
                .buttonStyle(.vuuroGhostSmall)
                .disabled(isRequestingDeletion)
            } else if deletionStatus?.requestsEnabled != false {
                Button {
                    showDeletionRequestConfirmation = true
                } label: {
                    if isRequestingDeletion {
                        ProgressView().tint(VuuroColor.textPrimary)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Request deletion (tenant)", systemImage: "person.crop.circle.badge.xmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("report.requestDeletion")
                .buttonStyle(.vuuroGhostSmall)
                .disabled(isRequestingDeletion)
            }

            Button("Forget this scan", role: .destructive) {
                showForgetConfirmation = true
            }
            .accessibilityIdentifier("report.forget")
            .buttonStyle(.vuuroGhostSmall)

            Button("Delete from server", role: .destructive) {
                showServerDeleteConfirmation = true
            }
            .accessibilityIdentifier("report.deleteFromServer")
            .buttonStyle(.vuuroDestructiveSmall)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func cacheRoomBreakdown(_ plan: FloorPlan) {
        ScanHistoryStore.shared.updateRoomSummary(
            sessionId: entry.sessionId,
            summary: RoomSummary.text(for: plan.rooms),
            floorAreaM2: plan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
        )
        ScanHistoryStore.shared.updateRoomsByFloor(
            sessionId: entry.sessionId,
            roomsByFloor: CachedFloorSummary.buckets(from: plan.rooms)
        )
    }

    @MainActor
    private func prepareUSDZ(forPreview: Bool) async {
        guard !isExportingUSDZ, let floorPlan, !floorPlan.rooms.isEmpty else { return }
        isExportingUSDZ = true
        defer { isExportingUSDZ = false }
        let rooms = floorPlan.rooms
        let sessionId = entry.sessionId
        let propertyId = entry.propertyId
        let unitId = entry.unitId
        do {
            PerfTrace.begin(.usdzExport)
            let url = try ExportNaming.url(
                sessionId: sessionId,
                property: propertyId,
                unit: unitId,
                room: nil,
                date: Date(),
                suffix: "dollhouse",
                ext: "usdz"
            )
            try await Task.detached(priority: .userInitiated) {
                let scene = try DollhouseMeshBuilder.buildForExport(rooms: rooms)
                try DollhouseUSDZExporter.export(scene, to: url)
            }.value
            PerfTrace.end(.usdzExport, detail: "\(rooms.count) rooms")
            if let old = usdzURL, FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.removeItem(at: old)
            }
            usdzURL = url
            if forPreview {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int,
                   size > 100 * 1024 * 1024 {
                    VuuroToast.shared.show(vuuroLocalized("This 3D model is too large to open in AR. Try sharing it as a file instead."))
                    return
                }
                ARQuickLookPresenter.shared.present(url: url)
            } else {
                ShareSheetPresenter.present(items: [url])
            }
        } catch is CancellationError {
        } catch DollhouseMeshBuilderError.tooManyTriangles {
            VuuroToast.shared.show(vuuroLocalized("This 3D model has too many details to export."))
        } catch {
            appError = AppError(site: .dollhouseExport, underlying: error)
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let sessionFetch = Task { @MainActor in
            do {
                let fetched = try await client.fetchSession(
                    sessionId: entry.sessionId,
                    accessToken: entry.accessToken
                )
                floorPlan = fetched
                cacheRoomBreakdown(fetched)
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
        let deletionFetch = Task { @MainActor in
            await loadDeletionStatus()
        }
        await sessionFetch.value
        await imageFetch.value
        await deletionFetch.value
    }

    @MainActor
    private func loadDeletionStatus() async {
        guard !entry.accessToken.isEmpty else { return }
        do {
            deletionStatus = try await client.fetchDeletionStatus(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken
            )
        } catch is CancellationError {
        } catch {
            DiagnosticsLog.shared.record(
                "Deletion status fetch failed for \(entry.sessionId): \(error.localizedDescription)",
                category: .error
            )
        }
    }

    private func deletionRequestedText(_ status: ScanServiceClient.RequestDeletionResponse) -> String {
        guard let purgeAfter = status.purgeAfter,
              let date = ISO8601DateFormatter().date(from: purgeAfter) else {
            return String(format: vuuroLocalized("Deletion requested. This scan is removed from the server after a %d-day grace period."), status.gracePeriodDays)
        }
        let formatted = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguageSettings.effectiveLocale))
        return String(format: vuuroLocalized("Deletion requested. This scan is removed from the server after %@."), formatted)
    }

    @MainActor
    private func cancelDeletionRequest() async {
        guard !isRequestingDeletion else { return }
        isRequestingDeletion = true
        defer { isRequestingDeletion = false }
        do {
            deletionStatus = try await client.cancelSessionDeletion(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken
            )
            VuuroToast.shared.show(vuuroLocalized("Deletion request cancelled"))
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .historyServerDelete, underlying: error)
        }
    }

    @MainActor
    private func loadImage() async {
        if floorPlanImage != nil { return }
        if let floorPlan, floorPlan.rooms.isEmpty { return }

        imageFailed = false
        PerfTrace.begin(.resultPlanImage)
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

        let decodedImage: UIImage?
        if let data {
            decodedImage = await ImageDecoding.decoded(data)
        } else {
            decodedImage = nil
        }
        guard let image = decodedImage else {
            PerfTrace.cancel(.resultPlanImage)
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
        PerfTrace.end(.resultPlanImage, detail: alreadyCached ? "cache" : "network")
    }

    @ViewBuilder
    private func separatePlans(_ floorPlan: FloorPlan) -> some View {
        if SeparatePlansSection.hasSeveralFloors(floorPlan.rooms) && PlanBlock.blocks(for: floorPlan.rooms).count < 2 {
            SeparatePlansSection(
                rooms: floorPlan.rooms,
                loadingTarget: loadingPlanTarget,
                onOpen: { target in
                    Task { await openPlan(target) }
                }
            )
        }
    }

    @MainActor
    private func openPlan(_ target: PlanTarget) async {
        guard loadingPlanTarget == nil else { return }
        loadingPlanTarget = target
        defer { loadingPlanTarget = nil }
        do {
            let data = try await client.fetchFloorPlanImage(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                unit: exportUnit,
                roomId: target.roomId,
                floor: target.floor
            )
            guard let decoded = UIImage(data: data) else {
                throw PlainError(message: "The floor plan image came back from the Scan Service but could not be decoded.")
            }
            previewImage = PreviewImage(image: decoded)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func shareImage() async {
        if let existing = shareImageURL, FileManager.default.fileExists(atPath: existing.path) {
            ShareSheetPresenter.present(items: [existing])
            return
        }
        do {
            let data = try await client.fetchFloorPlanImage(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken,
                unit: exportUnit,
                label: entry.nickname
            )
            let url = try ExportNaming.url(
                sessionId: entry.sessionId,
                property: entry.propertyId,
                unit: entry.unitId,
                room: nil,
                date: entry.createdAt,
                suffix: "floorplan",
                ext: "png"
            )
            try data.write(to: url, options: .atomic)
            shareImageURL = url
            ShareSheetPresenter.present(items: [url])
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
        guard let pdfURL else { return }
        ShareSheetPresenter.present(items: [pdfURL])
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
            let url = try ExportNaming.url(
                sessionId: entry.sessionId,
                property: entry.propertyId,
                unit: entry.unitId,
                room: nil,
                date: entry.createdAt,
                suffix: "floorplan",
                ext: "pdf"
            )
            try data.write(to: url, options: .atomic)
            pdfURL = url
            appError = nil
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .resultPDFLoad, underlying: error)
        }
    }

    @MainActor
    private func requestDeletion() async {
        guard !isRequestingDeletion else { return }
        isRequestingDeletion = true
        defer { isRequestingDeletion = false }
        do {
            let result = try await client.requestSessionDeletion(
                sessionId: entry.sessionId,
                accessToken: entry.accessToken
            )
            deletionStatus = result
            VuuroToast.shared.show(String(format: vuuroLocalized("Deletion requested — removed after %d days"), result.gracePeriodDays))
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .historyServerDelete, underlying: error)
            if case ScanServiceError.unexpectedStatus(403, _) = error {
                await loadDeletionStatus()
            }
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