import XCTest

final class VuuroScanUITests: XCTestCase {
    private let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeApp(onboardingDone: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        app.launchEnvironment["SCAN_SERVICE_BASE_URL"] = environment["SCAN_SERVICE_BASE_URL"] ?? "http://127.0.0.1:8089"
        app.launchEnvironment["FAKE_LIDAR_MODE"] = "1"
        app.launchArguments += [
            "-hasCompletedOnboarding", onboardingDone ? "YES" : "NO",
            "-onboardingCompletedVersion", onboardingDone ? "2" : "0",
        ]
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK", "Allow", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) never appeared")
        target.tap()
    }

    private func type(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "\(identifier) never appeared")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func startScan(_ app: XCUIApplication, entry: String, property: String, unit: String) {
        tap(app, entry)
        type(app, "startScan.propertyId", property)
        type(app, "startScan.unitId", unit)
        type(app, "startScan.organisationId", "org-ui-tests")
        tap(app, "startScan.start")
        let agree = element(app, "reagree.agree")
        if agree.waitForExistence(timeout: 5) {
            agree.tap()
        }
    }

    private func finishToResult(_ app: XCUIApplication) {
        tap(app, "attachments.finishAndUpload")
        XCTAssertTrue(element(app, "result.done").waitForExistence(timeout: timeout), "result screen never appeared")
    }

    func testOnboardingCanBeSkippedToHome() {
        let app = makeApp(onboardingDone: false)
        app.launch()
        tap(app, "onboarding.skip")
        XCTAssertTrue(element(app, "home.scanSingleRoom").waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "home.scanWholeUnit").exists)
    }

    func testSingleRoomFakeLidarCaptureReachesResult() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-single", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        XCTAssertTrue(app.staticTexts["Room captured"].exists)
        XCTAssertTrue(element(app, "result.viewPDF").exists)
    }

    func testFakeMultiRoomCaptureReachesResult() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanWholeUnit", property: "prop-ui-multi", unit: "unit-1")
        tap(app, "multiCapture.fakeScan")
        finishToResult(app)
        XCTAssertTrue(app.staticTexts["Unit captured"].waitForExistence(timeout: timeout))
    }

    func testExportStyleChangesWaitForSave() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-style", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        XCTAssertFalse(element(app, "result.saveChanges").exists)
        let planType = element(app, "exportStyle.planType")
        XCTAssertTrue(planType.waitForExistence(timeout: timeout))
        planType.buttons["Listing plan"].tap()
        XCTAssertTrue(element(app, "result.saveChanges").waitForExistence(timeout: timeout))
        tap(app, "result.discardChanges")
        XCTAssertFalse(element(app, "result.saveChanges").waitForExistence(timeout: 3))
    }

    func testHistoryShowsTheHomeAfterAScan() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-homes", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        tap(app, "result.saveAndReturnHome")
        tap(app, "home.recentScan")
        let viewMode = element(app, "history.viewMode")
        XCTAssertTrue(viewMode.waitForExistence(timeout: timeout))
        viewMode.buttons["Homes"].tap()
        XCTAssertTrue(app.staticTexts["prop-ui-homes \u{00B7} unit-1"].waitForExistence(timeout: timeout))
    }
}
