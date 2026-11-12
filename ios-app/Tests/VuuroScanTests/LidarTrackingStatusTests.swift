import XCTest
@testable import VuuroScan

final class LidarPauseReasonTests: XCTestCase {
    func testStandingStillDoesNotWarnButBlockedSavingDoes() {
        XCTAssertFalse(LidarRecordingStatus.warnsWhenStuck(.notMoved))
        XCTAssertFalse(LidarRecordingStatus.warnsWhenStuck(.waiting))
        XCTAssertTrue(LidarRecordingStatus.warnsWhenStuck(.writerBusy))
        XCTAssertTrue(LidarRecordingStatus.warnsWhenStuck(.noDepth))
        XCTAssertTrue(LidarRecordingStatus.warnsWhenStuck(.lowStorage))
    }
}

final class LidarTrackingStatusTests: XCTestCase {
    func testOneFrameThatJumpsToTheOriginIsDropped() {
        var filter = LidarPoseJumpFilter()
        XCTAssertTrue(filter.accepts(SIMD3(-2.43, -0.68, 0.41), at: 285.43))
        XCTAssertFalse(filter.accepts(SIMD3(0.01, -0.07, -0.18), at: 285.53))
        XCTAssertTrue(filter.accepts(SIMD3(-2.41, -0.63, 0.46), at: 285.67))
    }

    func testNormalWalkingIsKept() {
        var filter = LidarPoseJumpFilter()
        for step in 0..<50 {
            XCTAssertTrue(filter.accepts(SIMD3(Float(step) * 0.15, 0, 0), at: Double(step) * 0.1))
        }
    }

    func testANewPositionThatHoldsIsAcceptedAfterAFewFrames() {
        var filter = LidarPoseJumpFilter()
        XCTAssertTrue(filter.accepts(SIMD3(0, 0, 0), at: 0))
        var accepted = false
        for index in 1...LidarPoseJumpFilter.acceptAfterJumps {
            accepted = filter.accepts(SIMD3(5, 0, 0), at: Double(index) * 0.01)
        }
        XCTAssertTrue(accepted)
        XCTAssertTrue(filter.accepts(SIMD3(5.05, 0, 0), at: 0.1))
    }

    func testWarningShowsOnlyAfterTwoSecondsWithoutTracking() {
        var watch = LidarPauseWatch()
        XCTAssertNil(watch.update(.trackingInsufficientFeatures, at: 10))
        XCTAssertNil(watch.update(.trackingInsufficientFeatures, at: 11.9))
        XCTAssertEqual(watch.update(.trackingInsufficientFeatures, at: 12), .trackingInsufficientFeatures)
        XCTAssertNil(watch.update(nil, at: 12.1))
        XCTAssertNil(watch.update(.trackingExcessiveMotion, at: 13))
    }

    func testEveryReasonHasAMessage() {
        for reason in LidarSkipReason.allCases {
            XCTAssertFalse(LidarRecordingStatus.message(reason).isEmpty)
        }
    }
}
