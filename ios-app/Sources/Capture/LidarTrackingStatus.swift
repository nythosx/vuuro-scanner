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

    nonisolated static func message(_ reason: LidarSkipReason) -> String {
        switch reason {
        case .trackingExcessiveMotion:
            return vuuroLocalized("Slow down. Tracking is lost, so nothing is being recorded.")
        case .trackingInsufficientFeatures:
            return vuuroLocalized("Point at furniture or a wall edge, not a blank floor or wall. Tracking is lost, so nothing is being recorded.")
        case .lowStorage:
            return vuuroLocalized("Phone storage is full, so LiDAR stopped saving frames. The room plan and the mesh are still saved. Finish this room.")
        case .trackingInitializing, .trackingRelocalizing, .poseJump:
            return vuuroLocalized("Hold still and point back at where you just were. Tracking is recovering, so nothing is being recorded.")
        default:
            return vuuroLocalized("LiDAR is not recording right now. Keep the phone steady and point at the room.")
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
