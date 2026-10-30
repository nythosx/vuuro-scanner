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

    func testShortWallCountsOnceItsNeighbourIsPhotographed() {
        let notched = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 4, y: 0),
            CGPoint(x: 4, y: 2.3),
            CGPoint(x: 3.3, y: 2.3),
            CGPoint(x: 3.3, y: 3),
            CGPoint(x: 0, y: 3),
        ]
        var tracker = RoomPhotoCoverageTracker(outline: notched)
        XCTAssertEqual(tracker.totalWallCount, 6)
        tracker.record(positionM: CGPoint(x: 2, y: 1), cameraHeadingDeg: 270)
        XCTAssertEqual(tracker.coverage.photographedWalls, [1])
        XCTAssertEqual(tracker.coverage.coveredWalls, [1, 2])
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

    func testWallsCoveredFinishALargeRoomWithoutWalking() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle(9, 6))
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 4.5, y: 3), cameraHeadingDeg: heading)
        }
        XCTAssertEqual(tracker.wallCoverage, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(tracker.walkablePositionCoverage, 0.5)
        XCTAssertTrue(tracker.isReadyToFinish)
        XCTAssertEqual(tracker.overallCoverage, 1.0, accuracy: 1e-9)
    }

    func testFourShotsFromTheMiddleFinishASmallRoom() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: heading)
        }
        XCTAssertEqual(tracker.wallCoverage, 1.0, accuracy: 1e-9)
        XCTAssertTrue(tracker.isReadyToFinish)
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
        XCTAssertEqual(tracker.coverage.nextActionStructured?.gate, .ready)
    }

    func testNextActionDescribesUncoveredWalls() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: 0)
        let action = tracker.coverage.nextActionStructured
        guard let action else { return XCTFail("expected a next action") }
        if case .walls(let remaining) = action.gate {
            XCTAssertGreaterThan(remaining, 0)
        } else {
            XCTFail("expected walls gate, got \(action.gate)")
        }
    }

    func testNextActionIsReadyWhenWallsCoveredWithoutWalking() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle(9, 6))
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 4.5, y: 3), cameraHeadingDeg: heading)
        }
        XCTAssertEqual(tracker.coverage.nextActionStructured?.gate, .ready)
    }

    func testDeviceAtticAtThePhotoCapCanFinish() {
        let attic = [
            CGPoint(x: 0.536, y: 10.77), CGPoint(x: 0.714, y: 8.983), CGPoint(x: 0, y: 8.912),
            CGPoint(x: 0.499, y: 3.904), CGPoint(x: 0.888, y: 0), CGPoint(x: 6.648, y: 0.574),
            CGPoint(x: 6.263, y: 4.438), CGPoint(x: 4.008, y: 4.214), CGPoint(x: 3.732, y: 6.991),
            CGPoint(x: 5.979, y: 7.215), CGPoint(x: 5.758, y: 9.433), CGPoint(x: 5.116, y: 9.369),
            CGPoint(x: 4.932, y: 11.208),
        ]
        var tracker = RoomPhotoCoverageTracker(outline: attic)
        for heading in stride(from: 0.0, to: 360.0, by: 15.0) {
            tracker.record(positionM: CGPoint(x: 2.5, y: 2.5), cameraHeadingDeg: heading)
            tracker.record(positionM: CGPoint(x: 2.5, y: 8.5), cameraHeadingDeg: heading)
        }
        XCTAssertGreaterThanOrEqual(tracker.wallCoverage, RoomPhotoCoverage.readyWallCoverage)
        XCTAssertLessThan(tracker.walkablePositionCoverage, RoomPhotoCoverage.readyPositionCoverage)
        XCTAssertTrue(tracker.isReadyToFinish, "walking must not block Finish once the walls are covered")
    }

    func testMinimapCellsAreTheCellsThatCountAsWalked() {
        let tracker = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        XCTAssertEqual(tracker.coverage.minimapCells, tracker.coverage.walkableCells)
    }

    func testCellsNearTheWallsAreShownAsNotWalkable() {
        let coverage = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0)).coverage
        XCTAssertFalse(coverage.notWalkableCells.isEmpty)
        XCTAssertTrue(coverage.notWalkableCells.isDisjoint(with: coverage.walkableCells))
        XCTAssertEqual(coverage.notWalkableCells.union(coverage.walkableCells), coverage.inRoomCells)
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

    func testWalkingFillsPositionWithoutPhotos() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for x in stride(from: 0.5, to: 4.0, by: 1.0) {
            tracker.recordWalk(positionM: CGPoint(x: x, y: 1.5))
        }
        XCTAssertEqual(tracker.coveredCellCount, 4)
        XCTAssertEqual(tracker.coveredWallCount, 0)
        XCTAssertEqual(tracker.positionCoverage, 4.0 / 12.0, accuracy: 1e-9)
    }

    func testDeletingPhotosKeepsWalkedArea() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.recordWalk(positionM: CGPoint(x: 0.5, y: 0.5))
        tracker.record(positionM: CGPoint(x: 3.5, y: 2.5), cameraHeadingDeg: 0)
        tracker.reset()
        XCTAssertEqual(tracker.coveredCellCount, 1)
        XCTAssertEqual(tracker.coveredWallCount, 0)
    }

    func testStraightWallSplitIntoSegmentsCountsAsOneWall() {
        let outline = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2.31, y: 0),
            CGPoint(x: 5.06, y: 0.02),
            CGPoint(x: 8.95, y: 0),
            CGPoint(x: 8.95, y: 6),
            CGPoint(x: 0, y: 6),
        ]
        let tracker = RoomPhotoCoverageTracker(outline: outline)
        XCTAssertEqual(tracker.totalWallCount, 4)
    }

    func testShortJogsAreNotCountedAsWalls() {
        let outline = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 4, y: 0),
            CGPoint(x: 4, y: 0.2),
            CGPoint(x: 8, y: 0.2),
            CGPoint(x: 8, y: 5),
            CGPoint(x: 0, y: 5),
        ]
        let tracker = RoomPhotoCoverageTracker(outline: outline)
        XCTAssertEqual(tracker.totalWallCount, 4)
    }

    func testAtticSizedRoomIsReachableWithinThePhotoCap() {
        let attic = [
            CGPoint(x: 0, y: 0.69),
            CGPoint(x: 1.79, y: 0.69),
            CGPoint(x: 1.79, y: 0),
            CGPoint(x: 10.74, y: 0),
            CGPoint(x: 10.74, y: 5.76),
            CGPoint(x: 1.79, y: 5.76),
            CGPoint(x: 1.79, y: 5.09),
            CGPoint(x: 0, y: 5.09),
        ]
        var tracker = RoomPhotoCoverageTracker(outline: attic)
        for x in stride(from: 0.5, to: 10.74, by: 1.0) {
            for z in [0.5, 1.5, 2.5, 3.5, 4.5, 5.4] {
                tracker.recordWalk(positionM: CGPoint(x: x, y: z))
            }
        }
        var photos = 0
        for (position, heading) in [
            (CGPoint(x: 6, y: 2.9), 0.0), (CGPoint(x: 6, y: 2.9), 180.0),
            (CGPoint(x: 6, y: 2.9), 270.0), (CGPoint(x: 3, y: 2.9), 90.0),
            (CGPoint(x: 0.9, y: 2.9), 90.0), (CGPoint(x: 1.0, y: 2.9), 0.0),
            (CGPoint(x: 1.0, y: 2.9), 180.0), (CGPoint(x: 3, y: 0.3), 90.0),
            (CGPoint(x: 3, y: 5.4), 90.0),
        ] {
            tracker.record(positionM: position, cameraHeadingDeg: heading)
            photos += 1
        }
        XCTAssertLessThanOrEqual(photos, 30)
        XCTAssertGreaterThanOrEqual(tracker.positionCoverage, RoomPhotoCoverage.readyPositionCoverage)
        XCTAssertGreaterThanOrEqual(tracker.wallCoverage, RoomPhotoCoverage.readyWallCoverage)
        XCTAssertTrue(tracker.isReadyToFinish)
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

    func testWalkRasterisationCoversMultipleCells() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.recordWalk(positionM: CGPoint(x: 0.5, y: 1.5))
        tracker.recordWalk(positionM: CGPoint(x: 3.5, y: 1.5))
        XCTAssertGreaterThanOrEqual(
            tracker.coveredCellCount, 3,
            "walking across the room should mark every cell the path crossed"
        )
    }

    func testWalkableCellsSkipTheBandAlongTheWalls() {
        let attic = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        XCTAssertEqual(attic.coverage.inRoomCells.count, 54)
        XCTAssertEqual(attic.coverage.walkableCells.count, 28)
        let small = RoomPhotoCoverageTracker(outline: rectangle())
        XCTAssertEqual(small.coverage.walkableCells.count, 2)
    }

    func testLargeRoomReachesReadyInOnePassWithWalkingAndFewPhotos() {
        let outline = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 6),
            CGPoint(x: 0, y: 6),
        ]
        var tracker = RoomPhotoCoverageTracker(outline: outline)
        for x in stride(from: 0.5, to: 10.0, by: 1.0) {
            for y in stride(from: 0.5, to: 6.0, by: 1.0) {
                tracker.recordWalk(positionM: CGPoint(x: x, y: y))
            }
        }
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 5, y: 3), cameraHeadingDeg: heading)
        }
        XCTAssertTrue(
            tracker.isReadyToFinish,
            "a 60 m2 room walked end-to-end with 4 strategic photos should be ready"
        )
    }

    func testOnePassThroughASlopedAtticReachesReady() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        for x in stride(from: 0.6, through: 8.4, by: 0.6) {
            tracker.recordWalk(positionM: CGPoint(x: x, y: 2.6))
        }
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 4.5, y: 3.0), cameraHeadingDeg: heading)
        }
        XCTAssertLessThan(tracker.positionCoverage, RoomPhotoCoverage.readyPositionCoverage)
        XCTAssertGreaterThanOrEqual(tracker.walkablePositionCoverage, RoomPhotoCoverage.readyPositionCoverage)
        XCTAssertTrue(tracker.isReadyToFinish)
    }

    func testStandingStillDoesNotFillALargeRoom() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        for _ in 0..<10 {
            tracker.recordWalk(positionM: CGPoint(x: 4.5, y: 3.0))
        }
        XCTAssertLessThan(tracker.walkablePositionCoverage, RoomPhotoCoverage.readyPositionCoverage)
    }

    func testTrackingJumpDoesNotPaintAPath() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        tracker.recordWalk(positionM: CGPoint(x: 1.5, y: 1.5))
        tracker.recordWalk(positionM: CGPoint(x: 7.5, y: 4.5))
        XCTAssertEqual(tracker.coverage.walkedCells.count, 2)
    }

    func testEndedWalkSegmentDoesNotJoinTheNextWalk() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        tracker.recordWalk(positionM: CGPoint(x: 1.5, y: 1.5))
        tracker.endWalkSegment()
        tracker.recordWalk(positionM: CGPoint(x: 3.5, y: 1.5))
        XCTAssertEqual(tracker.coverage.walkedCells.count, 2)
        tracker.recordWalk(positionM: CGPoint(x: 5.5, y: 1.5))
        XCTAssertEqual(tracker.coverage.walkedCells.count, 4)
    }

    func testReplayingASavedWalkRestoresTheWalkedArea() {
        var live = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        let path = stride(from: 1.0, through: 8.0, by: 0.5).map { CGPoint(x: $0, y: 3.0) }
        for point in path { live.recordWalk(positionM: point) }
        var restored = RoomPhotoCoverageTracker(outline: rectangle(9.0, 6.0))
        for point in path { restored.recordWalk(positionM: point) }
        restored.endWalkSegment()
        XCTAssertEqual(restored.coverage.walkedCells, live.coverage.walkedCells)
        XCTAssertEqual(restored.walkablePositionCoverage, live.walkablePositionCoverage, accuracy: 1e-9)
    }

    func testWalkedRoomWithWallsCoveredIsReadyBeforeAnyCap() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        for x in stride(from: 0.5, to: 4.0, by: 1.0) {
            for y in stride(from: 0.5, to: 3.0, by: 1.0) {
                tracker.recordWalk(positionM: CGPoint(x: x, y: y))
            }
        }
        for heading in [0.0, 90.0, 180.0, 270.0] {
            tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: heading)
        }
        XCTAssertTrue(
            tracker.isReadyToFinish,
            "walked + walls covered should be ready well before any photo cap"
        )
    }

    func testResetKeepsWalkedArea() {
        var tracker = RoomPhotoCoverageTracker(outline: rectangle())
        tracker.recordWalk(positionM: CGPoint(x: 0.5, y: 0.5))
        tracker.record(positionM: CGPoint(x: 3.5, y: 2.5), cameraHeadingDeg: 0)
        XCTAssertGreaterThan(tracker.coverage.walkableCells.count, 0)
        let photoCellsBefore = tracker.coverage.photoCells.count
        XCTAssertGreaterThan(photoCellsBefore, 0)
        tracker.reset()
        XCTAssertGreaterThan(
            tracker.coverage.reachedCells.count, 0,
            "walked area must survive reset — deleting a photo should not erase walking"
        )
        XCTAssertGreaterThan(tracker.coverage.walkedPositions.count, 0)
        XCTAssertEqual(tracker.coverage.photoCells.count, 0, "photo cells are cleared")
    }
}
