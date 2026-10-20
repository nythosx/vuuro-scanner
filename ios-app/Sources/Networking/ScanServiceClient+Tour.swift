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
            URLQueryItem(name: "token", value: session.accessToken),
            URLQueryItem(name: "lang", value: AppLanguageSettings.exportLanguageCode),
        ]
        return components.url
    }
}
