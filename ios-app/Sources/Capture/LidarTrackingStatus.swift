import SwiftUI
import simd

struct LidarPoseJumpFilter {
    static let maxSpeedMS: Float = 3
    static let slackM: Float = 0.25
    static let acceptAfterJumps = 5

    private var lastTime: TimeInterval?
    private var lastPosition = SIMD3<Float>(0, 0, 0)
    private(set) var jumpsInRow = 0

    mutating func accepts(_ position: SIMD3<Float>, at time: TimeInterval) -> Bool {
        guard let lastTime else {
            keep(position, at: time)
            return true
        }
        let allowed = Self.maxSpeedMS * Float(max(0, time - lastTime)) + Self.slackM
        if simd_distance(position, lastPosition) <= allowed || jumpsInRow + 1 >= Self.acceptAfterJumps {
            keep(position, at: time)
            return true
        }
        jumpsInRow += 1
        return false
    }

    mutating func reset() {
        lastTime = nil
        jumpsInRow = 0
    }

    private mutating func keep(_ position: SIMD3<Float>, at time: TimeInterval) {
        lastTime = time
        lastPosition = position
        jumpsInRow = 0
    }
}

struct LidarMotionSpeed {
    static let steadyAngularDegPerS: Float = 40
    static let steadyLinearMPerS: Float = 0.7
    static let steadyWaitLimitS: TimeInterval = 1.5

    private var last: (pose: simd_float4x4, time: TimeInterval)?
    private(set) var angularDegPerS: Float = 0
    private(set) var linearMPerS: Float = 0

    mutating func update(_ pose: simd_float4x4, at time: TimeInterval) {
        defer { last = (pose, time) }
        guard let last, time > last.time else { return }
        let dt = Float(time - last.time)
        let a = SIMD3<Float>(last.pose.columns.3.x, last.pose.columns.3.y, last.pose.columns.3.z)
        let b = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let fa = simd_normalize(-SIMD3<Float>(last.pose.columns.2.x, last.pose.columns.2.y, last.pose.columns.2.z))
        let fb = simd_normalize(-SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
        let cosine = max(-1, min(1, simd_dot(fa, fb)))
        angularDegPerS = acos(cosine) * 180 / .pi / dt
        linearMPerS = simd_distance(a, b) / dt
    }

    mutating func reset() {
        last = nil
        angularDegPerS = 0
        linearMPerS = 0
    }

    var steady: Bool {
        angularDegPerS <= Self.steadyAngularDegPerS && linearMPerS <= Self.steadyLinearMPerS
    }

    static func holdsKeyframe(steady: Bool, secondsSinceLastKeyframe: TimeInterval) -> Bool {
        !steady && secondsSinceLastKeyframe < steadyWaitLimitS
    }
}

struct LidarPoseReset: Codable, Equatable, Sendable {
    var room: Int
    var atS: Double
    var roomFirstKeyframe: Int
    var firstKeyframeAfter: Int

    enum CodingKeys: String, CodingKey {
        case room
        case atS = "at_s"
        case roomFirstKeyframe = "room_first_keyframe"
        case firstKeyframeAfter = "first_keyframe_after"
    }

    static func usable(_ frames: [MeshFrame], resets: [LidarPoseReset]) -> (frames: [MeshFrame], dropped: Int) {
        var cutoffs: [Int: (first: Int, before: Int)] = [:]
        for reset in resets {
            if let known = cutoffs[reset.room], known.before >= reset.firstKeyframeAfter { continue }
            cutoffs[reset.room] = (reset.roomFirstKeyframe, reset.firstKeyframeAfter)
        }
        let kept = frames.filter { frame in
            !cutoffs.values.contains { frame.index >= $0.first && frame.index < $0.before }
        }
        return (kept, frames.count - kept.count)
    }
}

struct LidarPauseWatch {
    static let showAfterS: TimeInterval = 2

    private var since: TimeInterval?

    mutating func update(_ reason: LidarSkipReason?, at time: TimeInterval) -> LidarSkipReason? {
        guard let reason else {
            since = nil
            return nil
        }
        let start = since ?? time
        since = start
        return time - start >= Self.showAfterS ? reason : nil
    }

    mutating func reset() {
        since = nil
    }
}

@MainActor
final class LidarRecordingStatus: ObservableObject {
    @Published private(set) var pausedReason: LidarSkipReason?
    @Published private(set) var storageNote: String?
    private var watch = LidarPauseWatch()

    @discardableResult
    func update(_ reason: LidarSkipReason?, at time: TimeInterval) -> Bool {
        let shown = watch.update(reason, at: time)
        guard shown != pausedReason else { return false }
        pausedReason = shown
        return shown != nil
    }

    func clear() {
        watch.reset()
        if pausedReason != nil { pausedReason = nil }
    }

    func setStorageNote(_ note: String?) {
        if note != storageNote { storageNote = note }
    }

    nonisolated static func warnsWhenStuck(_ reason: LidarSkipReason) -> Bool {
        switch reason {
        case .notMoved, .waiting: return false
        case .noFrame, .sameFrame, .trackingNotAvailable, .trackingInitializing, .trackingExcessiveMotion, .trackingInsufficientFeatures, .trackingRelocalizing, .trackingLimitedOther, .noDepth, .writerBusy, .writeFailed, .pollStalled, .poseJump, .lowStorage, .appInactive: return true
        }
    }

    nonisolated static func message(_ reason: LidarSkipReason) -> String {
        switch reason {
        case .trackingExcessiveMotion:
            return vuuroLocalized("Slow down. Nothing is being recorded.")
        case .trackingInsufficientFeatures:
            return vuuroLocalized("Point at furniture or a wall edge. Nothing is being recorded.")
        case .lowStorage:
            return vuuroLocalized("Phone storage is full. Finish this room; the plan and mesh are kept.")
        case .trackingInitializing, .trackingRelocalizing, .poseJump:
            return vuuroLocalized("Hold still and point back where you were. Nothing is being recorded.")
        case .noDepth:
            return vuuroLocalized("Point at a wall or the floor nearby. Nothing is being recorded.")
        case .writerBusy, .writeFailed:
            return vuuroLocalized("Still saving. Slow down for a moment.")
        case .appInactive:
            return vuuroLocalized("Recording paused. Come back to the app and keep scanning.")
        case .noFrame, .sameFrame, .trackingNotAvailable, .trackingLimitedOther, .notMoved, .waiting, .pollStalled:
            return vuuroLocalized("LiDAR is not recording. Keep the phone steady and point at the room.")
        }
    }
}

struct LidarRecordingPausedBanner: View {
    @ObservedObject var status: LidarRecordingStatus

    var body: some View {
        VStack(spacing: 6) {
            if let reason = status.pausedReason {
                line(LidarRecordingStatus.message(reason), icon: "exclamationmark.triangle.fill")
                    .accessibilityIdentifier("capture.lidarPaused")
            }
            if let note = status.storageNote, status.pausedReason != .lowStorage {
                line(note, icon: "internaldrive")
                    .accessibilityIdentifier("capture.lidarStorage")
            }
        }
        .padding(.horizontal, 16)
    }

    private func line(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 8)
    }
}
