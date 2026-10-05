import Foundation

struct PendingUploadState: Codable {
    var session: ScanSessionResponse?
    let identity: ScanIdentity
    var captures: [PendingCapture]
    var skippedAt: Date? = nil
    var pendingRescan: StoredRescanChoice? = nil

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
        let url = fileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    static func load() -> PendingUploadState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PendingUploadState.self, from: data)
    }

    static func markSkipped() {
        guard var state = load() else { return }
        state.skippedAt = Date()
        save(state)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
