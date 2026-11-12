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

    private func capture(_ name: String, created: String, frames: Int, depthOnly: Int = 0, duration: Double) -> LidarCaptureMatch {
        var manifest = manifest(created: created, updated: created)
        manifest.stats.frames = frames
        manifest.stats.depthOnlyFrames = depthOnly
        manifest.durationS = duration
        return LidarCaptureMatch(url: URL(fileURLWithPath: "/tmp/\(name)"), manifest: manifest, matchedByTime: true)
    }

    func testSubstantiveCaptureComesBeforeANewerAbandonedOne() {
        let real = capture("real", created: "2026-11-05T10:00:00Z", frames: 60, depthOnly: 150, duration: 75)
        let abandoned = capture("abandoned", created: "2026-11-05T10:05:00Z", frames: 3, duration: 5)
        XCTAssertEqual(LidarCaptureLibrary.substantiveFirst([abandoned, real]).map(\.id), ["real", "abandoned"])
    }

    func testMoreKeyframesWinOverManyDepthOnlyFrames() {
        let depthHeavy = capture("depthHeavy", created: "2026-11-05T10:00:00Z", frames: 10, depthOnly: 1000, duration: 75)
        let keyframes = capture("keyframes", created: "2026-11-05T09:00:00Z", frames: 200, duration: 60)
        XCTAssertEqual(LidarCaptureLibrary.substantiveFirst([depthHeavy, keyframes]).map(\.id), ["keyframes", "depthHeavy"])
    }

    func testEqualCapturesFallBackToLongerThenNewer() {
        let short = capture("short", created: "2026-11-05T10:00:00Z", frames: 10, duration: 20)
        let long = capture("long", created: "2026-11-05T09:00:00Z", frames: 10, duration: 40)
        let newer = capture("newer", created: "2026-11-05T11:00:00Z", frames: 10, duration: 40)
        XCTAssertEqual(LidarCaptureLibrary.substantiveFirst([short, long, newer]).map(\.id), ["newer", "long", "short"])
    }

    func testMeshButtonFollowsTheSelectedCapture() {
        let a = capture("a", created: "2026-11-05T10:00:00Z", frames: 60, duration: 75)
        let b = capture("b", created: "2026-11-05T10:05:00Z", frames: 3, duration: 5)
        XCTAssertEqual(LidarCaptureLibrary.meshURL([a, b], selectedId: "b", meshIds: ["a", "b"])?.lastPathComponent, "b")
        XCTAssertNil(LidarCaptureLibrary.meshURL([a, b], selectedId: "b", meshIds: ["a"]))
        XCTAssertEqual(LidarCaptureLibrary.meshURL([a, b], selectedId: nil, meshIds: ["a"])?.lastPathComponent, "a")
        XCTAssertEqual(LidarCaptureLibrary.meshURL([a, b], selectedId: "gone", meshIds: ["a"])?.lastPathComponent, "a")
        XCTAssertNil(LidarCaptureLibrary.meshURL([], selectedId: nil, meshIds: []))
    }

    func testCaptureLabelShowsLengthAndFrames() {
        let real = capture("real", created: "2026-11-05T10:00:00Z", frames: 60, depthOnly: 150, duration: 75)
        XCTAssertEqual(LiDARProofView.captureLabel(real, date: "5 Nov 2026 at 10:00"), "5 Nov 2026 at 10:00, 75 s, 210 frames")
    }
}
