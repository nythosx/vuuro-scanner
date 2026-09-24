import RoomPlan
import SwiftUI

struct MultiRoomCaptureFlowView: View {
    let identity: ScanIdentity
    let existingSession: ScanSessionResponse?
    let onFinished: (ScanSessionResponse, FloorPlan) -> Void
    let onError: (AppError, ScanSessionResponse?) -> Void
    let onGoBack: () -> Void

    @StateObject private var coordinator = MultiRoomCaptureCoordinator()
    @StateObject private var uploadProgress = UploadProgressCoordinator()
    @State private var isUploading = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var didRequestStopRoom = false
    @State private var isFinishingUnit = false
    @State private var isDegenerateCapture = false
    @State private var showFinishConfirmation = false
    @State private var pendingFinishUnit = false
    @State private var partialRoomFailureMessage: String?
    @State private var showCapturedRoomsList = false
    @State private var showDiscardConfirmation = false
    @State private var showMultiFloorPrompt = false
    @State private var capturedLocation: CaptureLocation?
    @State private var capturedHeadingDeg: Double?
    @State private var preUploadedSession: (session: ScanSessionResponse, floorPlan: FloorPlan)?
    @State private var roomTypeGuessOn = RoomTypeGuessSettings.isEnabled
    @State private var didStart = false
    @State private var showCorrectionDialog = false
    @State private var capturedFloor: String = ""
    @Environment(\.scenePhase) private var scenePhase

    private let client = ScanServiceClient()
    private let locationProvider = LocationProvider()
    private let headingProvider = HeadingProvider()

