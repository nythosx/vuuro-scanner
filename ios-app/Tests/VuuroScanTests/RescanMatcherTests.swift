import XCTest
@testable import VuuroScan

final class RescanMatcherTests: XCTestCase {
    private func rooms(_ specs: [(id: String, floor: String?, area: Double, perimeter: Double, type: String?)]) throws -> [FloorPlan.Room] {
        let items = specs.map { spec -> String in
            let floor = spec.floor.map { "\"\($0)\"" } ?? "null"
            let type = spec.type.map { "{\"guess\": \"\($0)\", \"guess_source\": \"user\", \"confirmed\": \"\($0)\"}" } ?? "null"
            return """
            {
              "room_id": "\(spec.id)", "label": "\(spec.id)", "floor_area_m2": \(spec.area), "perimeter_m": \(spec.perimeter),
              "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
              "confidence": "high", "outline_m": [[0,0],[4,0],[4,3],[0,3]],
              "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
              "openings": [], "objects": [], "structure_origin_m": null, "room_type": \(type), "floor": \(floor)
            }
            """
        }
        return try JSONDecoder().decode([FloorPlan.Room].self, from: Data(("[" + items.joined(separator: ",") + "]").utf8))
    }

    func testTheSameRoomOnTheSameFloorMatches() throws {
        let existing = try rooms([("attic", "Attic", 20, 18, nil)])
        let found = RescanMatcher.candidates(areaM2: 21, perimeterM: 18.4, roomType: nil, floor: "attic ", existing: existing)
        XCTAssertEqual(found.map(\.roomId), ["attic"])
    }

    func testAnotherFloorNeverMatches() throws {
        let existing = try rooms([("attic", "Attic", 20, 18, nil)])
        XCTAssertTrue(RescanMatcher.candidates(areaM2: 20, perimeterM: 18, roomType: nil, floor: "Ground floor", existing: existing).isEmpty)
    }

    func testADifferentSizeDoesNotMatch() throws {
        let existing = try rooms([("attic", "Attic", 20, 18, nil)])
        XCTAssertTrue(RescanMatcher.candidates(areaM2: 30, perimeterM: 18, roomType: nil, floor: "Attic", existing: existing).isEmpty)
        XCTAssertTrue(RescanMatcher.candidates(areaM2: 20, perimeterM: 24, roomType: nil, floor: "Attic", existing: existing).isEmpty)
    }

    func testTheSameTypeComesFirst() throws {
        let existing = try rooms([
            ("bed-a", "Attic", 20, 18, "bedroom"),
            ("bath-a", "Attic", 20.5, 18, "bathroom"),
        ])
        let found = RescanMatcher.candidates(areaM2: 20.5, perimeterM: 18, roomType: "bathroom", floor: "Attic", existing: existing)
        XCTAssertEqual(found.map(\.roomId), ["bath-a", "bed-a"])
    }

    func testRoomsAlreadyChosenForReplacementAreSkipped() throws {
        let existing = try rooms([("attic", "Attic", 20, 18, nil)])
        XCTAssertTrue(RescanMatcher.candidates(areaM2: 20, perimeterM: 18, roomType: nil, floor: "Attic", existing: existing, excluding: ["attic"]).isEmpty)
    }

    func testNoFloorOnlyMatchesRoomsWithoutAFloor() throws {
        let existing = try rooms([("loose", nil, 12, 14, nil), ("attic", "Attic", 12, 14, nil)])
        XCTAssertEqual(RescanMatcher.candidates(areaM2: 12, perimeterM: 14, roomType: nil, floor: nil, existing: existing).map(\.roomId), ["loose"])
    }
}
