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

    func testContinuingAnOldScanMovesItsLastScannedDate() {
        var continued = entry("old", floor: "Attic", daysAgo: 6)
        continued.lastCapturedAt = Date()
        let other = entry("other", property: "prop-2", floor: "Attic", daysAgo: 2)
        let homes = HomeAggregator.aggregate([other, continued])
        XCTAssertEqual(homes.first?.key.propertyId, "prop-1")
        XCTAssertEqual(homes.first?.latestDate, continued.lastCapturedAt)
        XCTAssertEqual(homes.first?.mostRecentEntry?.sessionId, "old")
    }

    func testLastActivityIgnoresACaptureDateBeforeCreation() {
        var legacy = entry("legacy", floor: nil, daysAgo: 1)
        legacy.lastCapturedAt = legacy.createdAt.addingTimeInterval(-60)
        XCTAssertEqual(legacy.lastActivityAt, legacy.createdAt)
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

    func testScanWithMultipleFloorsAppearsUnderEachFloor() {
        var e = ScanHistoryEntry(
            sessionId: "multi-floor",
            accessToken: "t",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date(),
            expiresAt: nil,
            floor: "Attic"
        )
        e.cachedRoomsByFloor = [
            "Attic": CachedFloorSummary(roomCount: 1, areaM2: 20),
            "1st floor": CachedFloorSummary(roomCount: 2, areaM2: 40),
        ]
        let homes = HomeAggregator.aggregate([e])
        XCTAssertEqual(homes.count, 1)
        XCTAssertEqual(homes[0].floors.count, 2)
        let attic = homes[0].floors.first { $0.displayName == "Attic" }
        let first = homes[0].floors.first { $0.displayName == "1st floor" }
        XCTAssertEqual(attic?.roomCount, 1)
        XCTAssertEqual(attic?.totalAreaM2, 20)
        XCTAssertEqual(first?.roomCount, 2)
        XCTAssertEqual(first?.totalAreaM2, 40)
    }

    func testAddingFirstFloorToAtticScanKeepsAtticInTheList() {
        var atticOnly = ScanHistoryEntry(
            sessionId: "s1",
            accessToken: "t",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date().addingTimeInterval(-86_400),
            expiresAt: nil,
            floor: "Attic"
        )
        atticOnly.cachedRoomsByFloor = ["Attic": CachedFloorSummary(roomCount: 1, areaM2: 20)]
        var atticAndFirst = atticOnly
        atticAndFirst.cachedRoomsByFloor = [
            "Attic": CachedFloorSummary(roomCount: 1, areaM2: 20),
            "1st floor": CachedFloorSummary(roomCount: 1, areaM2: 25),
        ]
        atticAndFirst.floor = "1st floor"
        let homes = HomeAggregator.aggregate([atticOnly, atticAndFirst])
        let names = Set(homes[0].floors.compactMap { $0.displayName })
        XCTAssertTrue(names.contains("Attic"))
        XCTAssertTrue(names.contains("1st floor"))
    }

    func testLegacyEntryWithoutRoomsByFloorFallsBackToSessionFloor() {
        let legacy = entry("legacy", floor: "Attic", summary: "Attic", area: 15)
        let homes = HomeAggregator.aggregate([legacy])
        XCTAssertEqual(homes[0].floors.count, 1)
        XCTAssertEqual(homes[0].floors[0].displayName, "Attic")
        XCTAssertEqual(homes[0].floors[0].roomCount, 1)
        XCTAssertEqual(homes[0].floors[0].totalAreaM2, 15)
    }

    func testMostRecentEntryIsNotDuplicatedAcrossFloors() {
        var e = ScanHistoryEntry(
            sessionId: "multi-recent",
            accessToken: "t",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil
        )
        e.cachedRoomsByFloor = [
            "Attic": CachedFloorSummary(roomCount: 1, areaM2: 20),
            "1st floor": CachedFloorSummary(roomCount: 1, areaM2: 25),
        ]
        let homes = HomeAggregator.aggregate([e])
        XCTAssertEqual(homes[0].mostRecentEntry?.sessionId, "multi-recent")
    }

    func testMostRecentEntryPicksLatestAcrossDistinctSessions() {
        let older = entry("older", floor: "Attic", summary: "Attic", area: 20, daysAgo: 3)
        let newer = entry("newer", floor: "Attic", summary: "Attic", area: 22, daysAgo: 1)
        let homes = HomeAggregator.aggregate([older, newer])
        XCTAssertEqual(homes[0].mostRecentEntry?.sessionId, "newer")
    }

    func testTotalSessionsDoesNotDoubleCountMultiFloorScans() {
        var e = ScanHistoryEntry(
            sessionId: "multi",
            accessToken: "t",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date(),
            expiresAt: nil
        )
        e.cachedRoomsByFloor = [
            "Attic": CachedFloorSummary(roomCount: 1, areaM2: 20),
            "1st floor": CachedFloorSummary(roomCount: 1, areaM2: 25),
        ]
        let homes = HomeAggregator.aggregate([e])
        XCTAssertEqual(homes[0].totalSessions, 1)
    }

    func testBucketsFromRoomsGroupsByFloor() throws {
        let json = """
        [
          {
            "room_id": "r1", "label": "Room 1", "floor_area_m2": 20.0, "perimeter_m": 18.0,
            "bounding_dimensions_m": {"width_m": 5.0, "length_m": 4.0},
            "confidence": "high", "outline_m": [[0,0],[5,0],[5,4],[0,4]],
            "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
            "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "Attic"
          },
          {
            "room_id": "r2", "label": "Room 2", "floor_area_m2": 25.0, "perimeter_m": 20.0,
            "bounding_dimensions_m": {"width_m": 5.0, "length_m": 5.0},
            "confidence": "high", "outline_m": [[0,0],[5,0],[5,5],[0,5]],
            "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
            "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "1st floor"
          }
        ]
        """
        let rooms = try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
        let buckets = CachedFloorSummary.buckets(from: rooms)
        XCTAssertEqual(buckets["Attic"]?.roomCount, 1)
        XCTAssertEqual(buckets["Attic"]?.areaM2, 20.0)
        XCTAssertEqual(buckets["1st floor"]?.roomCount, 1)
        XCTAssertEqual(buckets["1st floor"]?.areaM2, 25.0)
    }

    func testRoomsWithoutAFloorStayUnassignedLikeOnThePlan() {
        var e = entry("mixed", floor: "Attic")
        e.cachedRoomsByFloor = [
            "Attic": CachedFloorSummary(roomCount: 1, areaM2: 20),
            "": CachedFloorSummary(roomCount: 2, areaM2: 30),
            "1st floor": CachedFloorSummary(roomCount: 1, areaM2: 25),
        ]
        let homes = HomeAggregator.aggregate([e])
        let attic = homes[0].floors.first { $0.displayName == "Attic" }
        let unassigned = homes[0].floors.first { $0.displayName == nil }
        XCTAssertEqual(attic?.roomCount, 1)
        XCTAssertEqual(attic?.totalAreaM2, 20)
        XCTAssertEqual(unassigned?.roomCount, 2)
        XCTAssertEqual(unassigned?.totalAreaM2, 30)
        XCTAssertEqual(homes[0].totalRooms, 4)
    }

    func testContinuingOnAnotherFloorDoesNotMoveRoomsWithoutAFloor() {
        var e = entry("continued", floor: "Attic")
        e.cachedRoomsByFloor = [
            "": CachedFloorSummary(roomCount: 3, areaM2: 74),
            "Attic": CachedFloorSummary(roomCount: 3, areaM2: 74),
        ]
        let homes = HomeAggregator.aggregate([e])
        let attic = homes[0].floors.first { $0.displayName == "Attic" }
        XCTAssertEqual(attic?.roomCount, 3)
        XCTAssertEqual(attic?.totalAreaM2, 74)
        XCTAssertEqual(homes[0].floors.count, 2)
    }

    func testFloorlessRoomsOnAScanWithoutADefaultFloorAreUnassigned() {
        var e = entry("no-default", floor: nil)
        e.cachedRoomsByFloor = ["": CachedFloorSummary(roomCount: 2, areaM2: 30)]
        let homes = HomeAggregator.aggregate([e])
        XCTAssertEqual(homes[0].floors.count, 1)
        XCTAssertNil(homes[0].floors[0].displayName)
        XCTAssertEqual(homes[0].floors[0].roomCount, 2)
    }

    func testBucketsKeepRoomsWithoutAFloor() throws {
        let json = """
        [
          {
            "room_id": "r1", "label": "Room 1", "floor_area_m2": 12.0, "perimeter_m": 14.0,
            "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
            "confidence": "high", "outline_m": [[0,0],[4,0],[4,3],[0,3]],
            "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
            "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": null
          }
        ]
        """
        let rooms = try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
        let buckets = CachedFloorSummary.buckets(from: rooms)
        XCTAssertEqual(buckets[""]?.roomCount, 1)
        XCTAssertEqual(buckets[""]?.areaM2, 12.0)
    }

    func testRoomsAreSectionedByFloorFromTheTopDown() throws {
        let json = """
        [
          {"room_id": "g1", "label": "Room 1", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "Begane grond"},
          {"room_id": "n1", "label": "Room 2", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": null},
          {"room_id": "z1", "label": "Room 3", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "Zolder"},
          {"room_id": "g2", "label": "Room 4", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "begane grond "},
          {"room_id": "f1", "label": "Room 5", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "1e verdieping"}
        ]
        """
        let rooms = try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
        let sections = RoomFloorSection.sections(for: rooms)
        XCTAssertEqual(sections.map(\.title), ["Zolder", "1e verdieping", "Begane grond", "Floor not set"])
        XCTAssertEqual(sections[2].rooms.map(\.roomId), ["g1", "g2"])
        XCTAssertEqual(sections[3].rooms.map(\.roomId), ["n1"])
    }

    func testRoomsOnOneFloorGetNoSectionHeading() throws {
        let json = """
        [
          {"room_id": "a", "label": "Room 1", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "Attic"},
          {"room_id": "b", "label": "Room 2", "floor_area_m2": 10.0, "perimeter_m": 13.0, "bounding_dimensions_m": {"width_m": 3.0, "length_m": 3.3}, "confidence": "high", "outline_m": [[0,0],[3,0],[3,3.3],[0,3.3]], "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null}, "openings": [], "objects": [], "structure_origin_m": null, "room_type": null, "floor": "attic"}
        ]
        """
        let rooms = try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
        let sections = RoomFloorSection.sections(for: rooms)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(sections[0].rooms.count, 2)
    }
}
