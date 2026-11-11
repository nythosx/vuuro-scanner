import XCTest
@testable import VuuroScan

final class LidarDeviceNameTests: XCTestCase {
    func testKnownPhoneShowsItsNameAndHardwareId() {
        XCTAssertEqual(LidarDeviceName.display("iPhone17,1"), "iPhone 16 Pro (iPhone17,1)")
        XCTAssertEqual(LidarDeviceName.display("iPhone13,3"), "iPhone 12 Pro (iPhone13,3)")
    }

    func testUnknownIdIsShownAsIs() {
        XCTAssertEqual(LidarDeviceName.display("iPhone99,9"), "iPhone99,9")
        XCTAssertEqual(LidarDeviceName.display("arm64"), "arm64")
    }
}
