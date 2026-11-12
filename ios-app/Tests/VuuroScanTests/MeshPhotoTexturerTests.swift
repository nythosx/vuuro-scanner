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
        let gains = MeshPhotoTexturer.levelGains(pairs: [(0, 1, log(1.5))], count: 2)
        XCTAssertEqual(gains[1] / gains[0], 1 / 1.5, accuracy: 0.01)
        XCTAssertEqual(gains[0] * gains[1], 1, accuracy: 0.01)
        XCTAssertEqual(MeshPhotoTexturer.levelGains(pairs: [], count: 2), [1, 1])
        let withIsolated = MeshPhotoTexturer.levelGains(pairs: [(0, 1, log(1.5))], count: 3)
        XCTAssertEqual(withIsolated[2], 1, accuracy: 0.0001)
        XCTAssertEqual(withIsolated[0] * withIsolated[1], 1, accuracy: 0.01)
        let capped = MeshPhotoTexturer.levelGains(pairs: [(0, 1, log(10))], count: 2)
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
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 1024 + 415), 10)
        XCTAssertEqual(LidarStorageBudget.squareMetresLeft(freeMB: 1024 + 471), 100)
        XCTAssertEqual(LidarStorageBudget.minutesLeft(freeMB: 500), 0)
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
