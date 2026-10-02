import XCTest
@testable import VuuroScan

final class ActivityRefreshThrottleTests: XCTestCase {
    func testFirstCallAlwaysRefreshes() {
        var throttle = ActivityRefreshThrottle(interval: 60)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldRefresh(now: now))
    }

    func testSecondCallWithinIntervalIsSkipped() {
        var throttle = ActivityRefreshThrottle(interval: 60)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldRefresh(now: now))
        XCTAssertFalse(throttle.shouldRefresh(now: now.addingTimeInterval(59)))
    }

    func testCallAfterIntervalRefreshesAgain() {
        var throttle = ActivityRefreshThrottle(interval: 60)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(throttle.shouldRefresh(now: now))
        XCTAssertTrue(throttle.shouldRefresh(now: now.addingTimeInterval(61)))
    }
}