    private var debugFakeCaptureActive: Bool {
        #if DEBUG
        FakeLidarMode.isEnabled
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if !DeviceCapability.isRoomPlanSupported && !debugFakeCaptureActive {
                UnsupportedDeviceScreen(onGoBack: onGoBack)
            } else if !DeviceCapability.isRoomPlanSupported && !isUploading {
                #if DEBUG
                VuuroCenterView {
                    VuuroIconBadge(systemName: "wand.and.stars", tint: VuuroColor.accent, background: VuuroColor.accentSoft)
                    Text("Debug: fake multi-room capture")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(VuuroColor.textPrimary)
                    Text("This device/simulator has no LiDAR. Tap Scan to generate 2-4 synthetic rooms and upload them to the configured Scan Service.")
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(VuuroColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    Button("Scan (fake data)") {
                        uploadTask = Task {
                            let exports = (0..<Int.random(in: 2...4)).map { _ in FakeCaptureGenerator.random() }
                            if let result = await submitExports(exports) {
                                onFinished(result.session, result.floorPlan)
                            }
                        }
                    }
                    .accessibilityIdentifier("multiCapture.fakeScan")
                    .buttonStyle(.vuuroPrimary)
                    .padding(.top, 12)
                    .frame(maxWidth: 340)
                }
                #else
                EmptyView()
                #endif
            } else if isFinishingUnit {
                MergingView(
                    title: "Combining your rooms",
                    subtitle: "Aligning floors and removing duplicate walls.",
                    steps: mergeSteps,
                    onCancel: { coordinator.cancelMerge() }
                )
            } else if isUploading {
                UploadingView(
                    coordinator: uploadProgress,
                    onPause: { uploadTask?.cancel() }
                )
            } else {
                ZStack {
                    MultiRoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

                    if isDegenerateCapture {
                        resolutionOverlay {
                            DegenerateCaptureView {
                                isDegenerateCapture = false
                                coordinator.start()
                            }
                        }
                    } else if let partialRoomFailureMessage {
                        resolutionOverlay {
                            PartialRoomChoiceView(
                                message: partialRoomFailureMessage,
                                onKeep: {
                                    self.partialRoomFailureMessage = nil
                                    coordinator.keepPendingPartialRoom()
                                    continueAfterRoomResolved()
                                },
                                onDiscard: {
                                    self.partialRoomFailureMessage = nil
                                    coordinator.discardPendingPartialRoom()
                                    continueAfterRoomResolved()
                                }
                            )
                        }
                    } else if didRequestStopRoom {
                        ProgressView("Finishing room…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if coordinator.state == .scanning {
                        multiCaptureOverlay
                    }
                }
                .onAppear {
                    guard !didStart else { return }
                    didStart = true
                    capturedFloor = (existingSession?.defaultFloor ?? identity.floor ?? "")
                    coordinator.start()
                    Task { capturedLocation = await locationProvider.currentLocation() }
                    Task { capturedHeadingDeg = await headingProvider.currentHeadingDeg() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background, coordinator.state == .scanning {
                        DiagnosticsLog.shared.record(
                            "App backgrounded mid-scan (multi-room) — ARKit/RoomPlan behavior here is unverified.",
                            category: .state
                        )
                    }
                }
            }
        }
        .onChange(of: coordinator.state) { _, state in
            handle(state)
        }
        .alert("Discard this scan?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) { onGoBack() }
                .accessibilityIdentifier("multiCapture.discardConfirm")
            Button("Keep scanning", role: .cancel) {}
                .accessibilityIdentifier("multiCapture.keepScanning")
        } message: {
            Text("\(coordinator.capturedRooms.count) room(s) captured so far will be lost.")
        }
        .alert("Finish this unit?", isPresented: $showFinishConfirmation) {
            Button("Finish") {
                pendingFinishUnit = true
                didRequestStopRoom = true
                coordinator.stopCurrentRoom()
            }
            .accessibilityIdentifier("multiCapture.finishConfirm")
            Button("Keep scanning", role: .cancel) {}
                .accessibilityIdentifier("multiCapture.finishKeepScanning")
        } message: {
            Text("\(coordinator.capturedRooms.count) room(s) captured so far will be merged and uploaded.")
        }
        .sheet(isPresented: $showCapturedRoomsList) {
            CapturedRoomsListView(coordinator: coordinator)
        }
        .alert("Which floor?", isPresented: $showMultiFloorPrompt) {
            TextField("e.g. Attic, 1st floor", text: $capturedFloor)
                .accessibilityIdentifier("multiCapture.floorField")
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Save") {
                Task { await persistMultiFloor() }
            }
            .accessibilityIdentifier("multiCapture.floorSave")
            Button("Clear", role: .destructive) {
                capturedFloor = ""
                Task { await persistMultiFloor() }
            }
            .accessibilityIdentifier("multiCapture.floorClear")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("multiCapture.floorCancel")
        } message: {
            Text("Applies to the next room you scan, and to the rest of this session, until you change it.")
        }
        .portraitLocked()
    }

    @MainActor
    private func persistMultiFloor() async {
        guard let session = existingSession ?? preUploadedSession?.session else { return }
        let trimmed = capturedFloor.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await client.setDefaultFloor(
                sessionId: session.id,
                accessToken: session.accessToken,
                floor: trimmed.isEmpty ? nil : trimmed
            )
            capturedFloor = trimmed
            ScanHistoryStore.shared.updateFloor(sessionId: session.id, floor: trimmed.isEmpty ? nil : trimmed)
        } catch is CancellationError {
        } catch {
            DiagnosticsLog.shared.record("Failed to update default floor (multi-room): \(error.localizedDescription)", category: .error)
        }
    }



    private var roomHintText: String {
        let number = coordinator.capturedRooms.count + 1
        if let guess = coordinator.liveRoomTypeGuess {
            return "Room \(number) · \(RoomTypeClassifier.displayName(for: guess.type))"
        }
        return "Scanning room \(number)"
    }

