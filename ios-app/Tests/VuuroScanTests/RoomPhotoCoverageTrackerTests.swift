import XCTest
@testable import VuuroScan

final class RoomPhotoCoverageTrackerTests: XCTestCase {
    func testFreshTrackerHasNoCoverage() {
        let tracker = RoomPhotoCoverageTracker()
        XCTAssertEqual(tracker.coveredCellCount, 0)
        XCTAssertEqual(tracker.coveragePercent, 0)
        XCTAssertEqual(tracker.totalCellCount, 36)
    }

    func testOnePhotoMarksOneCell() {
        var tracker = RoomPhotoCoverageTracker()
        tracker.record(headingDeg: 0, pitchDeg: 0)
        XCTAssertEqual(tracker.coveredCellCount, 1)
        XCTAssertEqual(tracker.coveragePercent, 1.0 / 36.0, accuracy: 0.0001)
    }

    func testOnePhotoPerSectorFillsAllTwelveInTheLevelBand() {
        var tracker = RoomPhotoCoverageTracker()
        for sector in 0..<RoomPhotoCoverageTracker.headingSectors {
            let heading = Double(sector) * (360.0 / Double(RoomPhotoCoverageTracker.headingSectors)) + 5
            tracker.record(headingDeg: heading, pitchDeg: 0)
        }
        XCTAssertEqual(tracker.coveredCellCount, RoomPhotoCoverageTracker.headingSectors)
        XCTAssertEqual(tracker.coveragePercent, 12.0 / 36.0, accuracy: 0.0001)
    }

    func testRepeatedPhotosInTheSameSectorOnlyFillOneCell() {
        var tracker = RoomPhotoCoverageTracker()
        for _ in 0..<10 {
            tracker.record(headingDeg: 15, pitchDeg: 5)
        }
        XCTAssertEqual(tracker.coveredCellCount, 1)
    }

    func testPitchBandsAreDistinguished() {
        var tracker = RoomPhotoCoverageTracker()
        tracker.record(headingDeg: 0, pitchDeg: -45)
        tracker.record(headingDeg: 0, pitchDeg: 0)
        tracker.record(headingDeg: 0, pitchDeg: 45)
        XCTAssertEqual(tracker.coveredCellCount, 3)
    }

    func testHeadingWrapsAround() {
        var tracker = RoomPhotoCoverageTracker()
        tracker.record(headingDeg: 359, pitchDeg: 0)
        tracker.record(headingDeg: 0, pitchDeg: 0)
        tracker.record(headingDeg: -1, pitchDeg: 0)
        XCTAssertEqual(tracker.coveredCellCount, 1, "359°, 0°, and -1° all belong to the sector spanning [0, 30)")
    }

    func testFullCoverageReachesOne() {
        var tracker = RoomPhotoCoverageTracker()
        for sector in 0..<RoomPhotoCoverageTracker.headingSectors {
            for pitchDeg in [-45.0, 0.0, 45.0] {
                let heading = Double(sector) * (360.0 / Double(RoomPhotoCoverageTracker.headingSectors)) + 1
                tracker.record(headingDeg: heading, pitchDeg: pitchDeg)
            }
        }
        XCTAssertEqual(tracker.coveragePercent, 1.0, accuracy: 0.0001)
    }

    func testResetClearsEverything() {
        var tracker = RoomPhotoCoverageTracker()
        tracker.record(headingDeg: 0, pitchDeg: 0)
        tracker.reset()
        XCTAssertEqual(tracker.coveredCellCount, 0)
    }
}
