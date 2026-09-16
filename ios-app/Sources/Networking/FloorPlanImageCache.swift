
import Foundation

@MainActor
final class FloorPlanImageCache {
    static let shared = FloorPlanImageCache()

    private var entries: [String: Data] = [:]
    private var inFlightTasks: [String: Task<Data?, Never>] = [:]
    private var lastErrors: [String: Error] = [:]

    private init() {}

    private func key(sessionId: String, unit: MeasurementUnit) -> String {
        "\(sessionId)|\(unit.rawValue)"
    }

    /// Fire-and-forget prefetch — callers who don't need the result (just
    /// want to warm the cache early) can ignore the returned Task.
    @discardableResult
    func prefetch(sessionId: String, accessToken: String, unit: MeasurementUnit, client: ScanServiceClient) -> Task<Data?, Never> {
        let cacheKey = key(sessionId: sessionId, unit: unit)
        if let existing = inFlightTasks[cacheKey] {
            return existing
        }
        if let cached = entries[cacheKey] {
            return Task { cached }
        }
        let task = Task<Data?, Never> {
            let data: Data?
            do {
                data = try await client.fetchFloorPlanImage(sessionId: sessionId, accessToken: accessToken, unit: unit)
                self.lastErrors[cacheKey] = nil
            } catch {
                DiagnosticsLog.shared.record("Floor plan image prefetch failed for session \(sessionId): \(error.localizedDescription)", category: .error)
                data = nil
                self.lastErrors[cacheKey] = error
            }
            if let data {
                self.entries[cacheKey] = data
            }
            self.inFlightTasks[cacheKey] = nil
            return data
        }
        inFlightTasks[cacheKey] = task
        return task
    }

    func cachedData(sessionId: String, unit: MeasurementUnit) -> Data? {
        entries[key(sessionId: sessionId, unit: unit)]
    }

    func lastError(sessionId: String, unit: MeasurementUnit) -> Error? {
        lastErrors[key(sessionId: sessionId, unit: unit)]
    }

    func invalidate(sessionId: String) {
        let prefix = "\(sessionId)|"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        inFlightTasks = inFlightTasks.filter { !$0.key.hasPrefix(prefix) }
        lastErrors = lastErrors.filter { !$0.key.hasPrefix(prefix) }
    }
}
