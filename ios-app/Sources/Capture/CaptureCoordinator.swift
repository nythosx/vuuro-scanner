
import ARKit
import Combine
import Foundation
import RoomPlan

@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case scanning
        case finished(roomAvailable: Bool)
      
        case failed(String, partialRoomAvailable: Bool)
    }

   
    @Published private(set) var state: State = .scanning {
        didSet {
            DiagnosticsLog.shared.record("Capture state -> \(state)", category: .state)
        }
    }

    private(set) var capturedRoom: CapturedRoom?
    private(set) var capturedRoomWalkPath: [[Double]] = []

    let arSession = ARSession()
    private var walkPathTask: Task<Void, Never>?
    private static let walkPathSampleIntervalNanoseconds: UInt64 = 500_000_000
    private static let walkPathMaxPoints = 400

    @Published private(set) var isApproachingSizeLimit = false {
        didSet {
            guard oldValue != isApproachingSizeLimit else { return }
            DiagnosticsLog.shared.record("Room size warning -> \(isApproachingSizeLimit)", category: .state)
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
        markRoomTypeAnswered()
        DiagnosticsLog.shared.record("Room type confirmed: \(liveRoomTypeGuess?.type ?? "nil")", category: .info)
    }

    func rejectRoomTypeGuess(correctedTo type: String?) {
        roomTypeConfirmation = type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        markRoomTypeAnswered()
        DiagnosticsLog.shared.record("Room type corrected: guess=\(liveRoomTypeGuess?.type ?? "nil") -> \(type ?? "nil")", category: .info)
    }

    private var captureSession: RoomCaptureSession?

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
        startWalkPathTracking()

        let configuration = RoomCaptureSession.Configuration()
        captureSession.run(configuration: configuration)
    }

    func stop() {
        stopWalkPathTracking()
        captureSession?.stop()
    }

    private func startWalkPathTracking() {
        stopWalkPathTracking()
        capturedRoomWalkPath = []
        walkPathTask = Task {
            while !Task.isCancelled {
                if let transform = self.arSession.currentFrame?.camera.transform,
                   self.capturedRoomWalkPath.count < Self.walkPathMaxPoints {
                    let t = transform.columns.3
                    self.capturedRoomWalkPath.append([Double(t.x), Double(t.y), Double(t.z)])
                }
                try? await Task.sleep(nanoseconds: Self.walkPathSampleIntervalNanoseconds)
            }
        }
    }

    private func stopWalkPathTracking() {
        walkPathTask?.cancel()
        walkPathTask = nil
        DiagnosticsLog.shared.record("Walk path tracking stopped — \(capturedRoomWalkPath.count) point(s) recorded", category: .info)
    }
}

extension CaptureCoordinator: RoomCaptureSessionDelegate {
   
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
         
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.capturedRoom = room
                if let error {
                    
                    let hasUsableGeometry = !room.walls.isEmpty || !room.floors.isEmpty
                    self.state = .failed(error.localizedDescription, partialRoomAvailable: hasUsableGeometry)
                } else {
                    self.state = .finished(roomAvailable: true)
                }
            } catch {
                self.state = .failed(error.localizedDescription, partialRoomAvailable: false)
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction: \(instruction)", category: .instruction)
        }
    }

    private let liveUpdateThrottleLock = NSLock()
    nonisolated(unsafe) private var lastLiveUpdateAt: Date = .distantPast
    nonisolated(unsafe) private var isRoomTypeAnswered = false
    private static let liveUpdateThrottleInterval: TimeInterval = 0.15

    nonisolated private func shouldProcessLiveUpdate() -> Bool {
        liveUpdateThrottleLock.lock()
        defer { liveUpdateThrottleLock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastLiveUpdateAt) >= Self.liveUpdateThrottleInterval else { return false }
        lastLiveUpdateAt = now
        return true
    }

    nonisolated private func roomTypeAlreadyAnswered() -> Bool {
        liveUpdateThrottleLock.lock()
        defer { liveUpdateThrottleLock.unlock() }
        return isRoomTypeAnswered
    }

    private func markRoomTypeAnswered() {
        liveUpdateThrottleLock.lock()
        isRoomTypeAnswered = true
        liveUpdateThrottleLock.unlock()
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        guard shouldProcessLiveUpdate() else { return }
        let exceedsSizeLimit = RoomSizeGuard.exceedsPracticalLimit(room)
        let guess = (RoomTypeGuessSettings.isEnabled && !roomTypeAlreadyAnswered()) ? RoomTypeClassifier.guess(for: room) : nil
        Task { @MainActor in
            if self.isApproachingSizeLimit != exceedsSizeLimit {
                self.isApproachingSizeLimit = exceedsSizeLimit
            }
            if let guess, self.liveRoomTypeGuess?.type != guess.type {
                self.liveRoomTypeGuess = guess
            }
        }
    }
}
