import Foundation

struct RoomDraft: Codable, Equatable {
    var label: String
    var note: String
    var noteTags: [String]
    var savedNoteId: String?
}

struct SessionNoteDraft: Codable, Equatable {
    var note: String
    var noteTags: [String]
    var savedNoteId: String?
}

struct SessionDrafts: Codable {
    var rooms: [String: RoomDraft] = [:]
    var sessionNote: SessionNoteDraft? = nil

    var isEmpty: Bool {
        rooms.isEmpty && sessionNote == nil
    }
}

enum DraftStore {
    private static let lock = NSLock()
    private static let ioQueue = DispatchQueue(label: "vuuro.draftstore.io", qos: .utility)
    private static var cache: [String: SessionDrafts] = [:]

    private static var draftsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VuuroScan", isDirectory: true)
            .appendingPathComponent("drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(sessionId: String) -> URL {
        draftsDir.appendingPathComponent("\(sessionId).json")
    }

    static func drafts(for sessionId: String) -> SessionDrafts {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[sessionId] { return cached }
        if let data = try? Data(contentsOf: fileURL(sessionId: sessionId)),
           let decoded = try? JSONDecoder().decode(SessionDrafts.self, from: data) {
            cache[sessionId] = decoded
            return decoded
        }
        let empty = SessionDrafts()
        cache[sessionId] = empty
        return empty
    }

    static func save(_ drafts: SessionDrafts, sessionId: String) {
        lock.lock()
        cache[sessionId] = drafts
        lock.unlock()

        let url = fileURL(sessionId: sessionId)
        let snapshot = drafts
        if snapshot.isEmpty {
            ioQueue.async {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func clearRoom(sessionId: String, roomId: String) {
        var d = drafts(for: sessionId)
        d.rooms.removeValue(forKey: roomId)
        save(d, sessionId: sessionId)
    }

    static func clearSessionNote(sessionId: String) {
        var d = drafts(for: sessionId)
        d.sessionNote = nil
        save(d, sessionId: sessionId)
    }

    static func clearAll(sessionId: String) {
        lock.lock()
        cache.removeValue(forKey: sessionId)
        lock.unlock()
        let url = fileURL(sessionId: sessionId)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
