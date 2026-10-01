import XCTest
@testable import VuuroScan

final class CaptureLiveStatsTests: XCTestCase {
    private func stats(doors: Int = 0, windows: Int = 0, openings: Int = 0) -> CaptureLiveStats {
        CaptureLiveStats(walls: 4, areaM2: 12, heightM: 2.6, doors: doors, windows: windows, openings: openings)
    }

    func testNothingScannedYetIsNotFlagged() {
        XCTAssertNil(CaptureLiveStats.empty.missingOpenings)
    }

    func testWallsWithoutDoorsOrWindowsAreFlagged() {
        XCTAssertEqual(stats().missingOpenings, .doorsAndWindows)
    }

    func testMissingDoorIsFlaggedEvenWithAWindow() {
        XCTAssertEqual(stats(windows: 1).missingOpenings, .doors)
    }

    func testMissingWindowIsFlaggedEvenWithADoor() {
        XCTAssertEqual(stats(doors: 1).missingOpenings, .windows)
    }

    func testAnOpenPassageCountsAsTheDoor() {
        XCTAssertEqual(stats(openings: 1).missingOpenings, .windows)
        XCTAssertNil(stats(windows: 1, openings: 1).missingOpenings)
    }

    func testDoorAndWindowClearsTheFlag() {
        XCTAssertNil(stats(doors: 1, windows: 2).missingOpenings)
    }
}
