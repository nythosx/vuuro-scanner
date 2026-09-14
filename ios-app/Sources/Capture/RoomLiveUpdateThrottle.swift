
import Foundation

final class RoomLiveUpdateThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdateAt: Date = .distantPast
    private var isAnswered = false
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.15) {
        self.interval = interval
    }

    func shouldProcessUpdate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastUpdateAt) >= interval else { return false }
        lastUpdateAt = now
        return true
    }

    func isRoomTypeAnswered() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAnswered
    }

    func markRoomTypeAnswered() {
        lock.lock()
        isAnswered = true
        lock.unlock()
    }

    func resetRoomTypeAnswered() {
        lock.lock()
        isAnswered = false
        lock.unlock()
    }
}
