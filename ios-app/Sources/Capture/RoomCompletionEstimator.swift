import Foundation

struct RoomCompletionStatus: Equatable {
    enum Stage: Equatable {
        case keepScanning
        case almostThere
        case ready
    }

    let stage: Stage
    let stableAreaM2: Double?

    static let scanning = RoomCompletionStatus(stage: .keepScanning, stableAreaM2: nil)
}

struct RoomCompletionEstimator {
    private var recentAreas: [Double] = []
    private var recentWallCounts: [Int] = []

    private static let windowSize = 6
    private static let minimumSamplesForStableArea = 3
    private static let minimumWalls = 3
    private static let minimumAreaM2 = 0.5
    private static let areaTolerance = 0.05

    mutating func update(stats: CaptureLiveStats, isApproachingSizeLimit: Bool) -> RoomCompletionStatus {
        recentAreas.append(stats.areaM2)
        recentWallCounts.append(stats.walls)
        if recentAreas.count > Self.windowSize {
            recentAreas.removeFirst()
        }
        if recentWallCounts.count > Self.windowSize {
            recentWallCounts.removeFirst()
        }

        guard stats.walls >= Self.minimumWalls, stats.areaM2 > Self.minimumAreaM2 else {
            return .scanning
        }

        let stableArea = stableAreaValue()

        if isApproachingSizeLimit {
            return RoomCompletionStatus(stage: .almostThere, stableAreaM2: stableArea)
        }

        guard stableArea != nil else {
            return .scanning
        }

        let wallsStable: Bool
        if recentWallCounts.count < Self.windowSize {
            wallsStable = false
        } else {
            var counts: [Int: Int] = [:]
            for w in recentWallCounts { counts[w, default: 0] += 1 }
            wallsStable = (counts.values.max() ?? 0) >= Self.windowSize - 2
        }
        let hasOpening = (stats.doors + stats.windows + stats.openings) >= 1

        if wallsStable, hasOpening {
            return RoomCompletionStatus(stage: .ready, stableAreaM2: stableArea)
        }

        return RoomCompletionStatus(stage: .almostThere, stableAreaM2: stableArea)
    }

    private func stableAreaValue() -> Double? {
        guard recentAreas.count >= Self.minimumSamplesForStableArea else { return nil }
        let mean = recentAreas.reduce(0, +) / Double(recentAreas.count)
        guard mean > 0 else { return nil }
        let maxDeviation = recentAreas.map { abs($0 - mean) / mean }.max() ?? 1
        return maxDeviation < Self.areaTolerance ? mean : nil
    }
}
