import XCTest
import simd
@testable import VuuroScan

final class MeshPhotoTexturerTests: XCTestCase {
    private func camera(at position: SIMD3<Float> = .zero, depth: [UInt16]? = nil) -> MeshPhotoTexturer.Camera {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(position, 1)
        return MeshPhotoTexturer.Camera(
            view: transform.inverse,
            position: position,
            width: 1920,
            height: 1440,
            fx: 1337,
            fy: 1337,
            cx: 960,
            cy: 720,
            depth: depth,
            depthWidth: depth == nil ? 0 : 2,
            depthHeight: depth == nil ? 0 : 2
        )
    }

    func testPointInFrontProjectsToTheImageCentre() throws {
        let pixel = try XCTUnwrap(MeshPhotoTexturer.project(SIMD3(0, 0, -2), camera()))
        XCTAssertEqual(pixel.x, 960, accuracy: 0.01)
        XCTAssertEqual(pixel.y, 720, accuracy: 0.01)
    }

    func testPointBehindOrTooFarIsNotProjected() {
        XCTAssertNil(MeshPhotoTexturer.project(SIMD3(0, 0, 2), camera()))
        XCTAssertNil(MeshPhotoTexturer.project(SIMD3(0, 0, -7), camera()))
    }

    func testCloserCameraScoresBetter() throws {
        let a = SIMD3<Float>(-0.05, -0.05, -2)
        let b = SIMD3<Float>(0.05, -0.05, -2)
        let c = SIMD3<Float>(0, 0.05, -2)
        let far = try XCTUnwrap(MeshPhotoTexturer.score(a, b, c, camera()))
        let near = try XCTUnwrap(MeshPhotoTexturer.score(a, b, c, camera(at: SIMD3(0, 0, -1))))
        XCTAssertLessThan(near, far)
    }

    func testTriangleSeenEdgeOnIsSkipped() {
        let a = SIMD3<Float>(0, -0.05, -2)
        let b = SIMD3<Float>(0, 0.05, -2)
        let c = SIMD3<Float>(0, 0, -2.1)
        XCTAssertNil(MeshPhotoTexturer.score(a, b, c, camera()))
    }

    func testTriangleHiddenBehindSomethingCloserIsSkipped() {
        let a = SIMD3<Float>(-0.05, -0.05, -2)
        let b = SIMD3<Float>(0.05, -0.05, -2)
        let c = SIMD3<Float>(0, 0.05, -2)
        XCTAssertNil(MeshPhotoTexturer.score(a, b, c, camera(depth: [800, 800, 800, 800])))
        XCTAssertNotNil(MeshPhotoTexturer.score(a, b, c, camera(depth: [2000, 2000, 2000, 2000])))
    }

    func testKeepsThePhotosThatCoverTheMostNewTriangles() {
        let visible: [UInt64] = [0b0000_1111, 0b0000_0111, 0b1111_0000, 0b0000_0000]
        XCTAssertEqual(MeshPhotoTexturer.coverCameras(visible: visible, cameras: 4, words: 1, limit: 3), [0, 2])
        XCTAssertEqual(MeshPhotoTexturer.coverCameras(visible: visible, cameras: 4, words: 1, limit: 1), [0])
        XCTAssertEqual(MeshPhotoTexturer.coverCameras(visible: [0, 0], cameras: 2, words: 1, limit: 3), [])
    }

