import XCTest
@testable import VuuroScan

final class ScanHistoryEntryTests: XCTestCase {
    func testEntriesSavedBeforeFloorAreaExistedStillDecode() throws {
        let legacy = """
        {
          "sessionId": "s-1",
          "accessToken": "",
          "propertyId": "prop-1",
          "unitId": "unit-1",
          "organisationId": "org-1",
          "purpose": "listing",
          "createdAt": 0,
          "cachedRoomSummary": "Attic"
        }
        """
        let entry = try JSONDecoder().decode(ScanHistoryEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.cachedFloorAreaM2)
        XCTAssertNil(entry.floor)
        XCTAssertFalse(entry.occupied)
        XCTAssertEqual(entry.cachedRoomSummary, "Attic")
    }

    func testFloorAreaRoundTrips() throws {
        let entry = ScanHistoryEntry(
            sessionId: "s-2",
            accessToken: "",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil,
            cachedFloorAreaM2: 42.5,
            floor: "Attic"
        )
        let decoded = try JSONDecoder().decode(ScanHistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.cachedFloorAreaM2, 42.5)
        XCTAssertEqual(decoded.floor, "Attic")
    }

    func testExportFileNamesDescribeTheFile() {
        let name = ExportNaming.fileName(
            property: "Home",
            unit: "Attic",
            room: nil,
            date: Date(timeIntervalSince1970: 1_790_000_000),
            suffix: "floorplan",
            ext: "pdf"
        )
        XCTAssertTrue(name.hasPrefix("Home_Attic_"))
        XCTAssertTrue(name.hasSuffix("_floorplan.pdf"))
        XCTAssertEqual(ExportNaming.slug("Keizersgracht 12/A"), "Keizersgracht_12_A")
    }
}
