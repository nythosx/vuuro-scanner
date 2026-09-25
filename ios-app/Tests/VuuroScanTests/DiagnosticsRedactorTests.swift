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

    func testMultiLineLogEntryWithEmbeddedToken() {
        let token = "abcdef0123456789abcdef0123456789"
        let text = """
        GET /scan-sessions/abc -> 200
        Header: X-Scan-Access-Token: \(token)
        Body: {"status": "ok"}
        """
        let redacted = DiagnosticsRedactor.redact(text)
        XCTAssertFalse(redacted.contains(token))
    }

    func testNestedJSONStringWithToken() {
        let token = "3f2b8c1e-9a4d-4e6b-8c2f-1d5e7a9b0c3d"
        let text = "{\"outer\": \"{\\\"access_token\\\": \\\"\(token)\\\"}\"}"
        let redacted = DiagnosticsRedactor.redact(text, secrets: [token])
        XCTAssertFalse(redacted.contains(token))
    }

    func testTokenInURLQueryString() {
        let token = "3f2b8c1e-9a4d-4e6b-8c2f-1d5e7a9b0c3d"
        let text = "GET /scan-sessions?access_token=\(token)&unit=metric"
        let redacted = DiagnosticsRedactor.redact(text)
        XCTAssertFalse(redacted.contains(token))
    }

    func testBase64BlobLongerThanThreshold() {
        let blob = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        XCTAssertGreaterThanOrEqual(blob.count, 32)
        let redacted = DiagnosticsRedactor.redact("payload \(blob) end")
        XCTAssertFalse(redacted.contains(blob))
    }

    func testBareUUIDTokenWithoutPrefixSurvivesRedaction() {
        let bareToken = "3f2b8c1e-9a4d-4e6b-8c2f-1d5e7a9b0c3d"
        let text = "Authorization attempt with \(bareToken)"
        let redacted = DiagnosticsRedactor.redact(text)
        XCTAssertTrue(
            redacted.contains(bareToken),
            "A bare UUID token survives redaction because the opaque pass preserves UUIDs to keep session IDs debuggable. If this now fails, redaction improved — update this test to assert the new behavior."
        )
    }

    func testSecretsListCatchesBareUUIDToken() {
        let token = "3f2b8c1e-9a4d-4e6b-8c2f-1d5e7a9b0c3d"
        let text = "Authorization attempt with \(token)"
        let redacted = DiagnosticsRedactor.redact(text, secrets: [token])
        XCTAssertFalse(
            redacted.contains(token),
            "Passing the token through secrets: must redact it even when it is a bare UUID with no access_token= prefix."
        )
    }
}
