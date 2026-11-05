import XCTest
@testable import VuuroScan

final class LidarCaptureLinkTests: XCTestCase {
    private func manifest(created: String, updated: String, sessionId: String? = nil) -> LidarCaptureManifest {
        var manifest = LidarCaptureManifest(
            createdAt: created,
            updatedAt: updated,
            device: "test",
            systemVersion: "26.0",
            supportsSceneDepth: true,
            supportsMeshClassification: true
        )
        manifest.sessionId = sessionId
        return manifest
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testSessionCreatedRightAfterCaptureMatchesByTime() {
        let capture = manifest(created: "2026-11-04T13:03:56Z", updated: "2026-11-04T13:06:20Z")
        XCTAssertTrue(LidarCaptureLibrary.overlaps(capture, [date("2026-11-04T13:07:30Z")]))
    }

    func testSessionFromAnotherHourDoesNotMatch() {
        let capture = manifest(created: "2026-11-04T13:03:56Z", updated: "2026-11-04T13:06:20Z")
        XCTAssertFalse(LidarCaptureLibrary.overlaps(capture, [date("2026-11-04T14:30:00Z")]))
        XCTAssertFalse(LidarCaptureLibrary.overlaps(capture, [date("2026-11-04T12:40:00Z")]))
    }

    func testUnreadableDatesNeverMatch() {
        let capture = manifest(created: "not a date", updated: "2026-11-04T13:06:20Z")
        XCTAssertFalse(LidarCaptureLibrary.overlaps(capture, [date("2026-11-04T13:05:00Z")]))
    }

    func testManifestWithoutSessionIdStillDecodes() throws {
        let old = manifest(created: "2026-11-04T13:03:56Z", updated: "2026-11-04T13:06:20Z")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        XCTAssertNil(json["session_id"])
        json.removeValue(forKey: "session_id")
        let decoded = try JSONDecoder().decode(LidarCaptureManifest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.sessionId)
    }

    func testSessionIdRoundTrips() throws {
        let linked = manifest(created: "2026-11-05T13:03:56Z", updated: "2026-11-05T13:06:20Z", sessionId: "abc")
        let decoded = try JSONDecoder().decode(LidarCaptureManifest.self, from: JSONEncoder().encode(linked))
        XCTAssertEqual(decoded.sessionId, "abc")
    }
}
