import Foundation

struct PendingUploadState: Codable {
    var session: ScanSessionResponse?
    let identity: ScanIdentity
    var captures: [PendingCapture]

    struct PendingCapture: Codable {
        let idempotencyKey: String
        let bodyJSON: Data
    }
}

enum PendingUploadStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VuuroScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_upload.json")
    }

    static func save(_ state: PendingUploadState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> PendingUploadState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PendingUploadState.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
