import XCTest
@testable import VuuroScan

final class ContinueScanStateTests: XCTestCase {
    private func recognisedState() -> ContinueScanState {
        var state = ContinueScanState()
        _ = state.handle(.targetFound("walk-A"))
        _ = state.handle(.mapFound)
        _ = state.handle(.recognised)
        return state
    }

    func testANewScanJustStartsAndNeverJoins() {
        var state = ContinueScanState()
        XCTAssertEqual(state.handle(.notAContinue), [.startScanning(afterRelocalization: false)])
        XCTAssertNil(state.joinTargetGroupId)
    }

    func testRecognisedContinueJoinsTheTarget() {
        var state = ContinueScanState()
        XCTAssertEqual(state.handle(.targetFound("walk-A")), [.lookForMap])
        XCTAssertEqual(state.handle(.mapFound), [.startRelocalizing])
        XCTAssertTrue(state.showsRelocalizeOverlay)
        XCTAssertEqual(state.handle(.recognised), [.startScanning(afterRelocalization: true)])
        XCTAssertEqual(state.joinTargetGroupId, "walk-A")
        XCTAssertFalse(state.showsRelocalizeOverlay)
    }

    func testNeverJoinsWithoutRecognition() {
        var noMap = ContinueScanState()
        _ = noMap.handle(.targetFound("walk-A"))
        _ = noMap.handle(.noMap)
        XCTAssertTrue(noMap.showsNoMapNotice)
        XCTAssertEqual(noMap.handle(.noMapAcknowledged), [.startScanning(afterRelocalization: false)])
        XCTAssertNil(noMap.joinTargetGroupId)

        var skipped = ContinueScanState()
        _ = skipped.handle(.targetFound("walk-A"))
        _ = skipped.handle(.mapFound)
        XCTAssertEqual(skipped.handle(.skip), [.cancelRelocalization, .startScanning(afterRelocalization: false)])
        XCTAssertNil(skipped.joinTargetGroupId)

        var timedOut = ContinueScanState()
        _ = timedOut.handle(.targetFound("walk-A"))
        _ = timedOut.handle(.mapFound)
        _ = timedOut.handle(.timedOut)
        _ = timedOut.handle(.skip)
        XCTAssertNil(timedOut.joinTargetGroupId)

        var unavailable = ContinueScanState()
        _ = unavailable.handle(.targetFound("walk-A"))
        _ = unavailable.handle(.mapFound)
        _ = unavailable.handle(.unavailable)
        XCTAssertNil(unavailable.joinTargetGroupId)
    }

    func testRetryAfterATimeoutLooksForTheMapAgain() {
        var state = ContinueScanState()
        _ = state.handle(.targetFound("walk-A"))
        _ = state.handle(.mapFound)
        _ = state.handle(.timedOut)
        XCTAssertTrue(state.showsRelocalizeOverlay)
        XCTAssertEqual(state.handle(.retry), [.cancelRelocalization, .lookForMap])
        XCTAssertEqual(state.phase, .lookingForMap)
        XCTAssertEqual(state.handle(.mapFound), [.startRelocalizing])
    }

    func testCaptureFailureAfterRecognitionDropsTheJoin() {
        var state = recognisedState()
        XCTAssertEqual(state.joinTargetGroupId, "walk-A")
        _ = state.handle(.captureFailedAfterRelocalize)
        XCTAssertNil(state.joinTargetGroupId)
        XCTAssertTrue(state.showsRelocalizeOverlay)
        _ = state.handle(.skip)
        XCTAssertNil(state.joinTargetGroupId)
    }

    func testUnrelatedEventsChangeNothing() {
        var state = recognisedState()
        XCTAssertEqual(state.handle(.timedOut), [])
        XCTAssertEqual(state.handle(.retry), [])
        XCTAssertEqual(state.joinTargetGroupId, "walk-A")
    }
}
