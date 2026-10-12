
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
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func add(_ entry: ScanHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        var redacted = entry
        if entry.accessToken.isEmpty || KeychainTokenStore.save(token: entry.accessToken, forSessionId: entry.sessionId) {
            redacted.accessToken = ""
        } else {
            DiagnosticsLog.shared.record("Keeping the access token for session \(entry.sessionId) in local history because the Keychain refused it", category: .error)
        }
        var entries = readRedacted()
        if let existing = entries.first(where: { $0.sessionId == entry.sessionId }), let existingCapture = existing.lastCapturedAt {
            redacted.lastCapturedAt = max(existingCapture, redacted.lastCapturedAt ?? existingCapture)
        }
        entries.removeAll { $0.sessionId == entry.sessionId }
        entries.append(redacted)
        save(entries)
    }

    func remove(sessionId: String) {
        Task { @MainActor in WorldMapStore.shared.deleteAll(sessionId: sessionId) }
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

    func markCaptured(sessionId: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        if let existing = entries[index].lastCapturedAt, existing >= date { return }
        entries[index].lastCapturedAt = date
        save(entries)
    }

    @discardableResult
    func applyServerActivity(_ results: [SessionActivityEntry]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var entries = readRedacted()
        var changed = false
        for result in results {
            guard let index = entries.firstIndex(where: { $0.sessionId == result.id }) else { continue }
            if let date = Self.parseServerDate(result.capturedAt), entries[index].lastCapturedAt.map({ $0 < date }) ?? true {
                entries[index].lastCapturedAt = date
                changed = true
            }
            guard let rooms = result.rooms else { continue }
            let summary = RoomSummary.text(for: rooms)
            let area = rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
            let byFloor = CachedFloorSummary.buckets(from: rooms)
            if entries[index].cachedRoomSummary != summary {
                entries[index].cachedRoomSummary = summary
                changed = true
            }
            if entries[index].cachedFloorAreaM2 != area {
                entries[index].cachedFloorAreaM2 = area
                changed = true
            }
            if entries[index].cachedRoomsByFloor != byFloor {
                entries[index].cachedRoomsByFloor = byFloor
                changed = true
            }
        }
        if changed {
            save(entries)
        }
        return changed
    }

    func noteServerCapture(sessionId: String, capturedAt: String) {
        guard let date = Self.parseServerDate(capturedAt) else { return }
        markCaptured(sessionId: sessionId, at: date)
    }

    static func parseServerDate(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    func updateRoomsByFloor(sessionId: String, roomsByFloor: [String: CachedFloorSummary]?) {
        lock.lock()
        defer { lock.unlock() }
        var entries = readRedacted()
        guard let index = entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        guard entries[index].cachedRoomsByFloor != roomsByFloor else { return }
        entries[index].cachedRoomsByFloor = roomsByFloor
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
