import Foundation

struct RoomPhotoCoverageTracker: Equatable {
    static let headingSectors = 12
    static let pitchBands = 3

    private(set) var coveredCells: Set<Int> = []

    mutating func record(headingDeg: Double, pitchDeg: Double) {
        let sectorWidth = 360.0 / Double(Self.headingSectors)
        var normalizedHeading = headingDeg.truncatingRemainder(dividingBy: 360)
        if normalizedHeading < 0 { normalizedHeading += 360 }
        var sector = Int((normalizedHeading / sectorWidth).rounded()) % Self.headingSectors
        if sector < 0 { sector += Self.headingSectors }

        let band: Int
        if pitchDeg < -15 {
            band = 0
        } else if pitchDeg > 15 {
            band = 2
        } else {
            band = 1
        }

        coveredCells.insert(sector * Self.pitchBands + band)
    }

    mutating func reset() {
        coveredCells.removeAll()
    }

    var coveragePercent: Double {
        let total = Self.headingSectors * Self.pitchBands
        guard total > 0 else { return 0 }
        return Double(coveredCells.count) / Double(total)
    }

    var coveredCellCount: Int {
        coveredCells.count
    }

    var totalCellCount: Int {
        Self.headingSectors * Self.pitchBands
    }
}
