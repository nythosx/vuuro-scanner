import XCTest
@testable import VuuroScan

final class ContinueRouteTests: XCTestCase {
    private func rooms(_ specs: [(floor: String?, group: String?, joined: String?, origin: Bool)]) throws -> [FloorPlan.Room] {
        let items = specs.enumerated().map { index, spec -> String in
            let floor = spec.floor.map { "\"\($0)\"" } ?? "null"
            let group = spec.group.map { "\"\($0)\"" } ?? "null"
            let joined = spec.joined.map { "\"\($0)\"" } ?? "null"
            let origin = spec.origin ? "[0, 0]" : "null"
            return """
            {
              "room_id": "r\(index)", "label": "Room \(index)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
              "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
              "confidence": "high", "outline_m": [[0,0],[4,0],[4,3],[0,3]],
              "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
              "openings": [], "objects": [], "structure_origin_m": \(origin), "room_type": null,
              "floor": \(floor), "capture_group_id": \(group), "joined_to_group_id": \(joined)
            }
            """
        }
        return try JSONDecoder().decode([FloorPlan.Room].self, from: Data(("[" + items.joined(separator: ",") + "]").utf8))
    }

    func testSingleRoomListingContinuesAsSingleRooms() throws {
        let plan = try rooms([("Attic", nil, nil, false), ("Attic", nil, nil, false)])
        XCTAssertFalse(ContinueRoute.continuesAsUnit(rooms: plan, floor: "Attic"))
        XCTAssertNil(ContinueRoute.joinTarget(rooms: plan, floor: "Attic"))
    }

    func testWholeUnitOnTheChosenFloorContinuesAsUnit() throws {
        let plan = try rooms([("Ground", "walk-A", nil, true), ("Ground", "walk-A", nil, true)])
        XCTAssertTrue(ContinueRoute.continuesAsUnit(rooms: plan, floor: " ground "))
        XCTAssertEqual(ContinueRoute.joinTarget(rooms: plan, floor: "Ground"), "walk-A")
    }

    func testWholeUnitOnAnotherFloorDoesNotCount() throws {
        let plan = try rooms([("Ground", "walk-A", nil, true)])
        XCTAssertFalse(ContinueRoute.continuesAsUnit(rooms: plan, floor: "Attic"))
    }

    func testJoinedScansTargetTheirRoot() throws {
        let plan = try rooms([("Ground", "walk-A", nil, true), ("Ground", "walk-B", "walk-A", true)])
        XCTAssertEqual(ContinueRoute.joinTarget(rooms: plan, floor: "Ground"), "walk-A")
        XCTAssertEqual(ContinueRoute.mapGroupIds(rooms: plan, floor: "Ground"), ["walk-A", "walk-B"])
    }

    func testTheNewestSeparateScanIsTheTarget() throws {
        let plan = try rooms([("Ground", "walk-A", nil, true), ("Ground", "walk-B", nil, true)])
        XCTAssertEqual(ContinueRoute.joinTarget(rooms: plan, floor: "Ground"), "walk-B")
    }

    func testRoomsWithoutAnOriginAreNotAUnit() throws {
        let plan = try rooms([("Ground", "walk-A", nil, false)])
        XCTAssertFalse(ContinueRoute.continuesAsUnit(rooms: plan, floor: "Ground"))
    }
}
