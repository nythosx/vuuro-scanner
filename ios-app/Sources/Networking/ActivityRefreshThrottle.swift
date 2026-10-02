import Foundation

struct ActivityRefreshThrottle {
    let interval: TimeInterval
    private(set) var lastRefreshAt: Date?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    mutating func shouldRefresh(now: Date) -> Bool {
        if let last = lastRefreshAt, now.timeIntervalSince(last) < interval {
            return false
        }
        lastRefreshAt = now
        return true
    }
}
