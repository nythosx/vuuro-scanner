
import ARKit
import Combine
import Foundation
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
        case mergeTimedOut
        case mergeCancelled
    }

    private struct MergeTimeoutError: Error {}

    static let roomCountWarningThreshold = 8

    @Published private(set) var state: State = .scanning {
        didSet {
            DiagnosticsLog.shared.record("Multi-room capture state -> \(state)", category: .state)
        }
    }

    @Published private(set) var capturedRooms: [CapturedRoom] = []
    @Published private(set) var roomTypeConfirmations: [RoomTypeConfirmation?] = []

    var roomTypeConfirmationsByIdentifier: [UUID: RoomTypeConfirmation] {
        var result: [UUID: RoomTypeConfirmation] = [:]
        for (room, confirmation) in zip(capturedRooms, roomTypeConfirmations) {
            if let confirmation {
                result[room.identifier] = confirmation
            }
        }
        return result
    }

    var roomWalkPathsByIdentifier: [UUID: [[Double]]] {
        var result: [UUID: [[Double]]] = [:]
        for (room, walkPath) in zip(capturedRooms, roomWalkPaths) {
            if !walkPath.isEmpty {
                result[room.identifier] = walkPath
            }
        }
        return result
    }

    @Published private(set) var isApproachingSizeLimit = false {
        didSet {
            guard oldValue != isApproachingSizeLimit else { return }
            DiagnosticsLog.shared.record("Room size warning (multi-room) -> \(isApproachingSizeLimit)", category: .state)
        }
    }

    @Published private(set) var liveRoomTypeGuess: RoomTypeClassifier.Guess?
    private(set) var roomTypeConfirmation: String?
    private(set) var roomTypeConfirmedForGuessType: String?

    var roomTypeConfirmationForExport: RoomTypeConfirmation? {
        roomTypeConfirmation.map { RoomTypeConfirmation(value: $0, answeredForGuessType: roomTypeConfirmedForGuessType) }
    }

    func confirmRoomTypeGuess() {
        roomTypeConfirmation = liveRoomTypeGuess?.type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        DiagnosticsLog.shared.record("Room type confirmed (multi-room): \(liveRoomTypeGuess?.type ?? "nil")", category: .info)
    }

    func rejectRoomTypeGuess(correctedTo type: String?) {
        roomTypeConfirmation = type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        DiagnosticsLog.shared.record("Room type corrected (multi-room): guess=\(liveRoomTypeGuess?.type ?? "nil") -> \(type ?? "nil")", category: .info)
    }

    private(set) var pendingPartialRoom: CapturedRoom?
    private var pendingPartialRoomWalkPath: [[Double]] = []

    private(set) var mergedStructure: CapturedStructure?

    private(set) var roomWalkPaths: [[[Double]]] = []
    private var currentRoomWalkPath: [[Double]] = []
    private var walkPathTask: Task<Void, Never>?
    private static let walkPathSampleIntervalNanoseconds: UInt64 = 500_000_000
    private static let walkPathMaxPoints = 400

    static let mergeTimeoutSeconds: Double = 45
    private var mergeTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    let arSession = ARSession()

    private var captureSession: RoomCaptureSession?

    private let liveUpdateThrottle = RoomLiveUpdateThrottle()

    func attach(to session: RoomCaptureSession) {
        captureSession = session
        session.delegate = self
    }

    func start() {
        guard let captureSession else { return }
        state = .scanning
        liveRoomTypeGuess = nil
        roomTypeConfirmation = nil
        roomTypeConfirmedForGuessType = nil
        isApproachingSizeLimit = false
        liveUpdateThrottle.resetRoomTypeAnswered()
        startWalkPathTracking()
        captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// pauseARSession: false — required for the next room to share this one's frame.
    func stopCurrentRoom() {
        stopWalkPathTracking()
        captureSession?.stop(pauseARSession: false)
    }

    func keepPendingPartialRoom() {
        guard let pendingPartialRoom else { return }
        capturedRooms.append(pendingPartialRoom)
        roomTypeConfirmations.append(roomTypeConfirmationForExport)
        roomWalkPaths.append(pendingPartialRoomWalkPath)
        self.pendingPartialRoom = nil
        pendingPartialRoomWalkPath = []
    }

    func discardPendingPartialRoom() {
        pendingPartialRoom = nil
        pendingPartialRoomWalkPath = []
    }

    func removeCapturedRoom(at index: Int) {
        guard capturedRooms.indices.contains(index) else { return }
        capturedRooms.remove(at: index)
        roomTypeConfirmations.remove(at: index)
        if roomWalkPaths.indices.contains(index) {
            roomWalkPaths.remove(at: index)
        }
        DiagnosticsLog.shared.record("Captured room removed at index \(index) (multi-room)", category: .info)
    }

    private func startWalkPathTracking() {
        stopWalkPathTracking()
        currentRoomWalkPath = []
        walkPathTask = Task {
            while !Task.isCancelled {
                if let transform = self.arSession.currentFrame?.camera.transform,
                   self.currentRoomWalkPath.count < Self.walkPathMaxPoints {
                    let t = transform.columns.3
                    self.currentRoomWalkPath.append([Double(t.x), Double(t.y), Double(t.z)])
                }
                try? await Task.sleep(nanoseconds: Self.walkPathSampleIntervalNanoseconds)
            }
        }
    }

    private func stopWalkPathTracking() {
        walkPathTask?.cancel()
        walkPathTask = nil
        DiagnosticsLog.shared.record("Walk path tracking stopped — \(currentRoomWalkPath.count) point(s) recorded for this room", category: .info)
    }

    func finishUnit() {
        stopWalkPathTracking()
        captureSession?.stop(pauseARSession: false)
        arSession.pause()
        guard !capturedRooms.isEmpty else {
            state = .mergeFailed("No rooms were captured in this walkthrough.")
            return
        }
        state = .merging
        startMergeHeartbeat()
        let rooms = capturedRooms
        mergeTask = Task {
            do {
                let structure = try await Self.runMerge(rooms: rooms, timeoutSeconds: Self.mergeTimeoutSeconds)
                guard !Task.isCancelled else { return }
                self.stopMergeHeartbeat()
                self.mergedStructure = structure
                self.state = .unitFinished
            } catch is CancellationError {
                self.stopMergeHeartbeat()
            } catch is MergeTimeoutError {
                self.stopMergeHeartbeat()
                DiagnosticsLog.shared.record("Merge timed out after \(Int(Self.mergeTimeoutSeconds))s — falling back to unmerged rooms", category: .error)
                self.state = .mergeTimedOut
            } catch {
                self.stopMergeHeartbeat()
                self.state = .mergeFailed(error.localizedDescription)
            }
        }
    }

    func cancelMerge() {
        mergeTask?.cancel()
        mergeTask = nil
        stopMergeHeartbeat()
        DiagnosticsLog.shared.record("Merge cancelled by user — keeping \(capturedRooms.count) captured room(s)", category: .info)
        state = .mergeCancelled
    }

    private static func runMerge(rooms: [CapturedRoom], timeoutSeconds: Double) async throws -> CapturedStructure {
        try await withThrowingTaskGroup(of: CapturedStructure.self) { group in
            group.addTask {
                try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw MergeTimeoutError()
            }
            guard let result = try await group.next() else {
                throw MergeTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    private func startMergeHeartbeat() {
        let start = Date()
        heartbeatTask = Task {
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                step += 1
                let elapsed = Int(Date().timeIntervalSince(start))
                DiagnosticsLog.shared.record("Merging rooms — step \(step), elapsed \(elapsed)s", category: .state)
            }
        }
    }

    private func stopMergeHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
                    self.pendingPartialRoomWalkPath = hasUsableGeometry ? self.currentRoomWalkPath : []
                    self.state = .failed(error.localizedDescription, partialRoomAvailable: hasUsableGeometry)
                } else {
                    if CapturedRoomExporter.export(room).hasUsableFloorOutline {
                        self.capturedRooms.append(room)
                        self.roomTypeConfirmations.append(self.roomTypeConfirmationForExport)
                        self.roomWalkPaths.append(self.currentRoomWalkPath)
                        self.state = .roomFinished(roomAvailable: true)
                    } else {
                        self.state = .roomFinished(roomAvailable: false)
                    }
                }
            } catch {
                self.state = .failed(error.localizedDescription, partialRoomAvailable: false)
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction (multi-room): \(instruction)", category: .instruction)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        guard liveUpdateThrottle.shouldProcessUpdate() else { return }
        let exceedsSizeLimit = RoomSizeGuard.exceedsPracticalLimit(room)
        let guess = RoomTypeGuessSettings.isEnabled ? RoomTypeClassifier.guess(for: room) : nil
        Task { @MainActor in
            if self.isApproachingSizeLimit != exceedsSizeLimit {
                self.isApproachingSizeLimit = exceedsSizeLimit
            }
            if let guess, !self.liveUpdateThrottle.isRoomTypeAnswered(), self.liveRoomTypeGuess?.type != guess.type {
                self.liveRoomTypeGuess = guess
            }
        }
    }
}
