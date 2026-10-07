import QuickLook
import SwiftUI
import UIKit

struct ResultSummaryView: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onDone: () -> Void

    @State private var currentFloorPlan: FloorPlan
    @State private var pendingObjectChanges: [ObjectChangeKey: PendingObjectChange] = [:]
    @State private var isSavingChanges = false
    @State private var floorPlanImage: UIImage?
    @State private var isLoadingImage = false
    @State private var imageFailed = false
    @State private var pdfURL: URL?
    @State private var previewImage: PreviewImage?
    @State private var showPDFPreview = false
    @State private var isFetchingPDF = false
    @State private var planRevision = 0
    @State private var showForgetConfirmation = false
    @State private var showUnsavedChangesAlert = false
    @State private var appError: AppError?
    @State private var placementTarget: PlacementTarget?
    @State private var saveSuccessVisible = false
    @State private var missingItemTarget: MissingItemTarget?
    @State private var updatingRoomTypeIds: Set<String> = []
    @State private var splitTarget: SplitTarget?
    @State private var isUndoingSplit = false
    @State private var floorTargetRoom: FloorPlan.Room?
    @State private var deleteTargetRoom: FloorPlan.Room?
    @State private var roomFloorDraft = ""
    @State private var loadingPlanTarget: PlanTarget?
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue
    @State private var exportStyle: ExportStyleSettings = ExportStyleSettings.load()
    @State private var savedExportStyle: ExportStyleSettings = ExportStyleSettings.load()

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private let client = ScanServiceClient()

    private var totalAreaM2: Double {
        currentFloorPlan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
    }

    private var hasPendingChanges: Bool {
        !pendingObjectChanges.isEmpty || exportStyle != savedExportStyle
    }

    init(session: ScanSessionResponse, floorPlan: FloorPlan, onDone: @escaping () -> Void) {
        self.session = session
        self.floorPlan = floorPlan
        self.onDone = onDone
        _currentFloorPlan = State(initialValue: floorPlan)
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Scan result",
                leading: { VuuroNavSpacer() },
                trailing: {
                    Button("Done") {
                        if hasPendingChanges {
                            showUnsavedChangesAlert = true
                        } else {
                            onDone()
                        }
                    }
                    .accessibilityIdentifier("result.done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
                    .disabled(isSavingChanges)
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summaryHero
                    if let warnings = currentFloorPlan.roomSplitWarnings, !warnings.isEmpty {
                        splitWarningBanner(warnings)
                    }
                    if !currentFloorPlan.rooms.isEmpty {
                        if RoomGridSection.shows(for: currentFloorPlan.rooms) {
                            RoomGridSection(
                                rooms: currentFloorPlan.rooms,
                                sessionId: session.id,
                                accessToken: session.accessToken,
                                unit: exportUnit,
                                refreshKey: "\(planRevision)",
                                identifierPrefix: "result",
                                imageActionLabel: "View image",
                                imageActionIdentifier: "result.viewImage",
                                isFetchingPDF: isFetchingPDF,
                                onOpen: { image in previewImage = PreviewImage(image: image) },
                                onImageAction: { Task { await fetchAndPreviewImage() } },
                                onViewPDF: { Task { await fetchAndPreviewPDF() } }
                            )
                        } else {
                            floorPlanCard
                        }
                        placementBanner
                        separatePlans
                        ExportStyleSection(style: $exportStyle)
                    }
                    ForEach(RoomFloorSection.sections(for: currentFloorPlan.rooms)) { section in
                        if let title = section.title {
                            RoomFloorSectionHeader(title: title)
                        }
                        ForEach(section.rooms, id: \.roomId) { room in
                            roomCard(room)
                        }
                    }

                    if !currentFloorPlan.photos.filter({ $0.roomId == nil }).isEmpty
                        || !currentFloorPlan.notes.filter({ $0.roomId == nil }).isEmpty {
                        unitAttachmentsCard
                    }

                    accessLogLink
                    actionButtons

                    if let appError {
                        ErrorCodeView(error: appError)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer().frame(height: 24)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
        .task { await loadImage() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasPendingChanges {
                saveBar
            }
        }
        .overlay(alignment: .top) {
            if saveSuccessVisible {
                Text("Changes saved")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $previewImage) { preview in
            ImagePreviewView(image: preview.image) {
                previewImage = nil
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
                        .accessibilityIdentifier("result.pdfErrorClose")
                        .buttonStyle(.vuuroPrimary)
                        .frame(maxWidth: 200)
                    }
                }
            }
        }
        .sheet(item: $missingItemTarget) { target in
            MissingItemSheet(
                session: session,
                room: target.room,
                onSaved: { updated in
                    currentFloorPlan = updated
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
                session: session,
                room: target.room,
                onSaved: { updated, mode in applySplitResult(updated, mode: mode) },
                onCancel: { splitTarget = nil }
            )
            .presentationDetents([.large])
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
                ScanHistoryStore.shared.remove(sessionId: session.id)
                onDone()
            }
            .accessibilityIdentifier("result.forgetConfirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("result.forgetCancel")
        } message: {
            Text("This removes the local record on this device. Server data isn't affected.")
        }
        .alert("Unsaved changes", isPresented: $showUnsavedChangesAlert) {
            Button("Save and leave") {
                Task {
                    appError = nil
                    await saveChanges()
                    if appError == nil {
                        onDone()
                    }
                }
            }
            .accessibilityIdentifier("result.unsavedSaveAndLeave")
            Button("Discard and leave", role: .destructive) {
                pendingObjectChanges.removeAll()
                exportStyle = savedExportStyle
                onDone()
            }
            .accessibilityIdentifier("result.unsavedDiscardAndLeave")
            Button("Stay", role: .cancel) {}
                .accessibilityIdentifier("result.unsavedStay")
        } message: {
            Text("You have unsaved edits on this scan.")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .sheet(item: $placementTarget) { target in
            GroupPlacementView(
                session: session,
                floorPlan: currentFloorPlan,
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

    private struct PreviewImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private struct MissingItemTarget: Identifiable {
        let room: FloorPlan.Room
        var id: String { room.roomId }
    }

    @MainActor
    private func roomCard(_ room: FloorPlan.Room) -> RoomResultCard {
        var delete: (() -> Void)? = nil
        if canDeleteRooms {
            delete = { deleteTargetRoom = room }
        }
        var undo: (() -> Void)? = nil
        if currentFloorPlan.lastSplitRoomIds.contains(room.roomId) {
            undo = { startUndoSplit() }
        }
        return RoomResultCard(
            room: room,
            showsRibbon: false,
            photos: currentFloorPlan.photos.filter { $0.roomId == room.roomId },
            notes: currentFloorPlan.notes.filter { $0.roomId == room.roomId },
            session: session,
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
            onDeleteRoom: delete
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

    private func splitWarningBanner(_ warnings: [FloorPlan.RoomSplitWarning]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "scissors")
                .foregroundStyle(VuuroColor.danger)
            Text(String(
                format: vuuroLocalized("%ld room split(s) could not be re-applied because the room changed in this scan (%@). Split the room again if you still need it."),
                warnings.count,
                warnings.map(\.roomLabel).joined(separator: ", ")
            ))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(VuuroColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.dangerTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityIdentifier("result.splitWarning")
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
            let updated = try await client.undoRoomSplit(sessionId: session.id, accessToken: session.accessToken)
            applyRoomChange(updated)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomSplit, underlying: error)
        }
    }

    @MainActor
    private var canDeleteRooms: Bool {
        currentFloorPlan.rooms.count > 1
    }

    @MainActor
    private func moveRoom(_ room: FloorPlan.Room, toFloor floor: String?) async {
        do {
            let updated = try await client.updateRoomFloor(sessionId: session.id, accessToken: session.accessToken, roomId: room.roomId, floor: floor)
            applyRoomChange(updated)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomFloorUpdate, underlying: error)
        }
    }

    @MainActor
    private func deleteRoom(_ room: FloorPlan.Room) async {
        do {
            let updated = try await client.deleteRoom(sessionId: session.id, accessToken: session.accessToken, roomId: room.roomId)
            applyRoomChange(updated)
            VuuroToast.shared.show(vuuroLocalized("Room deleted"))
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomDelete, underlying: error)
        }
    }

    private func applyRoomChange(_ updated: FloorPlan) {
        currentFloorPlan = updated
        ScanHistoryStore.shared.updateRoomSummary(
            sessionId: session.id,
            summary: RoomSummary.text(for: updated.rooms),
            floorAreaM2: updated.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
        )
        ScanHistoryStore.shared.updateRoomsByFloor(
            sessionId: session.id,
            roomsByFloor: CachedFloorSummary.buckets(from: updated.rooms)
        )
        discardRenderedExports()
        Task { await loadImage() }
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            Button {
                pendingObjectChanges.removeAll()
                exportStyle = savedExportStyle
            } label: {
                Text("Discard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VuuroColor.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("result.discardChanges")
            .buttonStyle(.plain)
            .disabled(isSavingChanges)

            Button {
                Task { await saveChanges() }
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
            .accessibilityIdentifier("result.saveChanges")
            .buttonStyle(.plain)
            .background(VuuroColor.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(isSavingChanges)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    private var summaryHero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(VuuroColor.lime.opacity(0.20))
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(VuuroColor.goodText)
            }
            .frame(width: 64, height: 64)

            Text(summaryTitle)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(VuuroColor.textPrimary)

            Text(summarySubtitle)
                .font(.system(size: 15))
                .foregroundStyle(VuuroColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private var summaryTitle: String {
        let count = currentFloorPlan.rooms.count
        if count == 0 { return vuuroLocalized("Notes-only session") }
        return vuuroLocalized(count == 1 ? "Room captured" : "Unit captured")
    }

    private var summarySubtitle: String {
        let count = currentFloorPlan.rooms.count
        if count == 0 {
            let notes = currentFloorPlan.notes.count
            let photos = currentFloorPlan.photos.count
            return "\(notes) note\(notes == 1 ? "" : "s") \u{00B7} \(photos) photo\(photos == 1 ? "" : "s")"
        }
        let roomsText = "\(count) room\(count == 1 ? "" : "s")"
        let areaText = String(format: "%.1f m\u{00B2} total", totalAreaM2)
        return "\(roomsText) \u{00B7} \(areaText)"
    }

    private var floorPlanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Floor plan")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)
                Spacer()
                VuuroBadge("\(currentFloorPlan.rooms.count) room\(currentFloorPlan.rooms.count == 1 ? "" : "s")", style: .info)
            }

            if PlanBlock.blocks(for: currentFloorPlan.rooms).count >= 2 {
                PlanBlocksCarousel(
                    blocks: PlanBlock.blocks(for: currentFloorPlan.rooms),
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    unit: exportUnit,
                    refreshKey: "\(planRevision)",
                    identifierPrefix: "result",
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
                        schematicPlaceholder
                    } else {
                        ProgressView().tint(VuuroColor.accent)
                    }
                }
                .vuuroPlanFrame()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard floorPlanImage != nil else { return }
                    Task { await fetchAndPreviewImage() }
                }
                .accessibilityIdentifier("result.floorPlanPreview")
            }

            if currentFloorPlan.rooms.count > 1 {
                RoomPlanStrip(
                    rooms: currentFloorPlan.rooms,
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    unit: exportUnit,
                    onOpen: { image in previewImage = PreviewImage(image: image) }
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task { await fetchAndPreviewImage() }
                } label: {
                    Text("View image")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("result.viewImage")
                .buttonStyle(.vuuroOutlineSmall)

                Button {
                    Task { await fetchAndPreviewPDF() }
                } label: {
                    if isFetchingPDF {
                        ProgressView().tint(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("View PDF")
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("result.viewPDF")
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

    private var schematicPlaceholder: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(currentFloorPlan.rooms, id: \.roomId) { room in
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(VuuroColor.accent.opacity(0.06))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(VuuroColor.accent.opacity(0.55), lineWidth: 2)
                    Text(room.label)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(VuuroColor.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
                .frame(height: 68)
            }
        }
        .padding(12)
    }

    private var unitAttachmentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whole unit")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(VuuroColor.textSecondary)
            RoomAttachmentsList(
                session: session,
                photos: currentFloorPlan.photos.filter { $0.roomId == nil },
                notes: currentFloorPlan.notes.filter { $0.roomId == nil }
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

    private var accessLogLink: some View {
        NavigationLink {
            AccessLogView(sessionId: session.id, accessToken: session.accessToken)
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
        .accessibilityIdentifier("result.accessLog")
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var placementBanner: some View {
        PlacementBannerView(rooms: currentFloorPlan.rooms) { target in
            placementTarget = target
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button("Save & return home") {
                Task {
                    appError = nil
                    if hasPendingChanges {
                        await saveChanges()
                    }
                    if appError == nil {
                        onDone()
                    }
                }
            }
            .accessibilityIdentifier("result.saveAndReturnHome")
            .buttonStyle(.vuuroPrimary)
            .disabled(isSavingChanges)

            Button("Forget this scan", role: .destructive) {
                showForgetConfirmation = true
            }
            .accessibilityIdentifier("result.deleteScan")
            .buttonStyle(.vuuroGhostSmall)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @MainActor
    private func loadImage() async {
        guard !currentFloorPlan.rooms.isEmpty, floorPlanImage == nil, !isLoadingImage else { return }
        isLoadingImage = true
        defer { isLoadingImage = false }

        if let cached = FloorPlanImageCache.shared.cachedData(sessionId: session.id, unit: exportUnit),
           let decoded = UIImage(data: cached) {
            floorPlanImage = decoded
            return
        }

        let data = await FloorPlanImageCache.shared.prefetch(
            sessionId: session.id,
            accessToken: session.accessToken,
            unit: exportUnit,
            client: client
        ).value

        guard let data, let image = UIImage(data: data) else {
            imageFailed = true
            return
        }
        floorPlanImage = image
    }

    @MainActor
    private func saveChanges() async {
        guard !isSavingChanges, hasPendingChanges else { return }
        isSavingChanges = true
        defer { isSavingChanges = false }

        let styleChanged = exportStyle != savedExportStyle
        if styleChanged {
            exportStyle.save()
            savedExportStyle = exportStyle
            FloorPlanImageCache.shared.clearAll()
            ExportNaming.removeAllExports()
        }

        guard !pendingObjectChanges.isEmpty else {
            discardRenderedExports()
            await loadImage()
            await showSaveSuccess()
            return
        }

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
                sessionId: session.id,
                accessToken: session.accessToken,
                changes: requests
            )
            currentFloorPlan = updated
            pendingObjectChanges.removeAll()
            discardRenderedExports()
            await loadImage()
            await showSaveSuccess()
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomTypeUpdate, underlying: error)
            if styleChanged {
                discardRenderedExports()
                await loadImage()
            }
        }
    }

    @MainActor
    private func showSaveSuccess() async {
        withAnimation(.easeInOut(duration: 0.2)) {
            saveSuccessVisible = true
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        withAnimation(.easeInOut(duration: 0.2)) {
            saveSuccessVisible = false
        }
    }

    @MainActor
    private func updateRoomType(roomId: String, to value: String?) async {
        updatingRoomTypeIds.insert(roomId)
        defer { updatingRoomTypeIds.remove(roomId) }
        do {
            let updated = try await client.updateRoomType(
                sessionId: session.id,
                accessToken: session.accessToken,
                roomId: roomId,
                roomType: value
            )
            currentFloorPlan = updated
            ScanHistoryStore.shared.updateRoomSummary(sessionId: session.id, summary: RoomSummary.text(for: updated.rooms))
            discardRenderedExports()
            await loadImage()
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .roomTypeUpdate, underlying: error)
        }
    }

    @MainActor
    private func discardRenderedExports() {
        FloorPlanImageCache.shared.invalidate(sessionId: session.id)
        ExportNaming.removeExports(sessionId: session.id)
        planRevision += 1
        floorPlanImage = nil
        imageFailed = false
        pdfURL = nil
    }

    @ViewBuilder
    private var separatePlans: some View {
        if SeparatePlansSection.hasSeveralFloors(currentFloorPlan.rooms) && PlanBlock.blocks(for: currentFloorPlan.rooms).count < 2 {
            SeparatePlansSection(
                rooms: currentFloorPlan.rooms,
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
                sessionId: session.id,
                accessToken: session.accessToken,
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
    private func fetchAndPreviewImage() async {
        if floorPlanImage == nil {
            await loadImage()
        }
        if let floorPlanImage {
            previewImage = PreviewImage(image: floorPlanImage)
            return
        }
        do {
            let data = try await client.fetchFloorPlanImage(
                sessionId: session.id,
                accessToken: session.accessToken,
                unit: exportUnit
            )
            guard let decoded = UIImage(data: data) else {
                throw PlainError(message: "The floor plan image came back from the Scan Service but could not be decoded.")
            }
            floorPlanImage = decoded
            imageFailed = false
            previewImage = PreviewImage(image: decoded)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func fetchAndPreviewPDF() async {
        guard !isFetchingPDF else { return }
        isFetchingPDF = true
        defer { isFetchingPDF = false }

        if let existing = pdfURL, FileManager.default.fileExists(atPath: existing.path) {
            showPDFPreview = true
            return
        }

        do {
            let data = try await client.fetchFloorPlanPDF(
                sessionId: session.id,
                accessToken: session.accessToken,
                unit: exportUnit
            )
            let url = try ExportNaming.url(
                sessionId: session.id,
                property: session.propertyId,
                unit: session.unitId,
                room: nil,
                date: Date(),
                suffix: "floorplan",
                ext: "pdf"
            )
            try data.write(to: url, options: .atomic)
            pdfURL = url
            showPDFPreview = true
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .resultPDFLoad, underlying: error)
        }
    }
}
