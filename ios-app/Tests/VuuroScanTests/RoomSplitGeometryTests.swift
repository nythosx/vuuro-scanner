import CoreGraphics
import XCTest
@testable import VuuroScan

final class RoomSplitGeometryTests: XCTestCase {
    private let rectangle = [CGPoint(x: 0, y: 0), CGPoint(x: 8.5, y: 0), CGPoint(x: 8.5, y: 3.5), CGPoint(x: 0, y: 3.5)]

    private func areas(_ result: Result<[RoomSplitGeometry.Part], RoomSplitGeometry.CutError>) -> [Double] {
        guard case .success(let parts) = result else { return [] }
        return parts.map { ($0.areaM2 * 1000).rounded() / 1000 }.sorted()
    }

    func testStraightCutMatchesTheServer() {
        let result = RoomSplitGeometry.cut(outline: rectangle, openEdges: [], from: CGPoint(x: 6, y: -1), to: CGPoint(x: 6, y: 4.5))
        XCTAssertEqual(areas(result), [8.75, 21.0])
        guard case .success(let parts) = result else { return XCTFail("cut failed") }
        for part in parts {
            XCTAssertEqual(part.openEdges.count, 1)
        }
    }

    func testCutThroughACornerHasNoZeroLengthEdge() {
        let result = RoomSplitGeometry.cut(outline: rectangle, openEdges: [], from: CGPoint(x: -1, y: -1), to: CGPoint(x: 5, y: 5))
        XCTAssertEqual(areas(result), [6.125, 23.625])
    }

    func testLShapeCut() {
        let lShape = [CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 6), CGPoint(x: 3, y: 6), CGPoint(x: 3, y: 3), CGPoint(x: 0, y: 3)]
        XCTAssertEqual(areas(RoomSplitGeometry.cut(outline: lShape, openEdges: [], from: CGPoint(x: 3, y: -1), to: CGPoint(x: 3, y: 7))), [9.0, 36.0])
    }

    func testInvalidLinesAreRejected() {
        XCTAssertEqual(errorOf(RoomSplitGeometry.cut(outline: rectangle, openEdges: [], from: CGPoint(x: 2, y: 1), to: CGPoint(x: 4, y: 1))), .doesNotCross)
        XCTAssertEqual(errorOf(RoomSplitGeometry.cut(outline: rectangle, openEdges: [], from: CGPoint(x: 3, y: 1), to: CGPoint(x: 3, y: 1))), .tooShort)
        let uShape = [CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 6), CGPoint(x: 6, y: 6), CGPoint(x: 6, y: 2), CGPoint(x: 3, y: 2), CGPoint(x: 3, y: 6), CGPoint(x: 0, y: 6)]
        XCTAssertEqual(errorOf(RoomSplitGeometry.cut(outline: uShape, openEdges: [], from: CGPoint(x: -1, y: 4), to: CGPoint(x: 10, y: 4))), .crossesTooOften)
        if case .partTooSmall = errorOf(RoomSplitGeometry.cut(outline: rectangle, openEdges: [], from: CGPoint(x: 8.4, y: -1), to: CGPoint(x: 8.4, y: 4.5))) {
        } else {
            XCTFail("a sliver should be rejected")
        }
    }

    func testInteriorPointIsInsideAnLShape() {
        let lShape = [CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0), CGPoint(x: 6, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 6), CGPoint(x: 0, y: 6)]
        XCTAssertTrue(RoomSplitGeometry.contains(lShape, RoomSplitGeometry.interiorPoint(lShape)))
    }

    func testSnapLocksToTheRoomAxes() {
        let snapped = RoomSplitGeometry.snapped(CGPoint(x: 6.2, y: 4), around: CGPoint(x: 6, y: -1), dominantAngle: 0)
        XCTAssertEqual(Double(snapped.x), 6, accuracy: 1e-9)
        let free = RoomSplitGeometry.snapped(CGPoint(x: 8, y: 4), around: CGPoint(x: 6, y: -1), dominantAngle: 0)
        XCTAssertEqual(Double(free.x), 8, accuracy: 1e-9)
    }

    func testInitialLineCrossesTheRoom() {
        let (a, b) = RoomSplitGeometry.initialLine(rectangle)
        XCTAssertEqual(areas(RoomSplitGeometry.cut(outline: rectangle, openEdges: [], from: a, to: b)).count, 2)
    }

    private func errorOf(_ result: Result<[RoomSplitGeometry.Part], RoomSplitGeometry.CutError>) -> RoomSplitGeometry.CutError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
