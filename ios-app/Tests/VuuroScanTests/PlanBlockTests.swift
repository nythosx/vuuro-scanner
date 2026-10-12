import XCTest
@testable import VuuroScan

final class PlanBlockTests: XCTestCase {
    private func rooms(_ specs: [(floor: String?, group: String?, joined: String?)]) throws -> [FloorPlan.Room] {
        let items = specs.enumerated().map { index, spec -> String in
            let floor = spec.floor.map { "\"\($0)\"" } ?? "null"
            let group = spec.group.map { "\"\($0)\"" } ?? "null"
            let joined = spec.joined.map { "\"\($0)\"" } ?? "null"
            return """
            {
              "room_id": "r\(index)", "label": "Room \(index)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
              "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
              "confidence": "high", "outline_m": [[0,0],[4,0],[4,3],[0,3]],
              "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
              "openings": [], "objects": [], "structure_origin_m": [0, 0], "room_type": null,
              "floor": \(floor), "capture_group_id": \(group), "joined_to_group_id": \(joined)
            }
            """
        }
        let json = "[" + items.joined(separator: ",") + "]"
        return try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
    }

    func testOneWholeUnitScanIsOneBlock() throws {
        let blocks = PlanBlock.blocks(for: try rooms([(nil, "A", nil), (nil, "A", nil)]))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].roomCount, 2)
    }

    func testTwoScansOnTheSameFloorAreNumbered() throws {
        let blocks = PlanBlock.blocks(for: try rooms([(nil, "A", nil), (nil, "A", nil), (nil, "B", nil)]))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.group), ["A", "B"])
        XCTAssertTrue(blocks[0].title.hasSuffix("1"))
        XCTAssertTrue(blocks[1].title.hasSuffix("2"))
        XCTAssertEqual(blocks.map(\.roomCount), [2, 1])
    }

    func testJoinedScanFoldsIntoItsTarget() throws {
        let blocks = PlanBlock.blocks(for: try rooms([(nil, "A", nil), (nil, "B", "A")]))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].roomCount, 2)
    }

    func testEachFloorIsItsOwnBlockWithItsName() throws {
        let blocks = PlanBlock.blocks(for: try rooms([("Attic", "A", nil), ("Ground", "A", nil)]))
        XCTAssertEqual(blocks.map(\.title), ["Attic", "Ground"])
        XCTAssertEqual(blocks.map(\.floor), ["Attic", "Ground"])
    }

    func testRoomsWithoutAGroupAreTheirOwnBlock() throws {
        let blocks = PlanBlock.blocks(for: try rooms([(nil, nil, nil), (nil, "A", nil)]))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].group, PlanBlock.noGroup)
    }
}
