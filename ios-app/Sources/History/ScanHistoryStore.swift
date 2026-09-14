
import Foundation

final class ScanHistoryStore {
    static let shared = ScanHistoryStore()

    private let defaults: UserDefaults
    private let key = "com.vuuro.scan.history"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [ScanHistoryEntry] {
        readRedacted()
            .map { entry in
                var entry = entry
                entry.accessToken = KeychainTokenStore.loadToken(forSessionId: entry.sessionId) ?? entry.accessToken
                return entry
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ entry: ScanHistoryEntry) {
        KeychainTokenStore.save(token: entry.accessToken, forSessionId: entry.sessionId)
        var redacted = entry
        redacted.accessToken = ""
        var entries = readRedacted()
        entries.removeAll { $0.sessionId == entry.sessionId }
        entries.append(redacted)
        save(entries)
    }

    func remove(sessionId: String) {
        KeychainTokenStore.deleteToken(forSessionId: sessionId)
        save(readRedacted().filter { $0.sessionId != sessionId })
    }

    func updateNickname(sessionId: String, nickname: String?) {
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        entries[index].nickname = nickname
        save(entries)
    }

    func updateRoomSummary(sessionId: String, summary: String?) {
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        entries[index].cachedRoomSummary = summary
        save(entries)
    }

    private func readRedacted() -> [ScanHistoryEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([ScanHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func save(_ entries: [ScanHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
