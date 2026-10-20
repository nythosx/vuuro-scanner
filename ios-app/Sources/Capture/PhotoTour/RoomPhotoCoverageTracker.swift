import CoreGraphics
import Foundation

struct RoomPhotoCoverageTracker {
    static let defaultCellSizeM = 1.0

    private(set) var coverage: RoomPhotoCoverage

    init(
        outline: [CGPoint],
        cellSizeM: Double = RoomPhotoCoverageTracker.defaultCellSizeM,
        roomHeadingDeg: Double? = nil
    ) {
        self.coverage = RoomPhotoCoverage(
            outline: outline,
            cellSizeM: cellSizeM,
            roomHeadingDeg: roomHeadingDeg
        )
    }

    mutating func record(positionM: CGPoint, cameraHeadingDeg: Double) {
        coverage.record(positionM: positionM, cameraHeadingDeg: cameraHeadingDeg)
    }

    mutating func reset() {
        coverage.reset()
    }

    var positionCoverage: Double { coverage.positionCoverage }
    var wallCoverage: Double { coverage.wallCoverage }
    var overallCoverage: Double { coverage.overallCoverage }
    var isReadyToFinish: Bool { coverage.isReadyToFinish }
    var nextAction: String? { coverage.nextAction }
    var coveredCellCount: Int { coverage.coveredCells.count }
    var coveredWallCount: Int { coverage.coveredWalls.count }
    var totalCellCount: Int { coverage.inRoomCells.count }
    var totalWallCount: Int { coverage.walls.count }
}
