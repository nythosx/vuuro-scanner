import UIKit
import XCTest
@testable import VuuroScan

final class PerfTraceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PerfSpan.allCases.forEach(PerfTrace.cancel)
    }

    func testEndWithoutBeginReturnsNil() {
        XCTAssertNil(PerfTrace.end(.usdzExport))
    }

    func testBeginThenEndReturnsElapsedAndClosesSpan() {
        PerfTrace.begin(.dollhouseBuild)
        XCTAssertTrue(PerfTrace.isOpen(.dollhouseBuild))
        let ms = PerfTrace.end(.dollhouseBuild, detail: "test")
        XCTAssertNotNil(ms)
        XCTAssertGreaterThanOrEqual(ms ?? -1, 0)
        XCTAssertFalse(PerfTrace.isOpen(.dollhouseBuild))
        XCTAssertNil(PerfTrace.end(.dollhouseBuild))
    }

    func testCancelClosesSpanWithoutMeasurement() {
        PerfTrace.begin(.historyLoad)
        PerfTrace.cancel(.historyLoad)
        XCTAssertFalse(PerfTrace.isOpen(.historyLoad))
        XCTAssertNil(PerfTrace.end(.historyLoad))
    }

    func testSpansAreIndependent() {
        PerfTrace.begin(.roomUpload)
        PerfTrace.begin(.roomProcessing)
        XCTAssertNotNil(PerfTrace.end(.roomProcessing))
        XCTAssertTrue(PerfTrace.isOpen(.roomUpload))
        XCTAssertNotNil(PerfTrace.end(.roomUpload))
    }

    func testEndFromBackgroundThreadIsSafe() {
        PerfTrace.begin(.scanStartToReady)
        let results = ResultBox()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append(PerfTrace.end(.scanStartToReady))
        }
        XCTAssertEqual(results.measuredCount, 1)
    }

    func testMessageFormat() {
        XCTAssertEqual(PerfTrace.message(span: .usdzExport, ms: 1234.6, detail: nil), "PERF usdz_export 1235 ms")
        XCTAssertEqual(PerfTrace.message(span: .roomUpload, ms: 12, detail: "room 1 of 2"), "PERF room_upload 12 ms (room 1 of 2)")
        XCTAssertEqual(PerfTrace.message(span: .historyLoad, ms: 3, detail: ""), "PERF history_load 3 ms")
    }

    func testMessageSurvivesRedaction() {
        let message = PerfTrace.message(span: .roomUpload, ms: 842, detail: "room 2 of 3, 512 KB")
        XCTAssertEqual(DiagnosticsRedactor.redact(message), message)
    }

    func testImageDecodingReturnsImageForPNG() async {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
        let png = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let image = await ImageDecoding.decoded(png)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width ?? 0, 4, accuracy: 0.01)
    }

    func testImageDecodingReturnsNilForGarbage() async {
        let image = await ImageDecoding.decoded(Data("not an image".utf8))
        XCTAssertNil(image)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []

    func append(_ value: Double?) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var measuredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }.count
    }
}
