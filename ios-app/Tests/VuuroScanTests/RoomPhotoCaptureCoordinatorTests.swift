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

    func testCameraYawDegReturnsNilWithoutAFrame() {
        let session = ARSession()
        XCTAssertNil(RoomPhotoCaptureCoordinator.cameraYawDeg(from: session))
    }
}
