import RoomPlan
import SwiftUI

struct MultiRoomCaptureFlowView: View {
    let identity: ScanIdentity
    let existingSession: ScanSessionResponse?
    let onFinished: (ScanSessionResponse, FloorPlan) -> Void
    let onError: (AppError, ScanSessionResponse?) -> Void
    let onGoBack: () -> Void

    @StateObject private var coordinator = MultiRoomCaptureCoordinator()
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
    @State private var capturedLocation: CaptureLocation?
    @State private var preUploadedSession: (session: ScanSessionResponse, floorPlan: FloorPlan)?
    @State private var isRoomsButtonCompact = false
    @State private var roomTypeGuessOn = RoomTypeGuessSettings.isEnabled
    @State private var isGuessToggleCompact = false
    @Environment(\.scenePhase) private var scenePhase

    private let client = ScanServiceClient()
    private let locationProvider = LocationProvider()

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
            } else if !DeviceCapability.isRoomPlanSupported {
                #if DEBUG
                ProgressView("Generating fake multi-room capture (Debug)…")
                    .onAppear {
                        uploadTask = Task {
                            let exports = (0..<Int.random(in: 2...4)).map { _ in FakeCaptureGenerator.random() }
                            if let result = await submitExports(exports) {
                                onFinished(result.session, result.floorPlan)
                            }
                        }
                    }
                #else
                EmptyView()
                #endif
            } else if isFinishingUnit {
                VStack(spacing: 16) {
                    ProgressView("Merging rooms…")
                    Button("Cancel", role: .destructive) {
                        coordinator.cancelMerge()
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if isUploading {
                UploadProgressView(message: "Uploading rooms…", onCancel: { uploadTask?.cancel() })
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ZStack {
                    MultiRoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

                    if coordinator.state == .scanning, let guess = coordinator.liveRoomTypeGuess {
                        VStack {
                            RoomTypeGuessOverlay(
                                guess: guess,
                                onConfirm: { coordinator.confirmRoomTypeGuess() },
                                onReject: { picked in coordinator.rejectRoomTypeGuess(correctedTo: picked) }
                            )
                            .id(guess.type)
                            Spacer()
                        }
                    }

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
                        VStack {
                            HStack {
                                // Review finding: this used to call onGoBack()
                                // directly — a stray tap silently discarded
                                // every already-captured room in this
                                // walkthrough, with LESS friction than the
                                // single-room flow's equivalent button
                                // despite a worse consequence (many rooms,
                                // not one). Now confirms first, same as that
                                // one does.
                                Button {
                                    showDiscardConfirmation = true
                                } label: {
                                    Image(systemName: "chevron.backward")
                                        .font(.headline)
                                        .padding(10)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .padding(.leading, 20)
                                .padding(.top, 8)

                                Spacer()
                                Button {
                                    roomTypeGuessOn.toggle()
                                    RoomTypeGuessSettings.isEnabled = roomTypeGuessOn
                                    VuuroToast.shared.show(roomTypeGuessOn ? "Room-type guessing on" : "Room-type guessing off")
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: roomTypeGuessOn ? "wand.and.stars" : "wand.and.stars.inverse")
                                        if !isGuessToggleCompact {
                                            Text("Room-type guessing")
                                                .transition(.opacity)
                                        }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(roomTypeGuessOn ? VuuroColor.textPrimary : .white)
                                    .padding(.horizontal, isGuessToggleCompact ? 0 : 12)
                                    .frame(width: isGuessToggleCompact ? 36 : nil, height: 36)
                                    .background(
                                        roomTypeGuessOn ? VuuroColor.accentLime : Color.white.opacity(0.16),
                                        in: Capsule()
                                    )
                                }
                                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isGuessToggleCompact)
                                .padding(.trailing, 20)
                                .padding(.top, 8)
                                .onAppear {
                                    isGuessToggleCompact = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
                                        isGuessToggleCompact = true
                                    }
                                }
                            }
                            Spacer()
                            if coordinator.capturedRooms.count >= MultiRoomCaptureCoordinator.roomCountWarningThreshold {
                                Text("\(coordinator.capturedRooms.count) rooms captured — you may be approaching a device limit soon.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(.bottom, 8)
                            }
                            if coordinator.isApproachingSizeLimit {
                                Text("This room looks larger than RoomPlan's practical scanning range (~9m) — accuracy may degrade beyond this size.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                    .padding(.bottom, 8)
                            }
                            HStack(spacing: 12) {
                                Button("Done with this room") {
                                    didRequestStopRoom = true
                                    coordinator.stopCurrentRoom()
                                }
                                .buttonStyle(.vuuroPrimary)
                                if !coordinator.capturedRooms.isEmpty {
                                    Button {
                                        showCapturedRoomsList = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "square.stack.3d.up.fill")
                                            if !isRoomsButtonCompact {
                                                Text("Rooms (\(coordinator.capturedRooms.count))")
                                                    .transition(.opacity)
                                            }
                                        }
                                        .frame(width: isRoomsButtonCompact ? 40 : nil, height: isRoomsButtonCompact ? 40 : nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(isRoomsButtonCompact ? VuuroColor.textPrimary : nil)
                                    Button("Finish unit") {
                                        showFinishConfirmation = true
                                    }
                                    .buttonStyle(.vuuroSecondary)
                                }
                            }
                            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isRoomsButtonCompact)
                            .onAppear {
                                isRoomsButtonCompact = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
                                    isRoomsButtonCompact = true
                                }
                            }
                            .padding(.bottom, 40)
                            .alert("Finish this unit?", isPresented: $showFinishConfirmation) {
                                Button("Finish") {
                                    pendingFinishUnit = true
                                    didRequestStopRoom = true
                                    coordinator.stopCurrentRoom()
                                }
                                Button("Keep scanning", role: .cancel) {}
                            } message: {
                                Text("\(coordinator.capturedRooms.count) room(s) captured so far will be merged and uploaded.")
                            }
                        }
                    }
                }
                .onAppear {
                    coordinator.start()
                    Task { capturedLocation = await locationProvider.currentLocation() }
                }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background, coordinator.state == .scanning {
                        DiagnosticsLog.shared.record("App backgrounded mid-scan (multi-room) — ARKit/RoomPlan behavior here is unverified.", category: .state)
                    }
                }
            }
        }
        .alert("Discard this scan?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) { onGoBack() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("\(coordinator.capturedRooms.count) room(s) captured so far will be lost.")
        }
        .sheet(isPresented: $showCapturedRoomsList) {
            CapturedRoomsListView(coordinator: coordinator)
        }
    }

    // Dimmed backdrop + floating card, since these overlays now draw on top
    // of the still-running (visually live) camera feed instead of replacing
    // it with an opaque screen — see the comment above this file's ZStack
    // for why the capture screen can no longer be swapped out here.
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
            finishWithPreUploadOrError(AppError(site: .captureFailed, underlying: PlainError(message: message)))
        case .mergeTimedOut, .mergeCancelled:
            isFinishingUnit = false
            finishWithPreUploadOrError(AppError(site: .captureFailed, underlying: PlainError(message: "Merging rooms didn't complete.")))
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
        let exports = coordinator.capturedRooms.indices.map { index in
            CapturedRoomExporter.export(
                coordinator.capturedRooms[index],
                roomTypeConfirmation: coordinator.roomTypeConfirmations[index],
                walkPath: coordinator.roomWalkPaths.indices.contains(index) ? coordinator.roomWalkPaths[index] : nil
            )
        }
        guard let result = await submitExports(exports) else { return }
        preUploadedSession = result
        coordinator.finishUnit()
    }

    @MainActor
    private func submitFused(_ structure: CapturedStructure) async {
        isFinishingUnit = false
        guard let preUploadedSession else { return }
        let exports = CapturedStructureExporter.export(structure, roomTypeConfirmationsByIdentifier: coordinator.roomTypeConfirmationsByIdentifier, roomWalkPathsByIdentifier: coordinator.roomWalkPathsByIdentifier)
        guard exports.allSatisfy({ $0.hasUsableFloorOutline }) else {
            DiagnosticsLog.shared.record("Fused structure had a degenerate floor outline in \(exports.filter { !$0.hasUsableFloorOutline }.count) of \(exports.count) room(s) — falling back to unfused per-room tiles.", category: .error)
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, preUploadedSession.floorPlan)
            return
        }
        isUploading = true
        defer { isUploading = false }
        do {
            let floorPlan = try await client.replaceRooms(sessionId: preUploadedSession.session.id, accessToken: preUploadedSession.session.accessToken, exports: exports, location: capturedLocation)
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, floorPlan)
        } catch {
            DiagnosticsLog.shared.record("replaceRooms failed while submitting the fused structure — falling back to unfused per-room tiles: \(error.localizedDescription)", category: .error)
            self.preUploadedSession = nil
            onFinished(preUploadedSession.session, preUploadedSession.floorPlan)
        }
    }

    @MainActor
    private func submitExports(_ exports: [RoomPlanCaptureExport]) async -> (session: ScanSessionResponse, floorPlan: FloorPlan)? {
        isUploading = true
        defer { isUploading = false }

        guard !exports.isEmpty else {
            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
            return nil
        }
        guard exports.allSatisfy({ $0.hasUsableFloorOutline }) else {
            onError(AppError(site: .captureFailed, underlying: PlainError(message: "One or more merged rooms had a degenerate floor outline.")), existingSession)
            return nil
        }

        var captures: [PendingUploadState.PendingCapture] = []
        for export in exports {
            guard let bodyJSON = try? client.encodeCaptureBody(capture: export, location: capturedLocation) else {
                onError(AppError(site: .captureFailed, underlying: PlainError(message: "Could not prepare a captured room for upload.")), existingSession)
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
                session = try await client.createSession(identity: identity)
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
                expiresAt: session.expiresAt
            ))
        }

        var floorPlan: FloorPlan?
        for capture in pending.captures {
            do {
                floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: capture.idempotencyKey, bodyJSON: capture.bodyJSON)
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
        return (session, floorPlan)
    }
}

struct PartialRoomChoiceView: View {
    let message: String
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan interrupted").font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Some of this room was captured before the interruption. You can keep it and continue, or discard it and rescan this room.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Keep this room", action: onKeep).buttonStyle(.borderedProminent)
            Button("Discard and rescan", role: .destructive, action: onDiscard)
        }
        .padding()
    }
}
