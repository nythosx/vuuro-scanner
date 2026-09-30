import XCTest
@testable import VuuroScan

final class FakeCaptureTests: XCTestCase {
    private func json(_ export: RoomPlanCaptureExport) throws -> [String: Any] {
        let data = try JSONEncoder().encode(export)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFakeLidarRoomHasAClosedFloorAndWalls() throws {
        for _ in 0..<20 {
            let body = try json(FakeCaptureGenerator.random())
            let floors = try XCTUnwrap(body["floors"] as? [[String: Any]])
            XCTAssertEqual(floors.count, 1)
            let corners = try XCTUnwrap(floors[0]["polygonCorners"] as? [[Double]])
            XCTAssertTrue([4, 6].contains(corners.count))
            let walls = try XCTUnwrap(body["walls"] as? [[String: Any]])
            XCTAssertEqual(walls.count, corners.count)
            for corner in corners {
                XCTAssertEqual(corner.count, 3)
                XCTAssertTrue(corner.allSatisfy { $0.isFinite && $0 >= 0 })
            }
        }
    }

    func testFakeUnitRoomsShareOneLayout() throws {
        for count in 2...8 {
            let exports = FakeCaptureGenerator.unit(roomCount: count)
            XCTAssertEqual(exports.count, count)
            XCTAssertTrue(exports.allSatisfy { $0.structureOriginM?.count == 2 && $0.hasUsableFloorOutline })
        }
    }

    func testFakeMultiRoomCapturesHaveDistinctSurfaces() throws {
        let exports = FakeCaptureGenerator.unit(roomCount: 5)
        var identifiers = Set<String>()
        for export in exports {
            let body = try json(export)
            let floors = try XCTUnwrap(body["floors"] as? [[String: Any]])
            let walls = try XCTUnwrap(body["walls"] as? [[String: Any]])
            for surface in floors + walls {
                let identifier = try XCTUnwrap(surface["identifier"] as? String)
                XCTAssertTrue(identifiers.insert(identifier).inserted, "duplicate identifier \(identifier)")
            }
        }
    }
}
