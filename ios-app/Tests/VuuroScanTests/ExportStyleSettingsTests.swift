import XCTest
@testable import VuuroScan

final class ExportStyleSettingsTests: XCTestCase {
    private func settings(
        planType: ExportPlanType = .fullReport,
        showFurniture: Bool = true,
        categories: Set<String> = Set(ExportStyleSettings.allFurnitureCategories)
    ) -> ExportStyleSettings {
        ExportStyleSettings(
            planType: planType,
            showWalkPath: true,
            showFurniture: showFurniture,
            furnitureCategories: categories,
            orientation: "as_captured",
            roomFill: "default"
        )
    }

    private func query(_ style: ExportStyleSettings) -> [String: String] {
        Dictionary(uniqueKeysWithValues: style.queryItems.map { ($0.name, $0.value ?? "") })
    }

    func testListingPlanOnlySendsTheFundaStyle() {
        XCTAssertEqual(query(settings(planType: .listingPlan)), ["style": "funda"])
    }

    func testFullReportNeverSendsTheFundaStyle() {
        let items = query(settings())
        XCTAssertNil(items["style"])
        XCTAssertEqual(items["walk_path"], "1")
        XCTAssertEqual(items["orientation"], "as_captured")
        XCTAssertEqual(items["room_fill"], "default")
    }

    func testFurnitureQueryValue() {
        XCTAssertEqual(settings().furnitureQueryValue, "all")
        XCTAssertEqual(settings(showFurniture: false).furnitureQueryValue, "none")
        XCTAssertEqual(settings(categories: []).furnitureQueryValue, "none")
        XCTAssertEqual(settings(categories: ["sofa", "bed"]).furnitureQueryValue, "bed,sofa")
    }

    func testSettingsRoundTripThroughUserDefaults() {
        let original = ExportStyleSettings.load()
        defer { original.save() }
        var changed = settings(planType: .listingPlan, categories: ["sink"])
        changed.roomFill = "white"
        changed.save()
        XCTAssertEqual(ExportStyleSettings.load(), changed)
    }

    func testWalkPathToggleMapsToQueryValue() {
        var on = settings()
        on.showWalkPath = true
        var off = settings()
        off.showWalkPath = false
        XCTAssertEqual(query(on)["walk_path"], "1")
        XCTAssertEqual(query(off)["walk_path"], "0")
    }

    func testListingPlanIgnoresAllOtherToggles() {
        var s = settings(planType: .listingPlan, showFurniture: true)
        s.showWalkPath = true
        s.roomFill = "white"
        s.orientation = "longest_horizontal"
        XCTAssertEqual(query(s), ["style": "funda"])
    }

    func testRoundTripPreservesEmptyFurnitureCategories() {
        let original = ExportStyleSettings.load()
        defer { original.save() }
        let changed = settings(categories: [])
        changed.save()
        XCTAssertEqual(ExportStyleSettings.load().furnitureCategories, [])
    }

    func testRoundTripPreservesCustomSubset() {
        let original = ExportStyleSettings.load()
        defer { original.save() }
        let changed = settings(categories: ["bed", "sofa"])
        changed.save()
        XCTAssertEqual(ExportStyleSettings.load().furnitureCategories, ["bed", "sofa"])
    }

    func testListingPlanRoundTripsAcrossReloads() {
        let original = ExportStyleSettings.load()
        defer { original.save() }
        let changed = settings(planType: .listingPlan)
        changed.save()
        XCTAssertEqual(ExportStyleSettings.load().planType, .listingPlan)
    }
}
