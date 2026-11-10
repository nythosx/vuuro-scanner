import ARKit
import Foundation
import simd

enum LidarSkipReason: String, CaseIterable, Codable, Sendable {
    case noFrame = "no_frame"
    case sameFrame = "same_frame"
    case trackingNotAvailable = "tracking_not_available"
    case trackingInitializing = "tracking_initializing"
    case trackingExcessiveMotion = "tracking_excessive_motion"
    case trackingInsufficientFeatures = "tracking_insufficient_features"
    case trackingRelocalizing = "tracking_relocalizing"
    case trackingLimitedOther = "tracking_limited_other"
    case noDepth = "no_depth"
    case notMoved = "not_moved"
    case writerBusy = "writer_busy"
    case writeFailed = "write_failed"
    case waiting = "waiting"
    case pollStalled = "poll_stalled"

    var label: String {
        switch self {
        case .noFrame: return "no camera frame"
        case .sameFrame: return "camera frame stopped updating"
        case .trackingNotAvailable: return "tracking not available"
        case .trackingInitializing: return "tracking starting up"
        case .trackingExcessiveMotion: return "tracking limited, moving too fast"
        case .trackingInsufficientFeatures: return "tracking limited, too little detail in view"
        case .trackingRelocalizing: return "tracking relocalizing"
        case .trackingLimitedOther: return "tracking limited"
        case .noDepth: return "no depth in the frame"
        case .notMoved: return "phone not moved enough"
        case .writerBusy: return "still saving the last frame"
        case .writeFailed: return "frame could not be saved"
        case .waiting: return "waiting for the next frame slot"
        case .pollStalled: return "app busy, recorder not called"
        }
    }

    var rank: Int {
        switch self {
        case .writerBusy: return 3
        case .noDepth: return 2
        case .notMoved: return 1
        default: return 0
        }
    }

    static func tracking(_ state: ARCamera.TrackingState) -> LidarSkipReason? {
        switch state {
        case .normal: return nil
        case .notAvailable: return .trackingNotAvailable
        case .limited(.initializing): return .trackingInitializing
        case .limited(.excessiveMotion): return .trackingExcessiveMotion
        case .limited(.insufficientFeatures): return .trackingInsufficientFeatures
        case .limited(.relocalizing): return .trackingRelocalizing
        case .limited: return .trackingLimitedOther
        }
    }

    static func moreTelling(_ a: LidarSkipReason, _ b: LidarSkipReason) -> LidarSkipReason {
        b.rank > a.rank ? b : a
    }
}

struct LidarRecordingGap: Codable, Equatable, Sendable {
    var room: Int
    var startS: Double
    var endS: Double
    var movedM: Double?
    var heightChangeM: Double?
    var atRoomEnd: Bool
    var reasons: [String: Int]

    var durationS: Double { endS - startS }

    var mainReason: LidarSkipReason? {
        reasons
            .compactMap { key, count in LidarSkipReason(rawValue: key).map { (reason: $0, count: count) } }
            .max { $0.count != $1.count ? $0.count < $1.count : $0.reason.rawValue > $1.reason.rawValue }?.reason
    }

    var reasonShares: [(reason: LidarSkipReason, percent: Double)] {
        let total = reasons.values.reduce(0, +)
        guard total > 0 else { return [] }
        return reasons
            .compactMap { key, count in LidarSkipReason(rawValue: key).map { (reason: $0, percent: Double(count) / Double(total) * 100) } }
            .sorted { $0.percent != $1.percent ? $0.percent > $1.percent : $0.reason.rawValue < $1.reason.rawValue }
    }

    enum CodingKeys: String, CodingKey {
        case room
        case startS = "start_s"
        case endS = "end_s"
        case movedM = "moved_m"
        case heightChangeM = "height_change_m"
        case atRoomEnd = "at_room_end"
        case reasons
    }
}

struct LidarGapTracker: Sendable {
    static let minGapS: TimeInterval = 2
    static let pollStallS: TimeInterval = 0.5
    static let expectedPollS: TimeInterval = 0.1
    static let maxGaps = 200

    private(set) var gaps: [LidarRecordingGap] = []
    private(set) var totals: [String: Int] = [:]
    private var origin: TimeInterval?
    private var room = 0
    private var lastRecordedAt: TimeInterval?
    private var lastRecordedPosition: SIMD3<Float>?
    private var latestPosition: SIMD3<Float>?
    private var lastTickAt: TimeInterval?
    private var pending: [String: Int] = [:]

    var gapSeconds: Double {
        gaps.reduce(0) { $0 + $1.durationS }
    }

    mutating func startRoom(at time: TimeInterval) {
        if origin == nil { origin = time }
        room += 1
        lastRecordedAt = time
        lastRecordedPosition = nil
        latestPosition = nil
        lastTickAt = time
        pending = [:]
    }

    mutating func tick(at time: TimeInterval) {
        if let last = lastTickAt, time - last > Self.pollStallS {
            add(.pollStalled, count: max(1, Int(((time - last) / Self.expectedPollS).rounded()) - 1))
        }
        lastTickAt = time
    }

    mutating func seen(position: SIMD3<Float>) {
        latestPosition = position
    }

    mutating func skipped(_ reason: LidarSkipReason) {
        add(reason, count: 1)
    }

    @discardableResult
    mutating func recorded(at time: TimeInterval, position: SIMD3<Float>) -> LidarRecordingGap? {
        if let lastRecordedAt, time <= lastRecordedAt { return nil }
        let gap = closeGap(at: time, end: position, atRoomEnd: false)
        lastRecordedAt = time
        lastRecordedPosition = position
        latestPosition = position
        pending = [:]
        return gap
    }

    @discardableResult
    mutating func finishRoom(at time: TimeInterval) -> LidarRecordingGap? {
        let gap = closeGap(at: time, end: latestPosition, atRoomEnd: true)
        lastRecordedAt = nil
        lastRecordedPosition = nil
        lastTickAt = nil
        pending = [:]
        return gap
    }

    private mutating func add(_ reason: LidarSkipReason, count: Int) {
        guard lastRecordedAt != nil, count > 0 else { return }
        totals[reason.rawValue, default: 0] += count
        pending[reason.rawValue, default: 0] += count
    }

    private mutating func closeGap(at time: TimeInterval, end: SIMD3<Float>?, atRoomEnd: Bool) -> LidarRecordingGap? {
        guard let start = lastRecordedAt, let origin, time - start >= Self.minGapS else { return nil }
        var moved: Double?
        var height: Double?
        if let from = lastRecordedPosition, let end {
            moved = Double(simd_distance(from, end))
            height = Double(end.y - from.y)
        }
        let gap = LidarRecordingGap(
            room: room,
            startS: start - origin,
            endS: time - origin,
            movedM: moved,
            heightChangeM: height,
            atRoomEnd: atRoomEnd,
            reasons: pending
        )
        if gaps.count < Self.maxGaps {
            gaps.append(gap)
        } else if let shortest = gaps.indices.min(by: { gaps[$0].durationS < gaps[$1].durationS }), gaps[shortest].durationS < gap.durationS {
            gaps.remove(at: shortest)
            gaps.append(gap)
        }
        return gap
    }
}
