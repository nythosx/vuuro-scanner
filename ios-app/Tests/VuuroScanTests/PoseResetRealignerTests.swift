import XCTest
import simd
@testable import VuuroScan

final class PoseResetRealignerTests: XCTestCase {
    private func roomPoints(step: Float = 0.04) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for i in 0...Int((4 / step).rounded()) {
            for j in 0...Int((2.48 / step).rounded()) {
                let a = Float(i) * step
                let b = Float(j) * step
                points.append(SIMD3(a, 0, b * 1.6))
                points.append(SIMD3(a, b, 0))
                points.append(SIMD3(0, b, a))
                points.append(SIMD3(a, b, 4))
            }
        }
        return points
    }

    private func moved(_ points: [SIMD3<Float>], by transform: simd_float4x4) -> [SIMD3<Float>] {
        points.map { point in
            let world = transform * SIMD4<Float>(point, 1)
            return SIMD3(world.x, world.y, world.z)
        }
    }

    private func offset(degrees: Float, shift: SIMD3<Float>) -> simd_float4x4 {
        var transform = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
        transform.columns.3 = SIMD4<Float>(shift, 1)
        return transform
    }

    func testRigidFitFindsAKnownTurnAndShift() throws {
        let source = (0..<200).map { index -> SIMD3<Float> in
            let value = Float(index)
            return SIMD3(sin(value) * 2, cos(value * 0.7) * 1.5, Float(index % 13) * 0.2)
        }
        let known = offset(degrees: 7, shift: SIMD3(0.3, -0.1, 0.2))
        let fit = try XCTUnwrap(PoseResetRealigner.rigidFit(source: source, target: moved(source, by: known)))
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(fit[column][row], known[column][row], accuracy: 1e-3)
            }
        }
    }

    func testDepthPointsThatAreSlightlyOffLineUpWithTheMesh() throws {
        let room = roomPoints()
        let grid = PoseResetRealigner.Grid(points: room, cell: PoseResetRealigner.cellM)
        let wrong = offset(degrees: 3, shift: SIMD3(0.12, 0.02, -0.08))
        let sample = stride(from: 0, to: room.count, by: 7).map { room[$0] }
        let source = moved(sample, by: wrong)
        let fit = try XCTUnwrap(PoseResetRealigner.fit(source: source, grid: grid))
        XCTAssertTrue(PoseResetRealigner.accepts(fit), "share \(fit.inlierShare), median \(fit.medianErrorM)")
        let fixed = moved(source, by: fit.transform)
        let error = zip(fixed, sample).map { simd_distance($0, $1) }.max() ?? 1
        XCTAssertLessThan(error, 0.05)
    }

    func testASmallDriftIsCorrectedAndNoDriftOrABigOneIsLeftAlone() throws {
        let room = roomPoints()
        let grid = PoseResetRealigner.Grid(points: roomPoints(step: 0.02), cell: PoseResetRealigner.cellM)
        let sample = stride(from: 0, to: room.count, by: 41).map { room[$0] }
        let drifted = moved(sample, by: offset(degrees: 1, shift: SIMD3(0.03, 0.01, -0.02)))
        let correction = try XCTUnwrap(PoseResetRealigner.driftCorrection(source: drifted, grid: grid))
        let error = zip(moved(drifted, by: correction), sample).map { simd_distance($0, $1) }.max() ?? 1
        XCTAssertLessThan(error, 0.03)
        XCTAssertNil(PoseResetRealigner.driftCorrection(source: sample, grid: grid))
        XCTAssertNil(PoseResetRealigner.driftCorrection(source: moved(sample, by: offset(degrees: 0, shift: SIMD3(0.3, 0, 0.3))), grid: grid))
    }

    func testPointsThatMatchNothingAreNotAccepted() {
        let room = roomPoints()
        let grid = PoseResetRealigner.Grid(points: room, cell: PoseResetRealigner.cellM)
        let far = moved(stride(from: 0, to: room.count, by: 7).map { room[$0] }, by: offset(degrees: 0, shift: SIMD3(20, 0, 20)))
        if let fit = PoseResetRealigner.fit(source: far, grid: grid) {
            XCTAssertFalse(PoseResetRealigner.accepts(fit))
        }
    }

    func testSegmentsSplitAtEveryResetInARoom() {
        let resets = [
            LidarPoseReset(room: 1, atS: 10, roomFirstKeyframe: 0, firstKeyframeAfter: 40),
            LidarPoseReset(room: 1, atS: 14, roomFirstKeyframe: 0, firstKeyframeAfter: 55),
            LidarPoseReset(room: 2, atS: 90, roomFirstKeyframe: 100, firstKeyframeAfter: 130)
        ]
        XCTAssertEqual(PoseResetRealigner.segments(resets), [0..<40, 40..<55, 100..<130])
    }

    func testWithoutResetsNothingIsDropped() {
        let frames = (0..<3).map { index in
            MeshFrame(index: index, cameraTransform: matrix_identity_float4x4, verticalFieldOfView: 60, imageURL: nil, imageWidth: 1920, imageHeight: 1440, fx: 1400, fy: 1400, cx: 960, cy: 720, depthURL: nil, confidenceURL: nil, depthWidth: 0, depthHeight: 0)
        }
        let outcome = PoseResetRealigner.realign(frames: frames, resets: [], meshPoints: roomPoints())
        XCTAssertEqual(outcome.frames.count, 3)
        XCTAssertEqual(outcome.dropped, 0)
        XCTAssertEqual(outcome.realigned, 0)
    }

    func testDepthPointsLandWhereTheCameraLooks() {
        let frame = MeshFrame(index: 0, cameraTransform: matrix_identity_float4x4, verticalFieldOfView: 60, imageURL: nil, imageWidth: 16, imageHeight: 16, fx: 8, fy: 8, cx: 8, cy: 8, depthURL: nil, confidenceURL: nil, depthWidth: 16, depthHeight: 16)
        let depth = [UInt16](repeating: 2000, count: 256)
        let points = PoseResetRealigner.depthPoints(frame, depth: depth)
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertEqual(point.z, -2, accuracy: 1e-4)
        }
    }
}
