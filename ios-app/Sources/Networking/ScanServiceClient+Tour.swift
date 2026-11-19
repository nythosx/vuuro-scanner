import CryptoKit
import Foundation

extension ScanServiceClient {
    func webTourURL(session: ScanSessionResponse, floorPlan: FloorPlan?) -> URL? {
        if let raw = floorPlan?.tour?.viewerUrl ?? session.tour?.viewerUrl,
           let url = URL(string: raw) {
            return url
        }
        guard isConfigured else { return nil }
        let base = baseURL
            .appendingPathComponent("tour", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: false)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "token", value: Self.viewToken(sessionId: session.id, accessToken: session.accessToken)),
            URLQueryItem(name: "lang", value: AppLanguageSettings.exportLanguageCode),
        ]
        return components.url
    }

    static func viewToken(sessionId: String, accessToken: String) -> String {
        let tokenHash = hex(SHA256.hash(data: Data(accessToken.utf8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("tour-view:\(sessionId)".utf8), using: SymmetricKey(data: Data(tokenHash.utf8)))
        return "view-" + String(hex(mac).prefix(40))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
