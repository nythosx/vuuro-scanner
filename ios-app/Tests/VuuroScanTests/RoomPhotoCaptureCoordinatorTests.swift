import ARKit
import XCTest
@testable import VuuroScan

@MainActor
final class RoomPhotoCaptureCoordinatorTests: XCTestCase {

    func testHeadingDegUsesCameraYawDeltaFromStart() {
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: 45.0,
            cameraYawAtStartDeg: 0.0,
            cameraYawAtShutterDeg: 10.0
        )
        XCTAssertEqual(heading, 55.0, accuracy: 1e-9)
    }

    func testHeadingDegDiffersWhenSeededFromFloorYawInsteadOfCameraYaw() {
        let correct = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: 45.0,
            cameraYawAtStartDeg: 0.0,
            cameraYawAtShutterDeg: 10.0
        )
        let floorYawSeeded = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: 45.0,
            cameraYawAtStartDeg: 90.0,
            cameraYawAtShutterDeg: 10.0
        )
        XCTAssertEqual(correct, 55.0, accuracy: 1e-9)
        XCTAssertEqual(floorYawSeeded, 325.0, accuracy: 1e-9)
        XCTAssertNotEqual(correct, floorYawSeeded)
    }

    func testHeadingDegWrapsAroundZero() {
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: 350.0,
            cameraYawAtStartDeg: 350.0,
            cameraYawAtShutterDeg: 10.0
        )
        XCTAssertEqual(heading, 10.0, accuracy: 1e-9)
    }

    func testHeadingDegWithNilCompassFallsBackToAbsoluteCameraYaw() {
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: nil,
            cameraYawAtStartDeg: 90.0,
            cameraYawAtShutterDeg: 100.0
        )
        XCTAssertEqual(heading, 100.0, accuracy: 1e-9)
    }

    func testHeadingDegWithNilCameraYawUsesCompassWithoutDelta() {
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: 45.0,
            cameraYawAtStartDeg: nil,
            cameraYawAtShutterDeg: 10.0
        )
        XCTAssertEqual(heading, 45.0, accuracy: 1e-9)
    }

    func testHeadingDegNormalizesNegativeCompass() {
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: -10.0,
            cameraYawAtStartDeg: 0.0,
            cameraYawAtShutterDeg: 0.0
        )
        XCTAssertEqual(heading, 350.0, accuracy: 1e-9)
    }

    func testHeadingDegResultAlwaysInZeroTo360() {
        for base in stride(from: -720.0, through: 720.0, by: 45.0) {
            for delta in stride(from: -720.0, through: 720.0, by: 45.0) {
                let heading = RoomPhotoCaptureCoordinator.headingDeg(
                    compassHeadingDeg: base,
                    cameraYawAtStartDeg: 0.0,
                    cameraYawAtShutterDeg: delta
                )
                XCTAssertGreaterThanOrEqual(heading, 0.0)
                XCTAssertLessThan(heading, 360.0)
            }
        }
    }

    private func cameraTransform(yawDeg: Float, x: Float = 0, z: Float = 0) -> simd_float4x4 {
        let r = yawDeg * .pi / 180
        return simd_float4x4(
            SIMD4<Float>(cos(r), 0, -sin(r), 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sin(r), 0, cos(r), 0),
            SIMD4<Float>(x, 0, z, 1)
        )
    }

    private func forwardXZ(_ transform: simd_float4x4) -> SIMD2<Double> {
        SIMD2<Double>(Double(-transform.columns.2.x), Double(-transform.columns.2.z))
    }

    private func coveredDirection(compass: Double?, startYaw: Float, shutterYaw: Float) -> (direction: SIMD2<Double>, expected: SIMD2<Double>) {
        let start = cameraTransform(yawDeg: startYaw)
        let shutter = cameraTransform(yawDeg: shutterYaw)
        let yawStart = RoomPhotoCaptureCoordinator.yawDeg(start)
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: compass,
            cameraYawAtStartDeg: yawStart,
            cameraYawAtShutterDeg: RoomPhotoCaptureCoordinator.yawDeg(shutter)
        )
        let coverage = RoomPhotoCoverage(
            outline: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 3), CGPoint(x: 0, y: 3)],
            roomHeadingDeg: RoomPhotoCaptureCoordinator.coverageReferenceDeg(
                compassHeadingDeg: compass,
                cameraYawAtStartDeg: yawStart
            )
        )
        return (coverage.directionVector(cameraHeadingDeg: heading), forwardXZ(shutter))
    }

    func testCoverageDirectionMatchesTheCameraForwardForAnyStartAndCompass() {
        for compass in [nil, 0.0, 37.0, 200.0, 359.0] as [Double?] {
            for startYaw in stride(from: Float(0), to: 360, by: 23) {
                for shutterYaw in stride(from: Float(0), to: 360, by: 29) {
                    let result = coveredDirection(compass: compass, startYaw: startYaw, shutterYaw: shutterYaw)
                    XCTAssertEqual(result.direction.x, result.expected.x, accuracy: 1e-4, "compass \(String(describing: compass)) start \(startYaw) shutter \(shutterYaw)")
                    XCTAssertEqual(result.direction.y, result.expected.y, accuracy: 1e-4, "compass \(String(describing: compass)) start \(startYaw) shutter \(shutterYaw)")
                }
            }
        }
    }

    func testPhotoFacingTheFarWallCoversThatWall() {
        let start = cameraTransform(yawDeg: 0)
        let shutter = cameraTransform(yawDeg: 180, x: 2, z: 1.5)
        let yawStart = RoomPhotoCaptureCoordinator.yawDeg(start)
        var tracker = RoomPhotoCoverageTracker(
            outline: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 3), CGPoint(x: 0, y: 3)],
            roomHeadingDeg: RoomPhotoCaptureCoordinator.coverageReferenceDeg(compassHeadingDeg: 37, cameraYawAtStartDeg: yawStart)
        )
        let heading = RoomPhotoCaptureCoordinator.headingDeg(
            compassHeadingDeg: 37,
            cameraYawAtStartDeg: yawStart,
            cameraYawAtShutterDeg: RoomPhotoCaptureCoordinator.yawDeg(shutter)
        )
        tracker.record(positionM: CGPoint(x: 2, y: 1.5), cameraHeadingDeg: heading)
        XCTAssertEqual(tracker.coverage.coveredWalls, [2], "the camera faces +Z, so the wall at z = 3 must be the one covered")
    }

    func testCameraYawDegReturnsNilWithoutAFrame() {
        let session = ARSession()
        XCTAssertNil(RoomPhotoCaptureCoordinator.cameraYawDeg(from: session))
    }
}
