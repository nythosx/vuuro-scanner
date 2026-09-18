import ARKit
import Combine
import Foundation
import RoomPlan
import simd

struct CaptureLiveStats: Equatable {
    var walls: Int
    var areaM2: Double
    var heightM: Double?

    static let empty = CaptureLiveStats(walls: 0, areaM2: 0, heightM: nil)
}

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

    @Published private(set) var liveStats: CaptureLiveStats = .empty

    private(set) var capturedRoom: CapturedRoom?
    private(set) var capturedRoomWalkPath: [[Double]] = []

    let arSession = ARSession()
    nonisolated(unsafe) private var walkPathTask: Task<Void, Never>?
    private static let walkPathSampleIntervalNanoseconds: UInt64 = 500_000_000
    private static let walkPathMaxPoints = 400

    deinit {
        walkPathTask?.cancel()
    }

    @Published private(set) var isApproachingSizeLimit = false {
        didSet {
            guard oldValue != isApproachingSizeLimit else { return }
            DiagnosticsLog.shared.record("Room size warning -> \(isApproachingSizeLimit)", category: .state)
        }
    }

    @Published private(set) var liveRoomTypeGuess: RoomTypeClassifier.Guess?
    @Published private(set) var hasAnsweredRoomType: Bool = false
    private(set) var roomTypeConfirmation: String?
    private(set) var roomTypeConfirmedForGuessType: String?

    var roomTypeConfirmationForExport: RoomTypeConfirmation? {
        roomTypeConfirmation.map { RoomTypeConfirmation(value: $0, answeredForGuessType: roomTypeConfirmedForGuessType) }
    }

    func confirmRoomTypeGuess() {
        roomTypeConfirmation = liveRoomTypeGuess?.type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        hasAnsweredRoomType = true
        DiagnosticsLog.shared.record("Room type confirmed: \(liveRoomTypeGuess?.type ?? "nil")", category: .info)
    }

    func rejectRoomTypeGuess(correctedTo type: String?) {
        roomTypeConfirmation = type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        hasAnsweredRoomType = true
        DiagnosticsLog.shared.record("Room type corrected: guess=\(liveRoomTypeGuess?.type ?? "nil") -> \(type ?? "nil")", category: .info)
    }

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
        hasAnsweredRoomType = false
        isApproachingSizeLimit = false
        liveStats = .empty
        liveUpdateThrottle.resetRoomTypeAnswered()
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
        // [weak self] breaks the retain cycle: the task no longer owns
        // the coordinator, so the coordinator's deinit can fire and cancel
        // the task. The task exits on the next iteration when self is nil.
        walkPathTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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

    nonisolated static func computeStats(_ room: CapturedRoom) -> CaptureLiveStats {
        let walls = room.walls.count
        let area = room.floors.reduce(0.0) { sum, floor in
            let corners = floor.polygonCorners.map { corner -> (x: Double, z: Double) in
                let world = floor.transform * simd_float4(corner, 1)
                return (Double(world.x), Double(world.z))
            }
            guard corners.count >= 3 else { return sum }
            var polygonArea = 0.0
            for i in corners.indices {
                let a = corners[i]
                let b = corners[(i + 1) % corners.count]
                polygonArea += a.x * b.z - b.x * a.z
            }
            return sum + abs(polygonArea) / 2.0
        }
        let height = room.walls.map { Double($0.dimensions.y) }.max()
        return CaptureLiveStats(walls: walls, areaM2: area, heightM: height)
    }
}

extension CaptureCoordinator: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.capturedRoom = room
                let hasUsableGeometry = !room.walls.isEmpty || !room.floors.isEmpty
                if let error {
                    self.state = .failed(error.localizedDescription, partialRoomAvailable: hasUsableGeometry)
                } else {
                    self.state = .finished(roomAvailable: hasUsableGeometry)
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

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let decision = liveUpdateThrottle.decideUpdate()
        guard decision.shouldProcess else { return }
        let exceedsSizeLimit = RoomSizeGuard.exceedsPracticalLimit(room)
        let guess = RoomTypeGuessSettings.isEnabled ? RoomTypeClassifier.guess(for: room) : nil
        let stats = Self.computeStats(room)
        Task { @MainActor in
            if self.isApproachingSizeLimit != exceedsSizeLimit {
                self.isApproachingSizeLimit = exceedsSizeLimit
            }
            if self.liveStats != stats {
                self.liveStats = stats
            }
            if let guess, !self.liveUpdateThrottle.isRoomTypeAnswered(), self.liveRoomTypeGuess?.type != guess.type {
                self.liveRoomTypeGuess = guess
            }
        }
    }
}