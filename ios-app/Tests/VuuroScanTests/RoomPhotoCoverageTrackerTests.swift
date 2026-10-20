import XCTest
@testable import VuuroScan

final class RoomPhotoCoverageTrackerTests: XCTestCase {

    private func rectangle(_ width: Double = 4.0, _ depth: Double = 3.0) -> [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: depth),
            CGPoint(x: 0, y: depth),
        ]
    }

    private func lShape() -> [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 6, y: 0),
            CGPoint(x: 6, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 6),
            CGPoint(x: 0, y: 6),
        ]
    }

    func testEmptyTrackerHasNoCoverage() {
        let tracker = RoomPhotoCoverageTracker(outline: rectangle())
        XCTAssertEqual(tracker.positionCoverage, 0, accuracy: 1e-9)
        XCTAssertEqual(tracker.wallCoverage, 0, accuracy: 1e-9)
        XCTAssertEqual(tracker.overallCoverage, 0, accuracy: 1e-9)
        XCTAssertFalse(tracker.isReadyToFinish)
        XCTAssertNotNil(tracker.nextAction)
    }

    func testRectangularRoomHasTwelveCells() {
        let tracker = RoomPhotoCoverageTracker(outline: rectangle())
        XCTAssertEqual(tracker.totalCellCount, 12)
        XCTAssertEqual(tracker.totalWallCount, 4)
    }

    func testRectangularRoomWithLargerCellsHasFewerCells() {
        let tracker = RoomPhotoCoverageTracker(outline: rectangle(6, 4), cellSizeM: 2.0)
        XCTAssertEqual(tracker.totalCellCount, 6)
    }

    func testLShapedRoomExcludesNotchCells() {
        let tracker = RoomPhotoCoverageTracker(outline: lShape())
        XCTAssertGreaterThan(tracker.totalCellCount, 6)
        XCTAssertLessThan(tracker.totalCellCount, 30)
    }

    func testRecordingPositionMarksItsCell() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.record(positionM: CGPoint(x: 2.5, y: 1.5), cameraHeadingDeg: 0)
        XCTAssertEqual(tracker.coveredCellCount, 1)
        XCTAssertEqual(tracker.positionCoverage, 1.0 / 12.0, accuracy: 1e-9)
    }

    func testRecordingOutsideRoomDoesNotMarkCell() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.record(positionM: CGPoint(x: -1, y: -1), cameraHeadingDeg: 0)
        XCTAssertEqual(tracker.coveredCellCount, 0)
    }

    func testRayPointsAtCorrectWallForCardinalHeadings() {
        let cases: [(heading: Double, expectedIndex: Int)] = [
            (0, 2),
            (90, 3),
            (180, 0),
            (270, 1),
        ]
        for testCase in cases {
            var tracker = RoomPhotoCoverageTracker(outline: rectangle())
            tracker.record(
                positionM: CGPoint(x: 2, y: 1.5),
                cameraHeadingDeg: testCase.heading
            )
            XCTAssertEqual(
                tracker.coveredWallCount, 1,
                "expected exactly one wall for heading \(testCase.heading)"
            )
            XCTAssertEqual(
                tracker.coverage.coveredWalls.first, testCase.expectedIndex,
                "wrong wall for heading \(testCase.heading)"
            )
        }
    }

    func testRayPointsAtCorrectWallForCardinalHeadingsWithNonZeroRoomHeading() {
        var tracker = RoomPhotoCoverageTracker(
            outline: rectangle(),
            roomHeadingDeg: 90
        )
        tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: 90)
        XCTAssertEqual(tracker.coverage.coveredWalls.first, 2)
    }

    func testThirtySimilarShotsDoNotOverClaimWallCoverage() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for _ in 0..<30 {
            tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: 0)
        }
        XCTAssertEqual(tracker.coveredWallCount, 1)
        XCTAssertEqual(tracker.wallCoverage, 0.25, accuracy: 1e-9)
        XCTAssertEqual(tracker.positionCoverage, 1.0 / 12.0, accuracy: 1e-9)
        XCTAssertFalse(tracker.isReadyToFinish)
    }

    func testFourStrategicShotsCoverAllWallsButNotRoom() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: heading)
        }
        XCTAssertEqual(tracker.wallCoverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tracker.positionCoverage, 1.0 / 12.0, accuracy: 1e-9)
        XCTAssertFalse(tracker.isReadyToFinish)
    }

    func testWalkingEveryCellAndFacingEveryWallReachesReady() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for x in stride(from: 0.5, to: 4.0, by: 1.0) {
            for z in stride(from: 0.5, to: 3.0, by: 1.0) {
                for heading in [0.0, 90.0, 180.0, 270.0] {
                    tracker.record(
                        positionM: CGPoint(x: x, y: z),
                        cameraHeadingDeg: heading
                    )
                }
            }
        }
        XCTAssertEqual(tracker.wallCoverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tracker.positionCoverage, 1.0, accuracy: 1e-9)
        XCTAssertTrue(tracker.isReadyToFinish)
        XCTAssertEqual(tracker.nextAction, "You can finish. Tap Finish when ready.")
    }

    func testNextActionDescribesUncoveredWalls() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: 0)
        let hint = tracker.nextAction ?? ""
        XCTAssertTrue(
            hint.contains("red walls") || hint.contains("uncovered wall"),
            "unexpected hint: \(hint)"
        )
    }

    func testNextActionPromptsWalkingWhenWallsCovered() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: heading)
        }
        let hint = tracker.nextAction ?? ""
        XCTAssertTrue(
            hint.contains("grey") || hint.contains("Walk"),
            "unexpected hint: \(hint)"
        )
    }

    func testResetClearsEverything() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: 0)
        tracker.reset()
        XCTAssertEqual(tracker.coveredCellCount, 0)
        XCTAssertEqual(tracker.coveredWallCount, 0)
        XCTAssertFalse(tracker.isReadyToFinish)
    }

    func testOverlappingCellsAreOnlyMarkedOnce() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for _ in 0..<5 {
            tracker.record(positionM: CGPoint(x: 0.6, y: 0.6), cameraHeadingDeg: 0)
        }
        XCTAssertEqual(tracker.coveredCellCount, 1)
    }

    func testDirectionVectorMatchesProjectionConvention() {
        let empty = RoomPhotoCoverage(outline: rectangle())
        XCTAssertEqual(empty.directionVector(cameraHeadingDeg: 0).x, 0, accuracy: 1e-9)
        XCTAssertEqual(empty.directionVector(cameraHeadingDeg: 0).y, 1, accuracy: 1e-9)
        XCTAssertEqual(empty.directionVector(cameraHeadingDeg: 180).x, 0, accuracy: 1e-9)
        XCTAssertEqual(empty.directionVector(cameraHeadingDeg: 180).y, -1, accuracy: 1e-9)
        XCTAssertEqual(empty.directionVector(cameraHeadingDeg: 90).x, -1, accuracy: 1e-9)
        XCTAssertEqual(empty.directionVector(cameraHeadingDeg: 90).y, 0, accuracy: 1e-9)
    }

    func testDegenerateOutlineHasNoCellsOrWalls() {
        let tracker = RoomPhotoCoverageTracker(outline: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
        ])
        XCTAssertEqual(tracker.totalCellCount, 0)
        XCTAssertEqual(tracker.totalWallCount, 0)
        XCTAssertFalse(tracker.isReadyToFinish)
    }
}
