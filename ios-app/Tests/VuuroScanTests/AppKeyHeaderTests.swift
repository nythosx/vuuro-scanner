import XCTest
@testable import VuuroScan

private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        let body = """
        {"id":"s-1","property_id":"prop-1","unit_id":"unit-1","organisation_id":"org-1","purpose":"listing","created_at":"2026-10-06T10:00:00+00:00","status":"created","occupied":false,"consent_obtained":false,"access_token":"t-1","expires_at":"2027-01-04T10:00:00+00:00","default_floor":""}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AppKeyHeaderTests: XCTestCase {
    private let identity = ScanIdentity(
        propertyId: "prop-1",
        unitId: "unit-1",
        organisationId: "org-1",
        purpose: .listing,
        occupied: false,
        consentObtained: false
    )

    private func client(appKey: String?) -> ScanServiceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        var client = ScanServiceClient()
        client.baseURL = URL(string: "https://scan.example.test")!
        client.isConfigured = true
        client.appKey = appKey
        client.session = URLSession(configuration: configuration)
        return client
    }

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    func testCreateSessionSendsTheAppKey() async throws {
        let response = try await client(appKey: "test-app-key-0123456789abcdef").createSession(identity: identity)
        XCTAssertEqual(response.accessToken, "t-1")
        let request = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/scan-sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Scan-App-Key"), "test-app-key-0123456789abcdef")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Scan-Access-Token"))
    }

    func testCreateSessionWithoutAKeySendsNoHeader() async throws {
        _ = try await client(appKey: nil).createSession(identity: identity)
        let request = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Scan-App-Key"))
    }

    func testExportsAskForTheAppLanguage() async throws {
        _ = try await client(appKey: nil).fetchFloorPlanPDF(sessionId: "s-1", accessToken: "t-1")
        let request = try XCTUnwrap(RecordingURLProtocol.requests.last)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "lang" }?.value, AppLanguageSettings.exportLanguageCode)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Scan-App-Key"))
    }

    func testExportLanguageFollowsTheAppSetting() {
        XCTAssertEqual(AppLanguageSettings.exportLanguageCode(for: .dutch, preferredLocalizations: ["en"]), "nl")
        XCTAssertEqual(AppLanguageSettings.exportLanguageCode(for: .english, preferredLocalizations: ["nl"]), "en")
        XCTAssertEqual(AppLanguageSettings.exportLanguageCode(for: .system, preferredLocalizations: ["nl-NL", "en"]), "nl")
        XCTAssertEqual(AppLanguageSettings.exportLanguageCode(for: .system, preferredLocalizations: ["de"]), "en")
        XCTAssertEqual(AppLanguageSettings.exportLanguageCode(for: .system, preferredLocalizations: []), "en")
    }

    func testTheAppKeyIsOnlySentWhenStartingAScan() async throws {
        let client = client(appKey: "test-app-key-0123456789abcdef")
        _ = try? await client.rotateToken(sessionId: "s-1", accessToken: "t-1")
        let request = try XCTUnwrap(RecordingURLProtocol.requests.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Scan-App-Key"))
    }
}
