
import ARKit
import Combine
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
            #if DEBUG
            DiagnosticsLog.shared.record("Capture state -> \(state)", category: .state)
            #endif
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
            #if DEBUG
            DiagnosticsLog.shared.record("Room size warning -> \(isApproachingSizeLimit)", category: .state)
            #endif
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
        #if DEBUG
        DiagnosticsLog.shared.record("Room type confirmed: \(liveRoomTypeGuess?.type ?? "nil")", category: .info)
        #endif
    }

    func rejectRoomTypeGuess(correctedTo type: String?) {
        roomTypeConfirmation = type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        #if DEBUG
        DiagnosticsLog.shared.record("Room type corrected: guess=\(liveRoomTypeGuess?.type ?? "nil") -> \(type ?? "nil")", category: .info)
        #endif
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
        #if DEBUG
        DiagnosticsLog.shared.record("Walk path tracking stopped — \(capturedRoomWalkPath.count) point(s) recorded", category: .info)
        #endif
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
        #if DEBUG
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction: \(instruction)", category: .instruction)
        }
        #endif
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let exceedsSizeLimit = RoomSizeGuard.exceedsPracticalLimit(room)
        Task { @MainActor in
            if self.isApproachingSizeLimit != exceedsSizeLimit {
                self.isApproachingSizeLimit = exceedsSizeLimit
            }
        }
        guard RoomTypeGuessSettings.isEnabled, let guess = RoomTypeClassifier.guess(for: room) else { return }
        Task { @MainActor in
            if self.liveRoomTypeGuess?.type != guess.type {
                self.liveRoomTypeGuess = guess
            }
        }
    }
}
