import XCTest
@testable import VuuroScan

final class LidarDeviceNameTests: XCTestCase {
    func testKnownPhoneShowsItsModelName() {
        XCTAssertEqual(LidarDeviceName.display("iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(LidarDeviceName.display("iPhone13,3"), "iPhone 12 Pro")
    }

    func testUnknownIdIsShownAsIs() {
        XCTAssertEqual(LidarDeviceName.display("iPhone99,9"), "iPhone99,9")
        XCTAssertEqual(LidarDeviceName.display("arm64"), "arm64")
    }
}
