
import Foundation

final class ScanHistoryStore {
    static let shared = ScanHistoryStore()

    private let defaults: UserDefaults
    private let key = "com.vuuro.scan.history"
    private let corruptedBackupKey = "com.vuuro.scan.history.corrupted-backup"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [ScanHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let entries = readRedacted()
        return entries
            .map { entry in
                var entry = entry
                entry.accessToken = KeychainTokenStore.loadToken(forSessionId: entry.sessionId) ?? entry.accessToken
                return entry
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ entry: ScanHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        KeychainTokenStore.save(token: entry.accessToken, forSessionId: entry.sessionId)
        var redacted = entry
        redacted.accessToken = ""
        var entries = readRedacted()
        entries.removeAll { $0.sessionId == entry.sessionId }
        entries.append(redacted)
        save(entries)
    }

    func remove(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        KeychainTokenStore.deleteToken(forSessionId: sessionId)
        save(readRedacted().filter { $0.sessionId != sessionId })
    }

    func updateNickname(sessionId: String, nickname: String?) {
        lock.lock()
        defer { lock.unlock() }
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        entries[index].nickname = nickname
        save(entries)
    }

    func updateFloor(sessionId: String, floor: String?) {
        lock.lock()
        defer { lock.unlock() }
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        entries[index].floor = floor
        save(entries)
    }

    func updateRoomSummary(sessionId: String, summary: String?, floorAreaM2: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        entries[index].cachedRoomSummary = summary
        if let floorAreaM2 {
            entries[index].cachedFloorAreaM2 = floorAreaM2
        }
        save(entries)
    }

    private func readRedacted() -> [ScanHistoryEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let entries = try? JSONDecoder().decode([ScanHistoryEntry].self, from: data) else {
            defaults.set(data, forKey: corruptedBackupKey)
            defaults.removeObject(forKey: key)
            DiagnosticsLog.shared.record("Scan history blob failed to decode — backed up under \(corruptedBackupKey) and cleared", category: .error)
            return []
        }
        return entries
    }

    private func save(_ entries: [ScanHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
