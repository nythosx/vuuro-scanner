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
    @State private var didRequestStopRoom = false
    @State private var isFinishingUnit = false
    @State private var isDegenerateCapture = false
    @State private var showFinishConfirmation = false
    @State private var pendingFinishUnit = false
    @State private var partialRoomFailureMessage: String?
    @State private var showCapturedRoomsList = false
    // Shared by the scanning back-button and the merging-screen Cancel
    // button — both mean the same thing (leave the flow, lose every room
    // captured so far), unlike single-room's discard confirmation which
    // this mirrors, see VuuroScanApp.swift's RoomCaptureFlowStep.
    @State private var showDiscardConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    private let client = ScanServiceClient()

    var body: some View {
        Group {
            if !DeviceCapability.isRoomPlanSupported {
                UnsupportedDeviceScreen(onGoBack: onGoBack)
            } else if isFinishingUnit {
                // Real dead-end found in review: StructureBuilder's merge
                // duration on a real multi-room walkthrough is unverified
                // (Apple forum reports of exceedSceneSizeLimit around 10-11
                // rooms), and this was the one long-running step in the app
                // with no way out short of force-quitting.
                VStack(spacing: 16) {
                    ProgressView("Merging rooms…")
                    Button("Cancel", role: .destructive) {
                        showDiscardConfirmation = true
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                // MultiRoomCaptureScreen must stay mounted for the entire
                // walkthrough, including through a degenerate or partial-
                // failure room — confirmed via Apple developer forum reports
                // (forums.developer.apple.com/forums/thread/769230):
                // recreating RoomCaptureView, even against the same shared
                // ARSession, loses world tracking. That's exactly the
                // alignment MultiRoomCaptureCoordinator's shared ARSession
                // exists to preserve across rooms, so isDegenerateCapture and
                // partialRoomFailureMessage used to be their own top-level
                // Group cases here — which unmounted this ZStack (and the
                // RoomCaptureView inside MultiRoomCaptureScreen) every time
                // either one showed, then rebuilt it from scratch on
                // "Rescan"/"Keep this room". Both are now overlays on top of
                // the still-running capture screen instead.
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
                    } else if isUploading {
                        ProgressView("Uploading rooms…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if didRequestStopRoom {
                        ProgressView("Finishing room…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if coordinator.state == .scanning {
                        VStack {
                            HStack {
                                Spacer()
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
                                .padding(.trailing, 20)
                                .padding(.top, 8)
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
                            HStack(spacing: 16) {
                                Button("Done with this room") {
                                    didRequestStopRoom = true
                                    coordinator.stopCurrentRoom()
                                }
                                .buttonStyle(.borderedProminent)
                                if !coordinator.capturedRooms.isEmpty {
                                    Button("Rooms (\(coordinator.capturedRooms.count))") {
                                        showCapturedRoomsList = true
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Finish unit") {
                                        showFinishConfirmation = true
                                    }
                                    .buttonStyle(.bordered)
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
                .onAppear { coordinator.start() }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background, coordinator.state == .scanning {
                        #if DEBUG
                        DiagnosticsLog.shared.record("App backgrounded mid-scan (multi-room) — ARKit/RoomPlan behavior here is unverified.", category: .state)
                        #endif
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
            Task { await submit(structure) }
        case .mergeFailed(let message):
            isFinishingUnit = false
            onError(AppError(site: .captureFailed, underlying: PlainError(message: message)), existingSession)
        }
    }

    private func continueAfterRoomResolved() {
        if pendingFinishUnit {
            pendingFinishUnit = false
            if coordinator.capturedRooms.isEmpty {
                onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
            } else {
                coordinator.finishUnit()
            }
        } else {
            coordinator.start()
        }
    }

    @MainActor
    private func submit(_ structure: CapturedStructure) async {
        isFinishingUnit = false
        isUploading = true
        defer { isUploading = false }

        let exports = CapturedStructureExporter.export(structure, roomTypeConfirmationsByIdentifier: coordinator.roomTypeConfirmationsByIdentifier)
        guard !exports.isEmpty else {
            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
            return
        }
        guard exports.allSatisfy({ $0.hasUsableFloorOutline }) else {
            onError(AppError(site: .captureFailed, underlying: PlainError(message: "One or more merged rooms had a degenerate floor outline.")), existingSession)
            return
        }

        let session: ScanSessionResponse
        if let existingSession {
            session = existingSession
        } else {
            do {
                session = try await client.createSession(identity: identity)
            } catch {
                onError(AppError(site: .sessionCreate, underlying: error), nil)
                return
            }
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
        for export in exports {
            do {
                floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            } catch {
                onError(AppError(site: .captureUpload, underlying: error), session)
                return
            }
        }
        guard let floorPlan else {
            onError(AppError(site: .captureNoRoom, underlying: nil), session)
            return
        }
        onFinished(session, floorPlan)
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