    private var multiCaptureOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VuuroCaptureCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Discard scan"
                ) {
                    showDiscardConfirmation = true
                }
                .accessibilityIdentifier("multiCapture.cancel")
                Spacer(minLength: 0)
                VuuroCaptureTogglePill(isOn: roomTypeGuessOn) {
                    roomTypeGuessOn.toggle()
                    RoomTypeGuessSettings.isEnabled = roomTypeGuessOn
                    VuuroToast.shared.show(roomTypeGuessOn ? "Room-type guessing on" : "Room-type guessing off")
                }
                .accessibilityIdentifier("multiCapture.roomTypeGuessToggle")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer().frame(height: 24)

            VuuroScanRing(walls: coordinator.liveStats.walls)

            Spacer().frame(height: 14)

            VuuroScanHint(text: roomHintText)

            if let guess = coordinator.liveRoomTypeGuess, !coordinator.hasAnsweredRoomType {
                Spacer().frame(height: 20)
                multiGuessPill(for: guess)
            }

            Spacer(minLength: 20)

            if coordinator.capturedRooms.count >= MultiRoomCaptureCoordinator.roomCountWarningThreshold {
                Text("\(coordinator.capturedRooms.count) rooms captured — you may be approaching a device limit soon.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }

            if coordinator.isApproachingSizeLimit {
                Text("This room looks larger than RoomPlan's practical scanning range (~9m) — accuracy may degrade beyond this size.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }

            VuuroLiveStatsRow(stats: coordinator.liveStats)
                .padding(.horizontal, 20)

            Spacer().frame(height: 12)

            HStack(spacing: 10) {
                VuuroFinishRoomButton(label: "Save & next") {
                    didRequestStopRoom = true
                    coordinator.stopCurrentRoom()
                }
                .accessibilityIdentifier("multiCapture.saveAndNext")

                HStack(spacing: 8) {
                    Button {
                        showMultiFloorPrompt = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "building.2")
                                .font(.system(size: 11, weight: .semibold))
                            Text(capturedFloor.isEmpty ? "Set floor" : capturedFloor)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.black.opacity(0.4), in: Capsule())
                    }
                    .accessibilityIdentifier("multiCapture.floor")
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

                if !coordinator.capturedRooms.isEmpty {
                    VuuroRoomsButton(count: coordinator.capturedRooms.count) {
                        showCapturedRoomsList = true
                    }
                    .accessibilityIdentifier("multiCapture.rooms")

                    VuuroFinishSecondaryButton(label: "Finish") {
                        showFinishConfirmation = true
                    }
                    .accessibilityIdentifier("multiCapture.finish")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func multiGuessPill(for guess: RoomTypeClassifier.Guess) -> some View {
        VuuroCaptureGuessPill(
            typeName: RoomTypeClassifier.displayName(for: guess.type),
            onConfirm: { coordinator.confirmRoomTypeGuess() },
            onReject: { showCorrectionDialog = true }
        )
        .accessibilityIdentifier("multiCapture.roomTypeGuessPill")
        .confirmationDialog(
            "What kind of room is this?",
            isPresented: $showCorrectionDialog,
            titleVisibility: .visible
        ) {
            ForEach(RoomTypeClassifier.allTypes.filter { $0 != guess.type }, id: \.self) { type in
                Button(RoomTypeClassifier.displayName(for: type)) {
                    coordinator.rejectRoomTypeGuess(correctedTo: type)
                }
                .accessibilityIdentifier("multiCapture.roomType.\(type)")
            }
            Button("Other") {
                coordinator.rejectRoomTypeGuess(correctedTo: "other")
            }
            .accessibilityIdentifier("multiCapture.roomType.other")
            Button("Not sure", role: .cancel) {
                coordinator.rejectRoomTypeGuess(correctedTo: nil)
            }
            .accessibilityIdentifier("multiCapture.roomType.notSure")
        }
    }

    private var mergeSteps: [VuuroMergeStep] {
        var steps: [VuuroMergeStep] = []
        for index in coordinator.capturedRooms.indices {
            steps.append(VuuroMergeStep(label: "\(roomLabel(at: index)) aligned", isDone: true))
        }
        steps.append(VuuroMergeStep(label: "Fusing structure…", isDone: false))
        return steps
    }

    private func roomLabel(at index: Int) -> String {
        if coordinator.roomTypeConfirmations.indices.contains(index),
           let value = coordinator.roomTypeConfirmations[index]?.value {
            return RoomTypeClassifier.displayName(for: value)
        }
        return "Room \(index + 1)"
    }

    @ViewBuilder
    private func resolutionOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            content()
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
        }
    }

    private func handle(_ state: MultiRoomCaptureCoordinator.State) {
        switch state {
        case .scanning:
            break
        case .roomFinished(roomAvailable: true):
            didRequestStopRoom = false
            continueAfterRoomResolved()
        case .roomFinished(roomAvailable: false):
            didRequestStopRoom = false
            if pendingFinishUnit {
                continueAfterRoomResolved()
            } else {
                isDegenerateCapture = true
            }
        case .failed(let message, let partialRoomAvailable):
            didRequestStopRoom = false
            if partialRoomAvailable {
                partialRoomFailureMessage = message
            } else {
                continueAfterRoomResolved()
            }
        case .merging:
            isFinishingUnit = true
        case .unitFinished:
            guard let structure = coordinator.mergedStructure else { return }
            uploadTask = Task { await submitFused(structure) }
        case .mergeFailed(let message):
            isFinishingUnit = false
            finishWithPreUploadOrError(
                AppError(site: .captureFailed, underlying: PlainError(message: message))
            )
        case .mergeTimedOut, .mergeCancelled:
            isFinishingUnit = false
            finishWithPreUploadOrError(
                AppError(site: .captureFailed, underlying: PlainError(message: "Merging rooms didn't complete."))
            )
        }
    }

    private func finishWithPreUploadOrError(_ error: AppError) {
        if let preUploadedSession {
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, preUploadedSession.floorPlan)
        } else {
            onError(error, existingSession)
        }
    }

    private func continueAfterRoomResolved() {
        if pendingFinishUnit {
            pendingFinishUnit = false
            if coordinator.capturedRooms.isEmpty {
                onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
            } else {
                uploadTask = Task { await beginFinishUnit() }
            }
        } else {
            coordinator.start()
        }
    }

    @MainActor
    private func beginFinishUnit() async {
        isFinishingUnit = true
        let exports = coordinator.capturedRooms.indices.map { index in
            CapturedRoomExporter.export(
                coordinator.capturedRooms[index],
                roomTypeConfirmation: coordinator.roomTypeConfirmations[index],
                walkPath: coordinator.roomWalkPaths.indices.contains(index) ? coordinator.roomWalkPaths[index] : nil,
                headingDeg: capturedHeadingDeg
            )
        }
        let labels = roomLabels(for: exports)
        uploadProgress.begin(roomLabels: labels)
        for index in labels.indices {
            uploadProgress.markUploading(index: index)
        }
        guard let result = await submitExportsSilent(exports) else {
            isFinishingUnit = false
            return
        }
        preUploadedSession = result
        coordinator.finishUnit()
    }

    @MainActor
    private func submitFused(_ structure: CapturedStructure) async {
        guard let preUploadedSession else {
            isFinishingUnit = false
            DiagnosticsLog.shared.record(
                "submitFused called without a pre-uploaded session — surfacing error",
                category: .error
            )
            onError(
                AppError(
                    site: .captureFailed,
                    underlying: PlainError(message: "The pre-upload session was lost. Please retry from History.")
                ),
                existingSession
            )
            return
        }

        let exports = CapturedStructureExporter.export(
            structure,
            roomTypeConfirmationsByIdentifier: coordinator.roomTypeConfirmationsForStructure(structure),
            roomWalkPathsByIdentifier: coordinator.walkPathsForStructure(structure),
            headingDeg: capturedHeadingDeg
        )

        guard exports.allSatisfy({ $0.hasUsableFloorOutline }) else {
            DiagnosticsLog.shared.record(
                "Fused structure had a degenerate floor outline in \(exports.filter { !$0.hasUsableFloorOutline }.count) of \(exports.count) room(s) — falling back to unfused per-room tiles.",
                category: .error
            )
            isFinishingUnit = false
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, preUploadedSession.floorPlan)
            return
        }

        let labels = roomLabels(for: exports)
        uploadProgress.begin(roomLabels: labels)
        isUploading = true
        isFinishingUnit = false
        defer { isUploading = false }

        for index in labels.indices {
            uploadProgress.markUploading(index: index)
        }

        do {
            let floorPlan = try await client.replaceRooms(
                sessionId: preUploadedSession.session.id,
                accessToken: preUploadedSession.session.accessToken,
                exports: exports,
                location: capturedLocation,
                floor: {
                    let trimmed = capturedFloor.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
            )
            for index in labels.indices {
                uploadProgress.markDone(index: index, areaM2: exports[index].floorAreaM2)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, floorPlan)
        } catch is CancellationError {
            self.preUploadedSession = nil
            DiagnosticsLog.shared.record(
                "Fused upload cancelled — falling back to unfused per-room tiles.",
                category: .info
            )
            onFinished(preUploadedSession.session, preUploadedSession.floorPlan)
        } catch {
            DiagnosticsLog.shared.record(
                "replaceRooms failed while submitting the fused structure — falling back to unfused per-room tiles: \(error.localizedDescription)",
                category: .error
            )
            for index in labels.indices {
                uploadProgress.markFailed(index: index)
            }
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, preUploadedSession.floorPlan)
        }
    }

    @MainActor
    private func submitExportsSilent(
        _ exports: [RoomPlanCaptureExport]
    ) async -> (session: ScanSessionResponse, floorPlan: FloorPlan)? {
        guard !exports.isEmpty else {
            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
            return nil
        }
        guard exports.allSatisfy({ $0.hasUsableFloorOutline }) else {
            onError(
                AppError(
                    site: .captureFailed,
                    underlying: PlainError(message: "One or more merged rooms had a degenerate floor outline.")
                ),
                existingSession
            )
            return nil
        }

        let floorForCaptures: String? = {
            let trimmed = (capturedFloor).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        var captures: [PendingUploadState.PendingCapture] = []
        for export in exports {
            guard let bodyJSON = try? client.encodeCaptureBody(
                capture: export,
                location: capturedLocation,
                floor: floorForCaptures
            ) else {
                onError(
                    AppError(
                        site: .captureFailed,
                        underlying: PlainError(message: "Could not prepare a captured room for upload.")
                    ),
                    existingSession
                )
                return nil
            }
            captures.append(.init(idempotencyKey: UUID().uuidString, bodyJSON: bodyJSON))
        }

        var pending = PendingUploadState(session: existingSession, identity: identity, captures: captures)
        PendingUploadStore.save(pending)

        let session: ScanSessionResponse
        if let existingSession {
            session = existingSession
        } else {
            do {
                session = try await client.createSession(identity: identity.withFloor(capturedFloor))
            } catch is CancellationError {
                onError(AppError(site: .uploadCancelled, underlying: nil), existingSession)
                return nil
            } catch {
                onError(AppError(site: .sessionCreate, underlying: error), nil)
                return nil
            }
            pending.session = session
            PendingUploadStore.save(pending)
            ScanHistoryStore.shared.add(ScanHistoryEntry(
                sessionId: session.id,
                accessToken: session.accessToken,
                propertyId: identity.propertyId,
                unitId: identity.unitId,
                organisationId: identity.organisationId,
                purpose: identity.purpose,
                createdAt: Date(),
                expiresAt: session.expiresAt,
                occupied: identity.occupied,
                consentObtained: identity.consentObtained,
                floor: session.defaultFloor ?? identity.floor
            ))
        }

        var floorPlan: FloorPlan?
        for capture in pending.captures {
            do {
                floorPlan = try await client.uploadCapture(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    idempotencyKey: capture.idempotencyKey,
                    bodyJSON: capture.bodyJSON
                )
            } catch is CancellationError {
                onError(AppError(site: .uploadCancelled, underlying: nil), session)
                return nil
            } catch {
                onError(AppError(site: .captureUpload, underlying: error), session)
                return nil
            }
        }
        guard let floorPlan else {
            onError(AppError(site: .captureNoRoom, underlying: nil), session)
            return nil
        }
        PendingUploadStore.clear()
        ScanHistoryStore.shared.updateRoomSummary(
            sessionId: session.id,
            summary: RoomSummary.text(for: floorPlan.rooms),
            floorAreaM2: floorPlan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
        )
        return (session, floorPlan)
    }

    @MainActor
    private func submitExports(
        _ exports: [RoomPlanCaptureExport]
    ) async -> (session: ScanSessionResponse, floorPlan: FloorPlan)? {
        isUploading = true
        defer { isUploading = false }
        return await submitExportsSilent(exports)
    }



    private func roomLabels(for exports: [RoomPlanCaptureExport]) -> [String] {
        exports.enumerated().map { index, export in
            if let confirmed = export.roomType?.confirmed, !confirmed.isEmpty {
                return RoomTypeClassifier.displayName(for: confirmed)
            }
            if let guess = export.roomType?.guess, !guess.isEmpty {
                return RoomTypeClassifier.displayName(for: guess)
            }
            return "Room \(index + 1)"
        }
    }
}

struct PartialRoomChoiceView: View {
    let message: String
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan interrupted")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Some of this room was captured before the interruption. You can keep it and continue, or discard it and rescan this room.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Keep this room", action: onKeep)
                .accessibilityIdentifier("partialRoom.keep")
                .buttonStyle(.borderedProminent)
            Button("Discard and rescan", role: .destructive, action: onDiscard)
                .accessibilityIdentifier("partialRoom.discard")
        }
        .padding()
    }
}