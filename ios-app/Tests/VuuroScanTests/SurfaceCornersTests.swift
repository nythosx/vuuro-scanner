import simd
import XCTest
@testable import VuuroScan

final class SurfaceCornersTests: XCTestCase {
    private func transform(yawDegrees: Float, translation: simd_float3) -> simd_float4x4 {
        let rotation = simd_float4x4(simd_quatf(angle: yawDegrees * .pi / 180, axis: simd_float3(0, 1, 0)))
        var matrix = rotation
        matrix.columns.3 = simd_float4(translation, 1)
        return matrix
    }

    func testRectangularDoorWithoutCornersGetsFourWorldCorners() {
        let corners = CapturedRoomExporter.worldCorners(
            transform: transform(yawDegrees: 0, translation: simd_float3(2, 1, 3)),
            dimensions: simd_float3(0.9, 2.0, 0),
            polygonCorners: []
        )
        XCTAssertEqual(corners.count, 4)
        let xs = corners.map { $0[0] }
        let zs = corners.map { $0[2] }
        XCTAssertEqual(xs.min() ?? 0, 1.55, accuracy: 0.001)
        XCTAssertEqual(xs.max() ?? 0, 2.45, accuracy: 0.001)
        XCTAssertTrue(zs.allSatisfy { abs($0 - 3) < 0.001 })
    }

    func testTurnedWindowRunsAlongItsWall() {
        let corners = CapturedRoomExporter.worldCorners(
            transform: transform(yawDegrees: 90, translation: simd_float3(5, 1.5, 2)),
            dimensions: simd_float3(1.2, 1.0, 0),
            polygonCorners: []
        )
        let xs = corners.map { $0[0] }
        let zs = corners.map { $0[2] }
        XCTAssertTrue(xs.allSatisfy { abs($0 - 5) < 0.001 })
        XCTAssertEqual((zs.max() ?? 0) - (zs.min() ?? 0), 1.2, accuracy: 0.001)
    }

    func testCornersFromRoomPlanAreKeptWhenPresent() {
        let given = [simd_float3(0, 0, 0), simd_float3(1, 0, 0), simd_float3(1, 1, 0)]
        let corners = CapturedRoomExporter.worldCorners(
            transform: transform(yawDegrees: 0, translation: simd_float3(10, 0, 0)),
            dimensions: simd_float3(5, 5, 0),
            polygonCorners: given
        )
        XCTAssertEqual(corners.count, 3)
        XCTAssertEqual(corners[1][0], 11, accuracy: 0.001)
    }

    func testYawIsReadFromTheTransform() {
        let yaw = CapturedRoomExporter.yawDegrees(transform(yawDegrees: 90, translation: .zero)) ?? -1
        XCTAssertTrue(abs(yaw - 90) < 0.5 || abs(yaw - 270) < 0.5)
    }
}
