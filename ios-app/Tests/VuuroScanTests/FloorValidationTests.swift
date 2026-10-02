import XCTest
@testable import VuuroScan

final class FloorValidationTests: XCTestCase {
    func testNonEmptyFloorIsValid() {
        XCTAssertTrue(FloorValidation.isValid("Attic"))
        XCTAssertTrue(FloorValidation.isValid("1st floor"))
    }

    func testWhitespaceOnlyFloorIsInvalid() {
        XCTAssertFalse(FloorValidation.isValid(""))
        XCTAssertFalse(FloorValidation.isValid("   "))
        XCTAssertFalse(FloorValidation.isValid("\n\t"))
    }

    func testTrimmingKeepsTheMeaningfulPart() {
        XCTAssertEqual(FloorValidation.trimmed("  Attic  "), "Attic")
        XCTAssertEqual(FloorValidation.trimmed("\nBasement\t"), "Basement")
    }

    func testFloorsTheServerWouldRejectAreInvalid() {
        XCTAssertFalse(FloorValidation.isValid(String(repeating: "a", count: 61)))
        XCTAssertTrue(FloorValidation.isValid(String(repeating: "a", count: 60)))
        XCTAssertFalse(FloorValidation.isValid("Attic\u{0007}"))
    }

    func testSanitizedFloorIsAlwaysAcceptedByTheServer() {
        XCTAssertEqual(FloorValidation.sanitized("  Attic\u{0007} "), "Attic")
        XCTAssertEqual(FloorValidation.sanitized(String(repeating: "b", count: 80)).count, 60)
        XCTAssertTrue(FloorValidation.isValid(FloorValidation.sanitized("  1st floor  ")))
    }
}
