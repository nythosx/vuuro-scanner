import XCTest
import UIKit
import simd
@testable import VuuroScan

@MainActor
final class StandCaptureMathTests: XCTestCase {

    private func intrinsics(
        orientation: UIImage.Orientation,
        cropWidth: Int = 1920,
        cropHeight: Int = 1440,
        jpegWidth: Int,
        jpegHeight: Int
    ) -> [Double] {
        RoomPhotoCaptureCoordinator.jpegIntrinsics(
            fx: 1500,
            fy: 1510,
            cx: 1000,
            cy: 700,
            rawWidth: 1920,
            rawHeight: 1440,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            jpegWidth: jpegWidth,
            jpegHeight: jpegHeight,
            orientation: orientation
        ) ?? []
    }

    private func assertNear(_ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 0.001, file: file, line: line)
        }
    }

    func testLandscapeUpKeepsTheSensorIntrinsics() {
        assertNear(intrinsics(orientation: .up, jpegWidth: 1920, jpegHeight: 1440), [1500, 1510, 1000, 700])
    }

    func testLandscapeDownMirrorsThePrincipalPoint() {
        assertNear(intrinsics(orientation: .down, jpegWidth: 1920, jpegHeight: 1440), [1500, 1510, 920, 740])
    }

    func testPortraitRightRotatesClockwise() {
        assertNear(intrinsics(orientation: .right, jpegWidth: 1440, jpegHeight: 1920), [1510, 1500, 740, 1000])
    }

    func testPortraitLeftRotatesCounterClockwise() {
        assertNear(intrinsics(orientation: .left, jpegWidth: 1440, jpegHeight: 1920), [1510, 1500, 700, 920])
    }

    func testZoomCropAndDownscaleAreApplied() {
        assertNear(
            intrinsics(orientation: .up, cropWidth: 960, cropHeight: 720, jpegWidth: 480, jpegHeight: 360),
            [750, 755, 260, 170]
        )
    }

    func testDepthIntrinsicsScaleToTheDepthMap() {
        let depth = RoomPhotoCaptureCoordinator.depthIntrinsics(
            fx: 1500,
            fy: 1510,
            cx: 1000,
            cy: 700,
            rawWidth: 1920,
            rawHeight: 1440,
            depthWidth: 256,
            depthHeight: 192
        ) ?? []
        assertNear(depth, [200, 201.3333, 133.3333, 93.3333])
    }

    func testStandSectorWrapsAroundTheStartHeading() {
        XCTAssertEqual(RoomPhotoCaptureCoordinator.standSector(yawDeg: 10, startYawDeg: 350), 0)
        XCTAssertEqual(RoomPhotoCaptureCoordinator.standSector(yawDeg: 45, startYawDeg: 0), 1)
        XCTAssertEqual(RoomPhotoCaptureCoordinator.standSector(yawDeg: 359, startYawDeg: 0), 11)
        XCTAssertEqual(RoomPhotoCaptureCoordinator.standSector(yawDeg: 5, startYawDeg: 10), 11)
    }

    func testStandCellsCoverThreeRowsAndBothPoles() {
        typealias C = RoomPhotoCaptureCoordinator
        XCTAssertEqual(C.standSectorTotal, 26)
        XCTAssertEqual(C.standCell(yawDeg: 45, startYawDeg: 0, pitchDeg: 5), 1)
        XCTAssertEqual(C.standCell(yawDeg: 45, startYawDeg: 0, pitchDeg: 45), 12)
        XCTAssertEqual(C.standCell(yawDeg: 130, startYawDeg: 0, pitchDeg: 45), 14)
        XCTAssertEqual(C.standCell(yawDeg: 130, startYawDeg: 0, pitchDeg: -45), 20)
        XCTAssertEqual(C.standCell(yawDeg: 10, startYawDeg: 0, pitchDeg: 80), 24)
        XCTAssertEqual(C.standCell(yawDeg: 10, startYawDeg: 0, pitchDeg: -80), 25)
        XCTAssertNil(C.standCell(yawDeg: 10, startYawDeg: 0, pitchDeg: 22))
        XCTAssertNil(C.standCell(yawDeg: 10, startYawDeg: 0, pitchDeg: -66))
        let all = C.StandRow.allCases.flatMap { Array(C.standCells($0)) }
        XCTAssertEqual(all, Array(0..<26))
    }

    func testStandInstructionWalksThroughTheRowsInOrder() {
        typealias C = RoomPhotoCaptureCoordinator
        XCTAssertEqual(C.standInstruction(captured: [], pitchDeg: 0), .turnSlowly)
        XCTAssertEqual(C.standInstruction(captured: [], pitchDeg: 30), .levelPhone)
        var captured = Set(C.standCells(.horizon))
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 0), .tiltUp)
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 45), .turnTiltedUp)
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 70), .tiltDownLittle)
        captured.formUnion(C.standCells(.up))
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 45), .tiltDown)
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: -45), .turnTiltedDown)
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: -70), .tiltUpLittle)
        captured.formUnion(C.standCells(.down))
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 0), .pointUp)
        captured.formUnion(C.standCells(.zenith))
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 0), .pointDown)
        captured.formUnion(C.standCells(.nadir))
        XCTAssertEqual(C.standInstruction(captured: captured, pitchDeg: 0), .done)
    }

    func testDarkWarningUsesHysteresis() {
        typealias C = RoomPhotoCaptureCoordinator
        XCTAssertTrue(C.isDark(ambientIntensity: 150, wasDark: false))
        XCTAssertFalse(C.isDark(ambientIntensity: 250, wasDark: false))
        XCTAssertTrue(C.isDark(ambientIntensity: 250, wasDark: true))
        XCTAssertFalse(C.isDark(ambientIntensity: 400, wasDark: true))
    }

    func testNextStandSuggestionStaysAwayFromWallsAndExistingSpots() {
        typealias C = RoomPhotoCaptureCoordinator
        let room = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 4), CGPoint(x: 0, y: 4)]
        let first = C.suggestNextStand(outline: room, stands: [])
        XCTAssertNotNil(first)
        if let first {
            XCTAssertGreaterThanOrEqual(C.distanceToOutline(first, outline: room), 1.5)
        }
        let second = C.suggestNextStand(outline: room, stands: [CGPoint(x: 2, y: 2)])
        XCTAssertNotNil(second)
        if let second {
            XCTAssertGreaterThan(second.x, 5)
            XCTAssertGreaterThanOrEqual(C.distanceToOutline(second, outline: room), C.standMinWallDistanceM)
        }
        XCTAssertNil(C.suggestNextStand(outline: room, stands: [CGPoint(x: 2, y: 2), CGPoint(x: 6, y: 2)]))
        XCTAssertEqual(C.distanceToOutline(CGPoint(x: 0.3, y: 2), outline: room), 0.3, accuracy: 1e-9)
        XCTAssertFalse(C.isInside(CGPoint(x: 9, y: 2), outline: room))
    }

    func testStandStepTooLargeCatchesFastTurns() {
        typealias C = RoomPhotoCaptureCoordinator
        XCTAssertFalse(C.standStepTooLarge(from: (yawDeg: 10, pitchDeg: 0), toYawDeg: 13, toPitchDeg: 1))
        XCTAssertTrue(C.standStepTooLarge(from: (yawDeg: 10, pitchDeg: 0), toYawDeg: 20, toPitchDeg: 0))
        XCTAssertTrue(C.standStepTooLarge(from: (yawDeg: 358, pitchDeg: 0), toYawDeg: 8, toPitchDeg: 0))
        XCTAssertFalse(C.standStepTooLarge(from: (yawDeg: 0, pitchDeg: 80), toYawDeg: 90, toPitchDeg: 81))
        XCTAssertTrue(C.standStepTooLarge(from: (yawDeg: 0, pitchDeg: 0), toYawDeg: 0, toPitchDeg: 9))
    }

    func testLocalCameraTransformMakesHeightRelativeToFloor() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = simd_float4(3.5, 0.9, -2.0, 1)
        let local = RoomPhotoCaptureCoordinator.localCameraTransform(transform, offsetX: 1.5, offsetY: -0.55, offsetZ: -4.0)
        XCTAssertEqual(local.count, 16)
        XCTAssertEqual(local[12], 2.0, accuracy: 1e-5)
        XCTAssertEqual(local[13], 1.45, accuracy: 1e-5)
        XCTAssertEqual(local[14], 2.0, accuracy: 1e-5)
        XCTAssertEqual(local[0], 1.0, accuracy: 1e-9)
    }
}
