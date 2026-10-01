import CoreGraphics
import XCTest
@testable import VuuroScan

final class GroupPlacementMathTests: XCTestCase {
    func testRotate90AroundOrigin() {
        let p = CGPoint(x: 4, y: 1)
        let rotated = GroupPlacementMath.rotate(point: p, around: .zero, byDegrees: 90)
        XCTAssertEqual(Double(rotated.x), -1.0, accuracy: 0.001)
        XCTAssertEqual(Double(rotated.y), 4.0, accuracy: 0.001)
    }

    func testRotateZeroIsIdentity() {
        let p = CGPoint(x: 3, y: 2)
        let rotated = GroupPlacementMath.rotate(point: p, around: CGPoint(x: 1, y: 1), byDegrees: 0)
        XCTAssertEqual(Double(rotated.x), 3.0, accuracy: 0.001)
        XCTAssertEqual(Double(rotated.y), 2.0, accuracy: 0.001)
    }

    func testCentroid() {
        let c = GroupPlacementMath.centroid(of: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 4, y: 0),
            CGPoint(x: 4, y: 3),
            CGPoint(x: 0, y: 3),
        ])
        XCTAssertEqual(Double(c.x), 2.0, accuracy: 0.001)
        XCTAssertEqual(Double(c.y), 1.5, accuracy: 0.001)
    }
    func testToServerTransformMatchesPHP() {
        let pivot = CGPoint(x: 10, y: 20)
        let result = GroupPlacementMath.toServerTransform(
            pivot: pivot,
            rotationDegrees: 90.0,
            translationM: CGPoint(x: 1.5, y: -2.5)
        )
        XCTAssertEqual(result.rotationDeg, 90.0, accuracy: 1e-9)
        XCTAssertEqual(result.translationM.count, 2)
        XCTAssertEqual(result.translationM[0], 31.5, accuracy: 1e-9)
        XCTAssertEqual(result.translationM[1], 7.5, accuracy: 1e-9)
    }

    func testServerTransformAppliedToPivotYieldsAppResult() {
        let pivot = CGPoint(x: 10, y: 20)
        let appTranslation = CGPoint(x: 1.5, y: -2.5)
        let server = GroupPlacementMath.toServerTransform(
            pivot: pivot,
            rotationDegrees: 90.0,
            translationM: appTranslation
        )
        let theta = 90.0 * .pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        let px = Double(pivot.x)
        let py = Double(pivot.y)
        let serverX = px * cosT - py * sinT + server.translationM[0]
        let serverY = px * sinT + py * cosT + server.translationM[1]
        let appX = Double(pivot.x) + Double(appTranslation.x)
        let appY = Double(pivot.y) + Double(appTranslation.y)
        XCTAssertEqual(serverX, appX, accuracy: 1e-9)
        XCTAssertEqual(serverY, appY, accuracy: 1e-9)
    }
}
