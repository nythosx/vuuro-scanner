import Foundation

struct WalkthroughState: Codable {
    let identity: ScanIdentity
    var session: ScanSessionResponse?
    var rooms: [StoredRoom]
    var startedAt: Date

    struct StoredRoom: Codable {
        let exportJSON: Data
        let floor: String?
        let label: String
    }
}

enum WalkthroughStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VuuroScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("walkthrough.json")
    }

    static func save(_ state: WalkthroughState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> WalkthroughState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WalkthroughState.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