    func testGainsEvenOutABrighterPhoto() {
        let gains = MeshPhotoTexturer.levelGains(pairs: [(0, 1, Float(log(1.5)))], count: 2)
        XCTAssertEqual(gains[1] / gains[0], 1 / 1.5, accuracy: 0.01)
        XCTAssertEqual(gains[0] * gains[1], 1, accuracy: 0.01)
        XCTAssertEqual(MeshPhotoTexturer.levelGains(pairs: [], count: 2), [1, 1])
        let withIsolated = MeshPhotoTexturer.levelGains(pairs: [(0, 1, Float(log(1.5)))], count: 3)
        XCTAssertEqual(withIsolated[2], 1, accuracy: 0.0001)
        XCTAssertEqual(withIsolated[0] * withIsolated[1], 1, accuracy: 0.01)
        let capped = MeshPhotoTexturer.levelGains(pairs: [(0, 1, Float(log(10.0)))], count: 2)
        XCTAssertEqual(capped[0], MeshPhotoTexturer.maxGain, accuracy: 0.01)
    }
}

final class LidarStorageBudgetTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(LidarStorageBudget.level(freeMB: 5000), .ok)
        XCTAssertEqual(LidarStorageBudget.level(freeMB: 1500), .low)
        XCTAssertEqual(LidarStorageBudget.level(freeMB: 900), .full)
    }

    func testMinutesAndAreaLeftMatchMarksRun() {
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 1024 + 570), 10)
        XCTAssertEqual(LidarStorageBudget.squareMetresLeft(freeMB: 1024 + 610), 100)
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 500), 0)
    }

    func testMinutesLeftUsesTheRateMeasuredInThisRun() {
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 1024 + 300, mbPerMinute: 30), 10)
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 1024 + 570, mbPerMinute: nil), 10)
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 1024 + 570, mbPerMinute: 0), 10)
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 1024 + 570, mbPerMinute: .infinity), 10)
        XCTAssertTrue(LidarStorageBudget.lowNote(freeMB: 1024 + 300, mbPerMinute: 30).contains("10"))
    }

    func testProgressOnlyMovesForwardAndStaysInRange() {
        let monitor = MeshPhotoTexturer.Monitor()
        monitor.report(0.4)
        monitor.report(0.2)
        XCTAssertEqual(monitor.fraction, 0.4, accuracy: 1e-9)
        monitor.beginStage()
        monitor.tick(of: 2, from: 0.4, to: 0.6)
        XCTAssertEqual(monitor.fraction, 0.5, accuracy: 1e-9)
        monitor.report(3)
        XCTAssertEqual(monitor.fraction, 1, accuracy: 1e-9)
        monitor.endStage("visibility")
        XCTAssertEqual(monitor.stages.map(\.name), ["visibility"])
        XCTAssertGreaterThanOrEqual(monitor.stages[0].seconds, 0)
    }

    func testCancelledPhotoTextureStopsBeforeLoadingPhotos() throws {
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("vuuro-cancel-\(UUID().uuidString).jpg")
        try Data([0]).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        let frame = MeshFrame(index: 0, cameraTransform: matrix_identity_float4x4, verticalFieldOfView: 60, imageURL: photo, imageWidth: 1920, imageHeight: 1440, fx: 1337, fy: 1337, cx: 960, cy: 720, depthURL: nil, confidenceURL: nil, depthWidth: 0, depthHeight: 0)
        var vertices: [Float] = [-0.05, -0.05, -2, 0.05, -0.05, -2, 0, 0.05, -2]
        var faces: [UInt32] = [0, 1, 2]
        let part = MeshPhotoTexturer.PartInput(
            vertices: vertices.withUnsafeMutableBytes { Data($0) },
            vertexCount: 3,
            faces: faces.withUnsafeMutableBytes { Data($0) },
            faceCount: 1,
            classes: nil,
            transform: matrix_identity_float4x4
        )
        let monitor = MeshPhotoTexturer.Monitor()
        monitor.cancel()
        switch MeshPhotoTexturer.texture(parts: [part], frames: [frame], monitor: monitor) {
        case .success:
            XCTFail("A cancelled photo texture must not finish")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(monitor.fraction, 0, accuracy: 1e-9)
    }

    func testPhotoBuildTimeIsKeptPerCaptureAndReadsPlainly() throws {
        let suite = "vuuro-photo-build-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = URL(fileURLWithPath: "/tmp/20261112-154844-C964E7F5")
        XCTAssertNil(try MeshPhotoBuildLog.load(capture: capture, defaults: defaults).get())
        let entry = MeshPhotoBuildLog.Entry(
            finishedAt: Date(timeIntervalSince1970: 0),
            seconds: 192,
            outcome: .done,
            percentDone: 100,
            debugBuild: true,
            triangles: 830283,
            photosUsed: 40,
            stages: [MeshPhotoBuildLog.Stage(name: "visibility", seconds: 150.4), MeshPhotoBuildLog.Stage(name: "3D scene", seconds: 4)]
        )
        try MeshPhotoBuildLog.save(entry, capture: capture, defaults: defaults).get()
        XCTAssertEqual(try MeshPhotoBuildLog.load(capture: capture, defaults: defaults).get(), entry)
        XCTAssertNil(try MeshPhotoBuildLog.load(capture: URL(fileURLWithPath: "/tmp/other"), defaults: defaults).get())
        XCTAssertEqual(MeshPhotoBuildLog.text(entry), "3 min 12 s, Debug build, 40 photos, 830283 triangles")
        XCTAssertEqual(MeshPhotoBuildLog.stagesText(entry), "visibility 2 min 30 s, 3D scene 4 s")
        let cancelled = MeshPhotoBuildLog.Entry(finishedAt: Date(), seconds: 20, outcome: .cancelled, percentDone: 37, debugBuild: false, triangles: 1, photosUsed: 0, stages: [])
        XCTAssertEqual(MeshPhotoBuildLog.text(cancelled), "20 s, Release build, cancelled at 37%")
    }

    func testCorruptPhotoBuildTimeIsAnErrorNotNothing() throws {
        let suite = "vuuro-photo-build-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = URL(fileURLWithPath: "/tmp/broken")
        defaults.set(Data("nope".utf8), forKey: MeshPhotoBuildLog.key(capture))
        XCTAssertThrowsError(try MeshPhotoBuildLog.load(capture: capture, defaults: defaults).get())
        MeshPhotoBuildLog.forget(capture: capture, defaults: defaults)
        XCTAssertNil(try MeshPhotoBuildLog.load(capture: capture, defaults: defaults).get())
    }

    func testMeasuredStorageRateWaitsForAMinuteOfRecording() throws {
        XCTAssertNil(LidarStorageBudget.measuredRate(bytes: 4 * 1_048_576, durationS: 12))
        XCTAssertNil(LidarStorageBudget.measuredRate(bytes: 50 * 1_048_576, durationS: 59))
        let rate = try XCTUnwrap(LidarStorageBudget.measuredRate(bytes: 57 * 1_048_576, durationS: 60))
        XCTAssertEqual(rate, 57, accuracy: 0.01)
    }

    func testMBPerMinute() throws {
        let rate = try XCTUnwrap(LidarStorageBudget.mbPerMinute(bytes: 42 * 1_048_576, durationS: 60))
        XCTAssertEqual(rate, 42, accuracy: 0.01)
        XCTAssertNil(LidarStorageBudget.mbPerMinute(bytes: 1_048_576, durationS: 5))
        XCTAssertNil(LidarStorageBudget.mbPerMinute(bytes: 0, durationS: 60))
    }

    func testOlderStatsWithoutDiskStillDecode() throws {
        let json = """
        {"frames":0,"depth_frames":0,"mesh_anchors":0,"mesh_vertices":0,"mesh_faces":0,"frame_bytes":0,"mesh_bytes":0,"scene_depth_seen":false,"mesh_seen":false,"classification_seen":false,"worst_thermal_state":0,"lowest_free_memory_mb":0,"write_failures":0,"skipped_busy_frames":0}
        """
        let stats = try JSONDecoder().decode(LidarCaptureStats.self, from: Data(json.utf8))
        XCTAssertNil(stats.lowestFreeDiskMB)
    }
}
