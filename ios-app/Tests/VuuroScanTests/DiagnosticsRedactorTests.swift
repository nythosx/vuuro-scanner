import XCTest
@testable import VuuroScan

final class DiagnosticsRedactorTests: XCTestCase {
    func testKnownSecretsAreRedactedEvenWhenTheyLookLikeUUIDs() {
        let token = "3f2b8c1e-9a4d-4e6b-8c2f-1d5e7a9b0c3d"
        let text = "GET /scan-sessions/abc failed with token \(token)"
        let redacted = DiagnosticsRedactor.redact(text, secrets: [token])
        XCTAssertFalse(redacted.contains(token))
        XCTAssertTrue(redacted.contains(DiagnosticsRedactor.placeholder))
    }

    func testSessionIdUUIDsAreKeptForDebugging() {
        let sessionId = "dbfdbfb2-535d-495f-b858-d2976203dd41"
        let text = "Session \(sessionId) deleted from server"
        XCTAssertEqual(DiagnosticsRedactor.redact(text), text)
    }

    func testKeyValueSecretsAreRedacted() {
        let samples = [
            "access_token=supersecretvalue123",
            "\"access_token\": \"supersecretvalue123\"",
            "X-Scan-Access-Token: supersecretvalue123",
            "admin_key=supersecretvalue123",
        ]
        for sample in samples {
            let redacted = DiagnosticsRedactor.redact(sample)
            XCTAssertFalse(redacted.contains("supersecretvalue123"), sample)
        }
    }

    func testBearerTokensAreRedacted() {
        let redacted = DiagnosticsRedactor.redact("Authorization: Bearer abc.def.ghi")
        XCTAssertFalse(redacted.contains("abc.def.ghi"))
    }

    func testShareCodesAreRedacted() {
        let code = "VUURO-SCAN-1:eyJzZXNzaW9uSWQiOiJhYmMiLCJhY2Nlc3NUb2tlbiI6Inh5eiJ9"
        let redacted = DiagnosticsRedactor.redact("Pasted code \(code)")
        XCTAssertFalse(redacted.contains("eyJzZXNzaW9uSWQi"))
        XCTAssertTrue(redacted.contains("VUURO-SCAN-1:\(DiagnosticsRedactor.placeholder)"))
    }

    func testLongOpaqueStringsAreRedactedButURLsSurvive() {
        let opaque = String(repeating: "a1B2", count: 12)
        let url = "https://scan.example.com/scan-sessions/dbfdbfb2-535d-495f-b858-d2976203dd41/export/floorplan.png"
        let redacted = DiagnosticsRedactor.redact("\(url) key \(opaque)")
        XCTAssertTrue(redacted.contains(url))
        XCTAssertFalse(redacted.contains(opaque))
    }
}
