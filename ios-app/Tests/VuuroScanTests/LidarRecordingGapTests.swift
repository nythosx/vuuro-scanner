import ARKit
import XCTest
@testable import VuuroScan

final class LidarRecordingGapTests: XCTestCase {
    func testShortPauseIsNotAGap() {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 100)
        tracker.recorded(at: 100.1, position: SIMD3(0, 0, 0))
        tracker.skipped(.notMoved)
        XCTAssertNil(tracker.recorded(at: 101.5, position: SIMD3(0.2, 0, 0)))
        XCTAssertTrue(tracker.gaps.isEmpty)
    }

    func testGapKeepsReasonsMovementAndTimesFromCaptureStart() throws {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 100)
        tracker.recorded(at: 110, position: SIMD3(0, 0, 0))
        for _ in 0..<8 { tracker.skipped(.trackingExcessiveMotion) }
        for _ in 0..<2 { tracker.skipped(.noDepth) }
        let gap = try XCTUnwrap(tracker.recorded(at: 155, position: SIMD3(4, 1.5, 0)))
        XCTAssertEqual(gap.room, 1)
        XCTAssertEqual(gap.startS, 10, accuracy: 0.001)
        XCTAssertEqual(gap.endS, 55, accuracy: 0.001)
        XCTAssertEqual(gap.durationS, 45, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(gap.movedM), Double(simd_length(SIMD3<Float>(4, 1.5, 0))), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(gap.heightChangeM), 1.5, accuracy: 0.001)
        XCTAssertFalse(gap.atRoomEnd)
        XCTAssertEqual(gap.mainReason, .trackingExcessiveMotion)
        XCTAssertEqual(gap.reasonShares.first?.percent ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(tracker.gaps.count, 2)
        XCTAssertEqual(tracker.gaps.last, gap)
    }

    func testLateSaveOfAnOlderFrameDoesNotMoveTheClockBack() {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        tracker.recorded(at: 10, position: SIMD3(0, 0, 0))
        XCTAssertNil(tracker.recorded(at: 9.9, position: SIMD3(0, 0, 0)))
        tracker.skipped(.trackingExcessiveMotion)
        let gap = tracker.recorded(at: 13, position: SIMD3(0, 0, 0))
        XCTAssertEqual(gap?.startS ?? -1, 10, accuracy: 0.001)
    }

    func testFullGapListKeepsTheLongestGaps() {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        var time: TimeInterval = 0
        for _ in 0..<LidarGapTracker.maxGaps {
            time += 3
            tracker.recorded(at: time, position: SIMD3(0, 0, 0))
        }
        time += 45
        tracker.recorded(at: time, position: SIMD3(0, 0, 0))
        XCTAssertEqual(tracker.gaps.count, LidarGapTracker.maxGaps)
        XCTAssertEqual(tracker.gaps.map(\.durationS).max() ?? 0, 45, accuracy: 0.001)
    }

    func testWriteFailureIsAReason() {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        tracker.recorded(at: 1, position: SIMD3(0, 0, 0))
        for _ in 0..<5 { tracker.skipped(.writeFailed) }
        XCTAssertEqual(tracker.recorded(at: 10, position: SIMD3(0, 0, 0))?.mainReason, .writeFailed)
    }

    func testReasonsResetAfterEachRecordedFrame() throws {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        tracker.recorded(at: 0, position: SIMD3(0, 0, 0))
        tracker.skipped(.noDepth)
        tracker.recorded(at: 1, position: SIMD3(0, 0, 0))
        tracker.skipped(.trackingInsufficientFeatures)
        let gap = try XCTUnwrap(tracker.recorded(at: 4, position: SIMD3(0, 0, 0)))
        XCTAssertEqual(gap.reasons, ["tracking_insufficient_features": 1])
        XCTAssertEqual(tracker.totals, ["no_depth": 1, "tracking_insufficient_features": 1])
    }

    func testTailGapIsClosedWhenTheRoomEnds() throws {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        tracker.recorded(at: 300, position: SIMD3(0, 0, 0))
        tracker.seen(position: SIMD3(0, -1.5, 4.2))
        tracker.skipped(.trackingRelocalizing)
        let gap = try XCTUnwrap(tracker.finishRoom(at: 345))
        XCTAssertTrue(gap.atRoomEnd)
        XCTAssertEqual(gap.durationS, 45, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(gap.heightChangeM), -1.5, accuracy: 0.001)
        XCTAssertEqual(gap.mainReason, .trackingRelocalizing)
    }

    func testGapAtRoomStartHasNoMovement() throws {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        tracker.skipped(.trackingInitializing)
        let gap = try XCTUnwrap(tracker.recorded(at: 3, position: SIMD3(1, 0, 0)))
        XCTAssertEqual(gap.startS, 0, accuracy: 0.001)
        XCTAssertNil(gap.movedM)
        XCTAssertNil(gap.heightChangeM)
    }

    func testPollStallIsCountedInMissedSamples() throws {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        tracker.recorded(at: 0, position: SIMD3(0, 0, 0))
        tracker.tick(at: 0.1)
        tracker.tick(at: 3.1)
        let gap = try XCTUnwrap(tracker.recorded(at: 3.1, position: SIMD3(0, 0, 0)))
        XCTAssertEqual(gap.reasons, ["poll_stalled": 29])
    }

    func testSecondRoomTimesStayOnTheCaptureClock() throws {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 10)
        tracker.recorded(at: 20, position: SIMD3(0, 0, 0))
        tracker.finishRoom(at: 21)
        tracker.skipped(.noFrame)
        tracker.startRoom(at: 50)
        tracker.skipped(.trackingInitializing)
        let gap = try XCTUnwrap(tracker.recorded(at: 54, position: SIMD3(0, 0, 0)))
        XCTAssertEqual(gap.room, 2)
        XCTAssertEqual(gap.startS, 40, accuracy: 0.001)
        XCTAssertEqual(tracker.totals["no_frame"], nil)
    }

    func testGapListIsCapped() {
        var tracker = LidarGapTracker()
        tracker.startRoom(at: 0)
        for index in 0...(LidarGapTracker.maxGaps + 5) {
            tracker.recorded(at: Double(index) * 3, position: SIMD3(0, 0, 0))
        }
        XCTAssertEqual(tracker.gaps.count, LidarGapTracker.maxGaps)
    }

    func testTrackingStatesMapToReasons() {
        XCTAssertNil(LidarSkipReason.tracking(.normal))
        XCTAssertEqual(LidarSkipReason.tracking(.notAvailable), .trackingNotAvailable)
        XCTAssertEqual(LidarSkipReason.tracking(.limited(.initializing)), .trackingInitializing)
        XCTAssertEqual(LidarSkipReason.tracking(.limited(.excessiveMotion)), .trackingExcessiveMotion)
        XCTAssertEqual(LidarSkipReason.tracking(.limited(.insufficientFeatures)), .trackingInsufficientFeatures)
        XCTAssertEqual(LidarSkipReason.tracking(.limited(.relocalizing)), .trackingRelocalizing)
    }

    func testMoreTellingReasonWins() {
        XCTAssertEqual(LidarSkipReason.moreTelling(.notMoved, .writerBusy), .writerBusy)
        XCTAssertEqual(LidarSkipReason.moreTelling(.noDepth, .notMoved), .noDepth)
        XCTAssertEqual(LidarSkipReason.moreTelling(.waiting, .notMoved), .notMoved)
        XCTAssertEqual(LidarSkipReason.moreTelling(.notMoved, .waiting), .notMoved)
    }

    func testOlderManifestWithoutGapsStillDecodes() throws {
        let json = """
        {"created_at":"a","updated_at":"b","device":"iPhone17,1","system_version":"26.0","supports_scene_depth":true,"supports_mesh_classification":true,"config_augmented":false,"config_notes":[],"room_runs":1,"duration_s":10,"version":1,"stats":{"frames":0,"depth_frames":0,"mesh_anchors":0,"mesh_vertices":0,"mesh_faces":0,"frame_bytes":0,"mesh_bytes":0,"scene_depth_seen":false,"mesh_seen":false,"classification_seen":false,"worst_thermal_state":0,"lowest_free_memory_mb":0,"write_failures":0,"skipped_busy_frames":0}}
        """
        let manifest = try JSONDecoder().decode(LidarCaptureManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.recordingGaps)
        XCTAssertNil(manifest.skipReasons)
    }

    func testGapRoundTripsWithSnakeCaseKeys() throws {
        let gap = LidarRecordingGap(room: 1, startS: 10, endS: 55, movedM: 4.5, heightChangeM: 1.5, atRoomEnd: true, reasons: ["tracking_excessive_motion": 3])
        let data = try JSONEncoder().encode(gap)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"start_s\""))
        XCTAssertTrue(text.contains("\"at_room_end\""))
        XCTAssertEqual(try JSONDecoder().decode(LidarRecordingGap.self, from: data), gap)
    }

    func testProofTextNamesTheGap() {
        let gap = LidarRecordingGap(room: 2, startS: 130, endS: 175, movedM: 4.5, heightChangeM: 1.5, atRoomEnd: true, reasons: ["tracking_excessive_motion": 8, "no_depth": 2])
        XCTAssertEqual(
            LiDARProofView.gapText(gap, showRoom: true),
            "Room 2, at 2:10, 45 s, moved 4.5 m, up 1.5 m, until the room ended: tracking limited, moving too fast 80%, no depth in the frame 20%"
        )
    }
}

