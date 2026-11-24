import XCTest
import simd
@testable import VuuroScan

final class LidarPauseReasonTests: XCTestCase {
    func testStandingStillDoesNotWarnButBlockedSavingDoes() {
        XCTAssertFalse(LidarRecordingStatus.warnsWhenStuck(.notMoved))
        XCTAssertFalse(LidarRecordingStatus.warnsWhenStuck(.waiting))
        XCTAssertTrue(LidarRecordingStatus.warnsWhenStuck(.writerBusy))
        XCTAssertTrue(LidarRecordingStatus.warnsWhenStuck(.noDepth))
        XCTAssertTrue(LidarRecordingStatus.warnsWhenStuck(.lowStorage))
    }

    func testHeatNoteOnlyWhenSeriousOrCritical() {
        XCTAssertNil(LidarRecordingStatus.heatNote(.nominal))
        XCTAssertNil(LidarRecordingStatus.heatNote(.fair))
        XCTAssertNotNil(LidarRecordingStatus.heatNote(.serious))
        XCTAssertNotNil(LidarRecordingStatus.heatNote(.critical))
        XCTAssertNotEqual(LidarRecordingStatus.heatNote(.serious), LidarRecordingStatus.heatNote(.critical))
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

    private func timedFrame(_ index: Int, at time: Double) -> MeshFrame {
        var result = frame(index)
        result.timestamp = time
        return result
    }

    func testDepthOnlyFramesBeforeAResetAreDroppedByTheirOwnIndex() {
        let depthFrames = (1...10).map { timedFrame($0, at: Double($0)) }
        let resets = [LidarPoseReset(room: 1, atS: 20, roomFirstKeyframe: 1, firstKeyframeAfter: 4, roomFirstDepthFrame: 2, firstDepthFrameAfter: 6)]
        let result = LidarPoseReset.usableDepthFrames(depthFrames, resets: resets, keyframes: [])
        XCTAssertEqual(result.frames.map(\.index), [1, 6, 7, 8, 9, 10])
        XCTAssertEqual(result.dropped, 4)
    }

    func testOlderCapturesDropDepthOnlyFramesByKeyframeTime() {
        let keyframes = [timedFrame(1, at: 10), timedFrame(2, at: 12), timedFrame(3, at: 20), timedFrame(4, at: 25)]
        let depthFrames = [timedFrame(1, at: 9), timedFrame(2, at: 11), timedFrame(3, at: 19.9), timedFrame(4, at: 20), timedFrame(5, at: 30)]
        let resets = [LidarPoseReset(room: 1, atS: 20, roomFirstKeyframe: 1, firstKeyframeAfter: 3)]
        let result = LidarPoseReset.usableDepthFrames(depthFrames, resets: resets, keyframes: keyframes)
        XCTAssertEqual(result.frames.map(\.index), [1, 4, 5])
        XCTAssertEqual(result.dropped, 2)
    }

    func testDepthOnlyFramesStayWhenTheResetTimeIsUnknown() {
        let depthFrames = [timedFrame(1, at: 5), frame(2)]
        let resets = [LidarPoseReset(room: 1, atS: 20, roomFirstKeyframe: 1, firstKeyframeAfter: 3)]
        let result = LidarPoseReset.usableDepthFrames(depthFrames, resets: resets, keyframes: [frame(1), frame(3)])
        XCTAssertEqual(result.dropped, 0)
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

    func testSteadyFrameIsStillHeldWhenItsBlurIsHigh() {
        XCTAssertTrue(LidarMotionSpeed.holdsKeyframe(steady: true, blurPx: 9, secondsSinceLastKeyframe: 0.5))
        XCTAssertFalse(LidarMotionSpeed.holdsKeyframe(steady: true, blurPx: 2, secondsSinceLastKeyframe: 0.5))
        XCTAssertFalse(LidarMotionSpeed.holdsKeyframe(steady: true, blurPx: 9, secondsSinceLastKeyframe: 1.6))
        XCTAssertFalse(LidarMotionSpeed.holdsKeyframe(steady: false, blurPx: 9, secondsSinceLastKeyframe: 0.5, movedFar: true))
    }

    func testWarnsOnlyWhenMoreThanHalfTheFramesAreLeftOut() {
        XCTAssertTrue(LidarPoseReset.mostlyLeftOut(dropped: 190, total: 200))
        XCTAssertTrue(LidarPoseReset.mostlyLeftOut(dropped: 101, total: 200))
        XCTAssertFalse(LidarPoseReset.mostlyLeftOut(dropped: 100, total: 200))
        XCTAssertFalse(LidarPoseReset.mostlyLeftOut(dropped: 0, total: 0))
    }

    func testConfigAfterKeepsReadingUntilTheMeshShowsOrTheLimitPasses() {
        let early = LidarSessionConfigReport(sceneDepth: true, smoothedSceneDepth: true, sceneReconstruction: "other")
        let later = LidarSessionConfigReport(sceneDepth: true, smoothedSceneDepth: true, sceneReconstruction: "mesh_with_classification")
        XCTAssertFalse(LidarSessionConfigReport.settled(early, secondsSinceFirstRead: 0))
        XCTAssertFalse(LidarSessionConfigReport.settled(early, secondsSinceFirstRead: 9.9))
        XCTAssertTrue(LidarSessionConfigReport.settled(early, secondsSinceFirstRead: 10))
        XCTAssertTrue(LidarSessionConfigReport.settled(later, secondsSinceFirstRead: 0))
        XCTAssertTrue(LidarSessionConfigReport.settled(LidarSessionConfigReport(sceneDepth: true, smoothedSceneDepth: true, sceneReconstruction: "mesh"), secondsSinceFirstRead: 0))
        XCTAssertFalse(LidarSessionConfigReport.settled(LidarSessionConfigReport(sceneDepth: true, smoothedSceneDepth: true, sceneReconstruction: "none"), secondsSinceFirstRead: 1))
    }
}

final class LidarKeyframeBlurTests: XCTestCase {
    func testBlurGrowsWithTurnSpeedAndExposure() {
        let slow = LidarMotionSpeed.blurPixels(angularDegPerS: 10, linearMPerS: 0, exposureS: 1.0 / 60, focalPx: 1400, distanceM: 2)
        let fast = LidarMotionSpeed.blurPixels(angularDegPerS: 40, linearMPerS: 0, exposureS: 1.0 / 60, focalPx: 1400, distanceM: 2)
        let longer = LidarMotionSpeed.blurPixels(angularDegPerS: 40, linearMPerS: 0, exposureS: 1.0 / 30, focalPx: 1400, distanceM: 2)
        XCTAssertEqual(fast, 40 * .pi / 180 * 1400 / 60, accuracy: 0.01)
        XCTAssertLessThan(slow, fast)
        XCTAssertEqual(longer, fast * 2, accuracy: 0.01)
    }

    func testSlidingCloseBlursMoreThanSlidingFar() {
        let near = LidarMotionSpeed.blurPixels(angularDegPerS: 0, linearMPerS: 0.5, exposureS: 1.0 / 60, focalPx: 1400, distanceM: 1)
        let far = LidarMotionSpeed.blurPixels(angularDegPerS: 0, linearMPerS: 0.5, exposureS: 1.0 / 60, focalPx: 1400, distanceM: 4)
        XCTAssertEqual(near, far * 4, accuracy: 0.01)
    }

    func testNoExposureGivesNoBlur() {
        XCTAssertEqual(LidarMotionSpeed.blurPixels(angularDegPerS: 90, linearMPerS: 1, exposureS: 0, focalPx: 1400, distanceM: 2), 0)
        XCTAssertEqual(LidarMotionSpeed.blurPixels(angularDegPerS: 90, linearMPerS: 1, exposureS: .nan, focalPx: 1400, distanceM: 2), 0)
    }

    func testCenterDepthReadsTheMiddlePixel() {
        var millimeters = [UInt16](repeating: 0, count: 16)
        millimeters[2 * 4 + 2] = 1850
        let data = millimeters.withUnsafeBufferPointer { Data(buffer: $0) }
        let depth = LidarDepthCopy(width: 4, height: 4, millimeters: data, confidence: nil)
        XCTAssertEqual(LidarMotionSpeed.centerDepthM(depth) ?? 0, 1.85, accuracy: 1e-4)
        XCTAssertNil(LidarMotionSpeed.centerDepthM(LidarDepthCopy(width: 4, height: 4, millimeters: Data(count: 32), confidence: nil)))
        XCTAssertNil(LidarMotionSpeed.centerDepthM(LidarDepthCopy(width: 4, height: 4, millimeters: Data(count: 4), confidence: nil)))
    }

    func testMedianIgnoresNotANumber() {
        XCTAssertEqual(LidarMotionSpeed.median([5, .nan, 1, 3]), 3)
        XCTAssertEqual(LidarMotionSpeed.median([]), 0)
    }
}
