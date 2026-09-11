
import Foundation

@MainActor
final class FloorPlanImageCache {
    static let shared = FloorPlanImageCache()

    private var entries: [String: Data] = [:]
    private var inFlightTasks: [String: Task<Data?, Never>] = [:]

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
            } catch {
                DiagnosticsLog.shared.record("Floor plan image prefetch failed for session \(sessionId): \(error.localizedDescription)", category: .error)
                data = nil
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
}
