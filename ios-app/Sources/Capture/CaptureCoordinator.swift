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
        let floorsArea = computeLiveAreaFromFloors(room)
        let area = floorsArea > 0 ? floorsArea : computeLiveAreaFromWalls(room)
        let height = room.walls.map { Double($0.dimensions.y) }.max()
        return CaptureLiveStats(walls: walls, areaM2: area, heightM: height)
    }

    nonisolated private static func computeLiveAreaFromFloors(_ room: CapturedRoom) -> Double {
        guard !room.floors.isEmpty else { return 0 }

        var total = 0.0
        for floor in room.floors {
            guard floor.polygonCorners.count >= 3 else { return 0 }
            let worldCorners = floor.polygonCorners.map { corner -> (x: Double, z: Double) in
                let world = floor.transform * simd_float4(corner, 1)
                return (Double(world.x), Double(world.z))
            }
            var area = 0.0
            for i in worldCorners.indices {
                let a = worldCorners[i]
                let b = worldCorners[(i + 1) % worldCorners.count]
                area += a.x * b.z - b.x * a.z
            }
            total += abs(area) / 2.0
        }
        return total
    }

    nonisolated private static func computeLiveAreaFromWalls(_ room: CapturedRoom) -> Double {
        guard !room.walls.isEmpty else { return 0 }

        var points: [SIMD2<Double>] = []
        points.reserveCapacity(room.walls.count * 4)

        for wall in room.walls {
            for corner in wall.polygonCorners {
                let world = wall.transform * simd_float4(corner, 1)
                let x = Double(world.x)
                let z = Double(world.z)
                guard x.isFinite, z.isFinite else { continue }
                points.append(SIMD2<Double>(x, z))
            }
        }

        guard points.count >= 3 else { return 0 }

        let hull = convexHull(points)
        guard hull.count >= 3 else { return 0 }

        var area = 0.0
        for i in hull.indices {
            let a = hull[i]
            let b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) / 2.0
    }

    nonisolated private static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let unique = Array(Set(points.map { PointKey(x: $0.x, y: $0.y) }))
            .map { SIMD2<Double>($0.x, $0.y) }

        guard unique.count >= 3 else { return unique }

        let sorted = unique.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }

        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Double>] = []
        lower.reserveCapacity(sorted.count)
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [SIMD2<Double>] = []
        upper.reserveCapacity(sorted.count)
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        lower.removeLast()
        upper.removeLast()

        let hull = lower + upper

        return hull
    }

    private struct PointKey: Hashable {
        private static let precision: Double = 1000

        let x: Double
        let y: Double

        init(x: Double, y: Double) {
            self.x = (x * Self.precision).rounded() / Self.precision
            self.y = (y * Self.precision).rounded() / Self.precision
        }

        static func == (lhs: PointKey, rhs: PointKey) -> Bool {
            lhs.x == rhs.x && lhs.y == rhs.y
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(x)
            hasher.combine(y)
        }
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