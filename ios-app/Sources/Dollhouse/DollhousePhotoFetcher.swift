import Foundation

enum DollhousePhotoFetcher {
    static func fetch(
        _ photos: [FloorPlan.Photo360],
        accessToken: String,
        client: ScanServiceClient = ScanServiceClient()
    ) async -> [String: Data] {
        let urls = Array(Set(photos.map(\.url).filter { !$0.isEmpty }))
        guard !urls.isEmpty else { return [:] }
        let fetched = await withTaskGroup(of: (String, Data)?.self) { group in
            for url in urls {
                group.addTask {
                    guard let data = try? await client.fetchPhotoData(url: url, accessToken: accessToken) else {
                        return nil
                    }
                    return (url, data)
                }
            }
            var results: [(String, Data)] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
        if fetched.count < urls.count {
            DiagnosticsLog.shared.record(
                "Dollhouse export: fetched \(fetched.count) of \(urls.count) tour photos for wall textures",
                category: .info
            )
        }
        return Dictionary(fetched, uniquingKeysWith: { first, _ in first })
    }
}
