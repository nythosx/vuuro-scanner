import XCTest
import simd
@testable import VuuroScan

final class MeshSceneFramingTests: XCTestCase {
    func testAFewFarAwayPiecesDoNotPullTheViewOffTheRoom() throws {
        var boxes: [MeshSceneBuilder.WeightedBox] = []
        for index in 0..<20 {
            let x = Float(index % 5)
            let z = Float(index / 5)
            boxes.append(.init(lower: SIMD3(x, 0, z), upper: SIMD3(x + 1, 2.5, z + 1), weight: 5000))
        }
        boxes.append(.init(lower: SIMD3(30, 5, 30), upper: SIMD3(31, 6, 31), weight: 200))
        let (lower, upper) = try XCTUnwrap(MeshSceneBuilder.trimmedBounds(boxes))
        XCTAssertEqual(lower.x, 0, accuracy: 0.001)
        XCTAssertEqual(upper.x, 5, accuracy: 0.001)
        XCTAssertEqual(upper.z, 4, accuracy: 0.001)
        XCTAssertEqual(upper.y, 2.5, accuracy: 0.001)
    }

    func testLightWallsStayInTheViewWhenTheFloorHasMostTriangles() throws {
        let boxes = [
            MeshSceneBuilder.WeightedBox(lower: SIMD3(0, 0, 0), upper: SIMD3(4, 0, 3), weight: 800),
            MeshSceneBuilder.WeightedBox(lower: SIMD3(0, 0, 0), upper: SIMD3(4, 2.5, 3), weight: 6),
            MeshSceneBuilder.WeightedBox(lower: SIMD3(28, 6, 28), upper: SIMD3(28.5, 6.5, 28), weight: 1)
        ]
        let (lower, upper) = try XCTUnwrap(MeshSceneBuilder.trimmedBounds(boxes))
        XCTAssertEqual(lower, SIMD3(0, 0, 0))
        XCTAssertEqual(upper, SIMD3(4, 2.5, 3))
    }

    func testOneRoomKeepsItsFullBounds() throws {
        let boxes = [MeshSceneBuilder.WeightedBox(lower: SIMD3(-2, 0, -1), upper: SIMD3(3, 2.4, 4), weight: 100)]
        let (lower, upper) = try XCTUnwrap(MeshSceneBuilder.trimmedBounds(boxes))
        XCTAssertEqual(lower, SIMD3(-2, 0, -1))
        XCTAssertEqual(upper, SIMD3(3, 2.4, 4))
    }

    func testNoPiecesGiveNoBounds() {
        XCTAssertNil(MeshSceneBuilder.trimmedBounds([]))
        XCTAssertNil(MeshSceneBuilder.trimmedBounds([.init(lower: .zero, upper: .one, weight: 0)]))
    }
}