final class LidarRoomRunReportTests: XCTestCase {
    func testRoomTwoWithNewMeshShowsGrowth() {
        var report = LidarRoomRunReport(room: 2)
        report.configAfter = LidarSessionConfigReport(sceneDepth: true, smoothedSceneDepth: true, sceneReconstruction: "mesh_with_classification")
        report.meshFacesAtStart = 1000
        report.meshFacesMax = 5000
        report.newMeshAnchors = 7
        report.depthSeen = true
        report.keyframes = 40
        report.depthOnlyFrames = 90
        XCTAssertTrue(report.meshGrew)
        XCTAssertEqual(LiDARProofView.roomReportText(report), "mesh_with_classification, 7 new mesh pieces, 1000 to 5000 triangles, depth yes, 40 keyframes + 90 depth-only")
    }

    func testRoomWithoutNewMeshSaysSo() {
        var report = LidarRoomRunReport(room: 2)
        report.meshFacesAtStart = 1000
        report.meshFacesMax = 1000
        XCTAssertFalse(report.meshGrew)
        XCTAssertEqual(LiDARProofView.roomReportText(report), "mesh setting unknown, no new mesh, depth no, 0 keyframes + 0 depth-only")
    }

    func testRoomReportRoundTripsWithSnakeCaseKeys() throws {
        var report = LidarRoomRunReport(room: 1)
        report.newMeshAnchors = 3
        let data = try JSONEncoder().encode(report)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"new_mesh_anchors\""))
        XCTAssertEqual(try JSONDecoder().decode(LidarRoomRunReport.self, from: data), report)
    }
}
