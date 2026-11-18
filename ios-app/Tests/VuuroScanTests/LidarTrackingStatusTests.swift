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

    func testAppNotInFrontSaysRecordingPausedNotKeepSteady() {
        let message = LidarRecordingStatus.message(.appInactive)
        XCTAssertTrue(message.hasPrefix("Recording paused"))
        XCTAssertFalse(message.contains("steady"))
    }

    private func frame(_ index: Int) -> MeshFrame {
        MeshFrame(index: index, cameraTransform: matrix_identity_float4x4, verticalFieldOfView: 60, imageURL: nil, imageWidth: 1920, imageHeight: 1440, fx: 1337, fy: 1337, cx: 960, cy: 720, depthURL: nil, confidenceURL: nil, depthWidth: 0, depthHeight: 0)
    }

    func testFramesBeforeTheLastResetInTheSameRoomAreDropped() {
        let frames = (1...10).map(frame)
        let resets = [
            LidarPoseReset(room: 1, atS: 20, roomFirstKeyframe: 1, firstKeyframeAfter: 4),
            LidarPoseReset(room: 1, atS: 50, roomFirstKeyframe: 1, firstKeyframeAfter: 7)
        ]
        let result = LidarPoseReset.usable(frames, resets: resets)
        XCTAssertEqual(result.frames.map(\.index), [7, 8, 9, 10])
        XCTAssertEqual(result.dropped, 6)
    }

    func testAResetInOneRoomKeepsTheOtherRoomsFrames() {
        let frames = (1...8).map(frame)
        let resets = [LidarPoseReset(room: 2, atS: 90, roomFirstKeyframe: 5, firstKeyframeAfter: 7)]
        let result = LidarPoseReset.usable(frames, resets: resets)
        XCTAssertEqual(result.frames.map(\.index), [1, 2, 3, 4, 7, 8])
        XCTAssertEqual(result.dropped, 2)
    }

    func testNoResetsKeepsEveryFrame() {
        let frames = (1...3).map(frame)
        let result = LidarPoseReset.usable(frames, resets: [])
        XCTAssertEqual(result.frames.count, 3)
        XCTAssertEqual(result.dropped, 0)
    }

    func testResetEventsRoundTripWithSnakeCaseKeys() throws {
        var stats = LidarCaptureStats()
        stats.poseResets = 1
        stats.poseResetEvents = [LidarPoseReset(room: 1, atS: 31.5, roomFirstKeyframe: 1, firstKeyframeAfter: 126)]
        let data = try JSONEncoder().encode(stats)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"pose_reset_events\""))
        XCTAssertEqual(try JSONDecoder().decode(LidarCaptureStats.self, from: data), stats)
    }

    private func pose(x: Float, yawDeg: Float) -> simd_float4x4 {
        let r = yawDeg * .pi / 180
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(cos(r), 0, -sin(r), 0)
        m.columns.2 = SIMD4<Float>(sin(r), 0, cos(r), 0)
        m.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return m
    }

    func testSlowHandIsSteadyAndFastTurnIsNot() {
        var motion = LidarMotionSpeed()
        motion.update(pose(x: 0, yawDeg: 0), at: 10)
        motion.update(pose(x: 0.02, yawDeg: 2), at: 10.1)
        XCTAssertTrue(motion.steady)
        motion.update(pose(x: 0.02, yawDeg: 12), at: 10.2)
        XCTAssertGreaterThan(motion.angularDegPerS, 90)
        XCTAssertFalse(motion.steady)
    }

    func testFastWalkIsNotSteady() {
        var motion = LidarMotionSpeed()
        motion.update(pose(x: 0, yawDeg: 0), at: 5)
        motion.update(pose(x: 0.2, yawDeg: 0), at: 5.1)
        XCTAssertEqual(motion.linearMPerS, 2, accuracy: 0.01)
        XCTAssertFalse(motion.steady)
    }

    func testBlurryFrameIsHeldOnlyForALimitedTime() {
        XCTAssertTrue(LidarMotionSpeed.holdsKeyframe(steady: false, secondsSinceLastKeyframe: 0.5))
        XCTAssertFalse(LidarMotionSpeed.holdsKeyframe(steady: false, secondsSinceLastKeyframe: 1.6))
        XCTAssertFalse(LidarMotionSpeed.holdsKeyframe(steady: true, secondsSinceLastKeyframe: 0.5))
        XCTAssertFalse(LidarMotionSpeed.holdsKeyframe(steady: false, secondsSinceLastKeyframe: .infinity))
    }
}
