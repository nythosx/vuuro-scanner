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
        app.launchArguments += ["-scanInstructions.seen.single", "YES", "-scanInstructions.seen.multi", "YES", "-uiTestResetState"]
        if onboardingDone {
            app.launchArguments += ["-hasCompletedOnboarding", "YES", "-onboardingCompletedVersion", "2"]
        } else {
            app.launchArguments += ["-uiTestResetOnboarding"]
        }
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

    private func scrollIntoView(_ app: XCUIApplication, _ target: XCUIElement) {
        var attempts = 0
        while !target.isHittable && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) never appeared")
        scrollIntoView(app, target)
        target.tap()
    }

    private func type(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "\(identifier) never appeared")
        field.tap()
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
        type(app, "startScan.floor", "Ground floor")
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

    private func openSavedReport(_ app: XCUIApplication, property: String) {
        startScan(app, entry: "home.scanSingleRoom", property: property, unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        tap(app, "result.saveAndReturnHome")
        tap(app, "home.recentScan")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "history card never appeared")
        card.tap()
        XCTAssertTrue(element(app, "report.close").waitForExistence(timeout: timeout), "report did not open")
    }

    private func shareSheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["ActivityListView", "UIActivityContentView"]))
            .firstMatch
    }

    private func closeShareSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    func testSavedReportShare3DModelOpensAndClosesTwice() {
        let app = makeApp()
        app.launch()
        openSavedReport(app, property: "prop-ui-usdz")
        for round in 1...2 {
            let menu = element(app, "report.shareMenu")
            XCTAssertTrue(menu.waitForExistence(timeout: timeout), "share menu never appeared (round \(round))")
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: menu)
            if XCTWaiter().wait(for: [hittable], timeout: 10) != .completed {
                print("SHARE_MENU_NOT_HITTABLE round \(round)
\(app.debugDescription)")
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "share-menu-not-hittable-round-\(round)"
                shot.lifetime = .keepAlways
                add(shot)
                menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                menu.tap()
            }
            tap(app, "report.shareUSDZ")
            XCTAssertTrue(shareSheet(app).waitForExistence(timeout: 60), "share sheet for the 3D model never appeared (round \(round))")
            closeShareSheet(app)
            let gone = NSPredicate(format: "exists == false")
            let closed = XCTNSPredicateExpectation(predicate: gone, object: shareSheet(app))
            XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: timeout), .completed, "share sheet did not close (round \(round))")
            XCTAssertTrue(element(app, "report.close").waitForExistence(timeout: timeout), "report not reachable after closing the share sheet (round \(round))")
        }
    }

    func testSavedReportSwitchesTo3DAndBack() {
        let app = makeApp()
        app.launch()
        openSavedReport(app, property: "prop-ui-3d")
        let viewMode = element(app, "report.planViewMode")
        XCTAssertTrue(viewMode.waitForExistence(timeout: timeout), "report.planViewMode never appeared")
        scrollIntoView(app, viewMode)
        viewMode.buttons["3D"].tap()
        XCTAssertTrue(element(app, "dollhouse.mode").waitForExistence(timeout: timeout), "3D controls never appeared")
        let modes = element(app, "dollhouse.mode")
        modes.buttons.element(boundBy: 0).tap()
        modes.buttons.element(boundBy: 1).tap()
        let scene = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "3D floor plan")).firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: timeout), "3D scene never appeared")
        viewMode.buttons["2D plan"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "dollhouse.mode"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "3D controls did not go away after switching back to 2D")
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

    func testExportStyleChangesSaveRightAway() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-style", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        XCTAssertFalse(element(app, "result.saveChanges").exists)
        let planType = element(app, "exportStyle.planType")
        XCTAssertTrue(planType.waitForExistence(timeout: timeout))
        scrollIntoView(app, planType)
        planType.buttons["Automatic"].tap()
        planType.buttons["Full report"].tap()
        tap(app, "exportStyle.walkPath")
        XCTAssertFalse(element(app, "result.saveChanges").waitForExistence(timeout: 3))
        tap(app, "result.done")
        XCTAssertFalse(app.alerts["Unsaved changes"].waitForExistence(timeout: 2))
        XCTAssertTrue(element(app, "home.scanSingleRoom").waitForExistence(timeout: timeout))
    }

    func testAttachmentsAddNoteAndFinish() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-attach", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")

        let noteEditor = element(app, "attachments.note")
        XCTAssertTrue(noteEditor.waitForExistence(timeout: timeout), "attachments.note never appeared")
        scrollIntoView(app, noteEditor)
        noteEditor.tap()
        noteEditor.typeText("UI test note")

        tap(app, "attachments.finishAndUpload")
        XCTAssertTrue(element(app, "result.done").waitForExistence(timeout: timeout), "result screen never appeared")
    }

    func testEditNoteFromResult() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-editnote", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")

        let noteEditor = element(app, "attachments.note")
        XCTAssertTrue(noteEditor.waitForExistence(timeout: timeout), "attachments.note never appeared")
        scrollIntoView(app, noteEditor)
        noteEditor.tap()
        noteEditor.typeText("Crack in wall")
        finishToResult(app)

        tap(app, "attachmentsList.editNote")
        let editor = element(app, "noteEdit.text")
        XCTAssertTrue(editor.waitForExistence(timeout: timeout), "noteEdit.text never appeared")
        editor.tap()
        editor.typeText(" near window")
        tap(app, "noteEdit.save")

        let edited = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "near window")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: timeout), "edited note text never showed on the result screen")
    }

    func testMissingItemFromResult() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-missing", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)

        let addMissing = element(app, "roomCard.addMissingItem")
        XCTAssertTrue(addMissing.waitForExistence(timeout: timeout), "roomCard.addMissingItem never appeared")
        scrollIntoView(app, addMissing)
        addMissing.tap()

        let noteField = element(app, "missingItem.note")
        XCTAssertTrue(noteField.waitForExistence(timeout: timeout), "missingItem.note never appeared")
        noteField.tap()
        noteField.typeText("Roof window missed")

        tap(app, "missingItem.save")
        XCTAssertTrue(element(app, "result.done").waitForExistence(timeout: timeout), "did not return to result after saving missing item")
    }

    func testSavedReportOpensFromHistory() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-report", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        tap(app, "result.saveAndReturnHome")
        tap(app, "home.recentScan")

        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "history card never appeared")
        card.tap()

        XCTAssertTrue(element(app, "report.close").waitForExistence(timeout: timeout), "report did not open")
    }

    func testSavedReportObjectEditStartsSaveBar() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-edit", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        tap(app, "result.saveAndReturnHome")
        tap(app, "home.recentScan")

        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "history card never appeared")
        card.tap()

        XCTAssertTrue(element(app, "report.close").waitForExistence(timeout: timeout), "report did not open")

        let toggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@", ".include"))
            .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: timeout), "no object include toggle appeared on the saved report")
        scrollIntoView(app, toggle)
        toggle.tap()

        XCTAssertTrue(element(app, "report.saveChanges").waitForExistence(timeout: timeout), "saveChanges bar did not appear after toggling an object")
        tap(app, "report.saveChanges")

        XCTAssertTrue(element(app, "report.close").waitForExistence(timeout: timeout), "did not return to report after saving")
    }

    func testHomesAddRoomsStartsCapture() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-addrooms", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        tap(app, "result.saveAndReturnHome")
        tap(app, "home.recentScan")

        let viewMode = element(app, "history.viewMode")
        XCTAssertTrue(viewMode.waitForExistence(timeout: timeout), "history.viewMode never appeared")
        viewMode.buttons["Homes"].tap()

        let homeCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homes.card.")).firstMatch
        XCTAssertTrue(homeCard.waitForExistence(timeout: timeout), "homes card never appeared")
        homeCard.tap()

        let addRooms = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeDetail.addRooms.")).firstMatch
        XCTAssertTrue(addRooms.waitForExistence(timeout: timeout), "add-rooms button never appeared")
        addRooms.tap()

        let addToLatest = element(app, "homeDetail.addToLatestScan")
        let startNew = element(app, "homeDetail.startNewVisit")
        XCTAssertTrue(
            addToLatest.waitForExistence(timeout: timeout) || startNew.waitForExistence(timeout: timeout),
            "neither add-rooms option appeared"
        )
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

    func testSavedReportOffersContinueThisScan() {
        let app = makeApp()
        app.launch()
        startScan(app, entry: "home.scanSingleRoom", property: "prop-ui-continue", unit: "unit-1")
        tap(app, "capture.fakeScan")
        tap(app, "anotherRoom.finishUnit")
        finishToResult(app)
        tap(app, "result.saveAndReturnHome")
        tap(app, "home.recentScan")

        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "history card never appeared")
        card.tap()

        tap(app, "report.continueScan")
        XCTAssertTrue(element(app, "report.continueNewFloor").waitForExistence(timeout: timeout), "continue choices never appeared")
    }
}
