import XCTest
@testable import VuuroScan

final class WalkthroughStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WalkthroughStore.clear()
    }

    override func tearDown() {
        WalkthroughStore.clear()
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() throws {
        let export = FakeCaptureGenerator.random()
        let data = try JSONEncoder().encode(export)
        let identity = ScanIdentity(
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            occupied: false,
            consentObtained: false,
            floor: "Attic"
        )
        let state = WalkthroughState(
            identity: identity,
            session: nil,
            rooms: [WalkthroughState.StoredRoom(exportJSON: data, floor: "Attic", label: "Room 1")],
            startedAt: Date()
        )
        WalkthroughStore.save(state)
        let loaded = WalkthroughStore.load()
        XCTAssertEqual(loaded?.identity.propertyId, "prop-1")
        XCTAssertEqual(loaded?.rooms.count, 1)
        XCTAssertEqual(loaded?.rooms.first?.floor, "Attic")
    }

    func testExportJSONRoundTripsThroughCodable() throws {
        let export = FakeCaptureGenerator.random()
        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(RoomPlanCaptureExport.self, from: data)
        XCTAssertEqual(decoded.story, export.story)
        XCTAssertEqual(decoded.floors.count, export.floors.count)
        XCTAssertEqual(decoded.walls.count, export.walls.count)
    }

    func testClearRemovesState() {
        let identity = ScanIdentity(
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            occupied: false,
            consentObtained: false,
            floor: nil
        )
        WalkthroughStore.save(WalkthroughState(
            identity: identity,
            session: nil,
            rooms: [],
            startedAt: Date()
        ))
        XCTAssertNotNil(WalkthroughStore.load())
        WalkthroughStore.clear()
        XCTAssertNil(WalkthroughStore.load())
    }

    func testLoadReturnsNilWhenNothingStored() {
        WalkthroughStore.clear()
        XCTAssertNil(WalkthroughStore.load())
    }
}
