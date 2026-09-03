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

    private let client = ScanServiceClient()

    var body: some View {
        Group {
            if !DeviceCapability.isRoomPlanSupported {
                UnsupportedDeviceScreen(onGoBack: onGoBack)
            } else if isFinishingUnit {
                ProgressView("Merging rooms…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if isDegenerateCapture {
                DegenerateCaptureView {
                    isDegenerateCapture = false
                    coordinator.start()
                }
            } else if let partialRoomFailureMessage {
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
            } else {
                ZStack {
                    MultiRoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

                    if isUploading {
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
                                Button {
                                    onGoBack()
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
                            HStack(spacing: 16) {
                                Button("Done with this room") {
                                    didRequestStopRoom = true
                                    coordinator.stopCurrentRoom()
                                }
                                .buttonStyle(.borderedProminent)
                                if !coordinator.capturedRooms.isEmpty {
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
            }
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

        let exports = CapturedStructureExporter.export(structure)
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
                createdAt: Date()
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
