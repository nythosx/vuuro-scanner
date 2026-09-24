import XCTest
@testable import VuuroScan

final class HomeAggregatorTests: XCTestCase {
    private func entry(
        _ id: String,
        property: String = "prop-1",
        unit: String = "unit-1",
        floor: String?,
        summary: String? = nil,
        area: Double? = nil,
        daysAgo: Double = 0
    ) -> ScanHistoryEntry {
        ScanHistoryEntry(
            sessionId: id,
            accessToken: "token-\(id)",
            propertyId: property,
            unitId: unit,
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
            expiresAt: nil,
            cachedRoomSummary: summary,
            cachedFloorAreaM2: area,
            floor: floor
        )
    }

    func testFloorsAreOrderedTopOfHouseFirst() {
        let entries = [
            entry("a", floor: "Basement"),
            entry("b", floor: "Ground floor"),
            entry("c", floor: "Attic"),
            entry("d", floor: "1st floor"),
            entry("e", floor: nil),
            entry("f", floor: "2nd floor"),
        ]
        let homes = HomeAggregator.aggregate(entries)
        XCTAssertEqual(homes.count, 1)
        XCTAssertEqual(
            homes[0].floors.map { $0.displayName ?? "Unassigned" },
            ["Attic", "2nd floor", "1st floor", "Ground floor", "Basement", "Unassigned"]
        )
    }

    func testDutchFloorNamesAreRanked() {
        XCTAssertGreaterThan(HomeAggregator.floorRank("Zolder"), HomeAggregator.floorRank("Eerste verdieping"))
        XCTAssertGreaterThan(HomeAggregator.floorRank("Eerste verdieping"), HomeAggregator.floorRank("Begane grond"))
        XCTAssertGreaterThan(HomeAggregator.floorRank("Begane grond"), HomeAggregator.floorRank("Kelder"))
    }

    func testWordAndNumberFloorNamesRankTheSame() {
        XCTAssertEqual(HomeAggregator.floorRank("First floor"), HomeAggregator.floorRank("1st floor"))
        XCTAssertLessThan(HomeAggregator.floorRank("First floor"), HomeAggregator.floorRank("2nd floor"))
        XCTAssertEqual(HomeAggregator.floorRank("Tweede verdieping"), HomeAggregator.floorRank("2e verdieping"))
    }

    func testFloorNamesAreGroupedCaseInsensitively() {
        let homes = HomeAggregator.aggregate([entry("a", floor: "Attic"), entry("b", floor: " attic ")])
        XCTAssertEqual(homes[0].floors.count, 1)
        XCTAssertEqual(homes[0].floors[0].sessions.count, 2)
    }

    func testHomesAreSplitByPropertyAndUnitAndSortedByLatestScan() {
        let homes = HomeAggregator.aggregate([
            entry("a", unit: "unit-1", floor: "Attic", daysAgo: 5),
            entry("b", unit: "unit-2", floor: "Attic", daysAgo: 1),
        ])
        XCTAssertEqual(homes.map(\.key.unitId), ["unit-2", "unit-1"])
    }

    func testRoomCountAndAreaTotals() {
        let homes = HomeAggregator.aggregate([
            entry("a", floor: "Attic", summary: "Attic", area: 12.5),
            entry("b", floor: "1st floor", summary: "Kitchen, Bedroom, Bathroom, +2 more", area: 40),
        ])
        XCTAssertEqual(homes[0].totalRooms, 6)
        XCTAssertEqual(homes[0].totalAreaM2, 52.5, accuracy: 0.001)
    }

    func testParsedRoomCount() {
        XCTAssertEqual(entry("a", floor: nil, summary: nil).parsedRoomCount, 0)
        XCTAssertEqual(entry("a", floor: nil, summary: "Attic").parsedRoomCount, 1)
        XCTAssertEqual(entry("a", floor: nil, summary: "A, B, C, +4 more").parsedRoomCount, 7)
    }
}
