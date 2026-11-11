import XCTest
@testable import VuuroScan

final class PhotoTourSettingsTests: XCTestCase {
    func testPhotoStepIsOffByDefault() {
        XCTAssertFalse(PhotoTourSettings.showsStep(photosAfterRoom: false, walkthrough: false))
    }

    func testPhotoStepOpensWhenTurnedOnOrForWalkThrough() {
        XCTAssertTrue(PhotoTourSettings.showsStep(photosAfterRoom: true, walkthrough: false))
        XCTAssertTrue(PhotoTourSettings.showsStep(photosAfterRoom: false, walkthrough: true))
    }

    func testDefaultIsOffWhenNothingIsStored() {
        let defaults = UserDefaults(suiteName: "PhotoTourSettingsTests")!
        defaults.removePersistentDomain(forName: "PhotoTourSettingsTests")
        XCTAssertFalse(defaults.bool(forKey: PhotoTourSettings.afterRoomKey))
    }
}
