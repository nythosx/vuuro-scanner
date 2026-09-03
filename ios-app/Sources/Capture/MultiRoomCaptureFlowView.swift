import RoomPlan
import SwiftUI

struct MultiRoomCaptureFlowView: View {
    let identity: ScanIdentity
    let onFinished: (ScanSessionResponse, FloorPlan) -> Void
    let onError: (AppError) -> Void
    let onGoBack: () -> Void

    @StateObject private var coordinator = MultiRoomCaptureCoordinator()
    @State private var isUploading = false
    @State private var didRequestStopRoom = false
    @State private var isFinishingUnit = false
    @State private var isDegenerateCapture = false
    @State private var showFinishConfirmation = false

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
                                    didRequestStopRoom = true
                                    coordinator.stopCurrentRoom()
                                    coordinator.finishUnit()
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
            coordinator.start()
        case .roomFinished(roomAvailable: false):
            didRequestStopRoom = false
            isDegenerateCapture = true
        case .failed:
            didRequestStopRoom = false
            coordinator.discardPendingPartialRoom()
            coordinator.start()
        case .merging:
            isFinishingUnit = true
        case .unitFinished:
            guard let structure = coordinator.mergedStructure else { return }
            Task { await submit(structure) }
        case .mergeFailed(let message):
            isFinishingUnit = false
            onError(AppError(site: .captureFailed, underlying: PlainError(message: message)))
        }
    }

    @MainActor
    private func submit(_ structure: CapturedStructure) async {
        isFinishingUnit = false
        isUploading = true
        defer { isUploading = false }

        let exports = CapturedStructureExporter.export(structure)
        guard exports.allSatisfy({ $0.hasUsableFloorOutline }) else {
            onError(AppError(site: .captureFailed, underlying: PlainError(message: "One or more merged rooms had a degenerate floor outline.")))
            return
        }

        let session: ScanSessionResponse
        do {
            session = try await client.createSession(identity: identity)
        } catch {
            onError(AppError(site: .sessionCreate, underlying: error))
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

        var floorPlan: FloorPlan?
        for export in exports {
            do {
                floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            } catch {
                onError(AppError(site: .captureUpload, underlying: error))
                return
            }
        }
        guard let floorPlan else {
            onError(AppError(site: .captureNoRoom, underlying: nil))
            return
        }
        onFinished(session, floorPlan)
    }
}
