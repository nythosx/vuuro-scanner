//
//  MultiRoomCaptureCoordinator.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  LIDAR-5/11 groundwork (docs/proposals/multi-room-fusion.md). Separate
//  from CaptureCoordinator on purpose — that class's "scan another room"
//  path recreates its RoomCaptureView/ARSession per room, which breaks
//  StructureBuilder alignment. This one owns one ARSession across the
//  whole multi-room visit instead. Unverified on real hardware, and a
//  world-origin-shift bug on room 2+ has been reported even with this
//  exact pattern (Apple forums thread 763244, unresolved) — first real
//  test must check room 2's position relative to room 1, not just that
//  both captured cleanly.
//

import ARKit
import Combine
import RoomPlan

@MainActor
final class MultiRoomCaptureCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case scanning
        case roomFinished(roomAvailable: Bool)
        case failed(String, partialRoomAvailable: Bool)
        case merging
        case unitFinished
        case mergeFailed(String)
    }

    // ~10-11 rooms reportedly throws exceedSceneSizeLimit (Apple forums);
    // warn two rooms early.
    static let roomCountWarningThreshold = 8

    @Published private(set) var state: State = .scanning {
        didSet {
            #if DEBUG
            DiagnosticsLog.shared.record("Multi-room capture state -> \(state)", category: .state)
            #endif
        }
    }

    private(set) var capturedRooms: [CapturedRoom] = []

    /// Set only on partialRoomAvailable — not committed until the user chooses to keep it.
    private(set) var pendingPartialRoom: CapturedRoom?

    private(set) var mergedStructure: CapturedStructure?

    /// Owned here, not by the view, so it survives across rooms.
    let arSession = ARSession()

    private var captureSession: RoomCaptureSession?

    func attach(to session: RoomCaptureSession) {
        captureSession = session
        session.delegate = self
    }

    func start() {
        guard let captureSession else { return }
        state = .scanning
        captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// pauseARSession: false — required for the next room to share this one's frame.
    func stopCurrentRoom() {
        captureSession?.stop(pauseARSession: false)
    }

    func keepPendingPartialRoom() {
        guard let pendingPartialRoom else { return }
        capturedRooms.append(pendingPartialRoom)
        self.pendingPartialRoom = nil
    }

    func discardPendingPartialRoom() {
        pendingPartialRoom = nil
    }

    func finishUnit() {
        captureSession?.stop(pauseARSession: false)
        arSession.pause()
        guard !capturedRooms.isEmpty else {
            state = .mergeFailed("No rooms were captured in this walkthrough.")
            return
        }
        state = .merging
        Task {
            do {
                // Merge accuracy on a real walk is unverified — see proposal doc.
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: capturedRooms)
                self.mergedStructure = structure
                self.state = .unitFinished
            } catch {
                self.state = .mergeFailed(error.localizedDescription)
            }
        }
    }
}

extension MultiRoomCaptureCoordinator: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                if let error {
                    let hasUsableGeometry = !room.walls.isEmpty || !room.floors.isEmpty
                    self.pendingPartialRoom = hasUsableGeometry ? room : nil
                    self.state = .failed(error.localizedDescription, partialRoomAvailable: hasUsableGeometry)
                } else {
                    self.capturedRooms.append(room)
                    self.state = .roomFinished(roomAvailable: true)
                }
            } catch {
                self.state = .failed(error.localizedDescription, partialRoomAvailable: false)
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        #if DEBUG
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction (multi-room): \(instruction)", category: .instruction)
        }
        #endif
    }
}
