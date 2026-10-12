import Foundation

@MainActor
final class FloorPlanImageCache {
    static let shared = FloorPlanImageCache()

    private let entries: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 40
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()
    private var knownKeys: Set<String> = []
    private var inFlightTasks: [String: Task<Data?, Never>] = [:]
    private var lastErrors: [String: Error] = [:]
    private var generations: [String: Int] = [:]

    private init() {}

    private func key(sessionId: String, unit: MeasurementUnit) -> String {
        "\(sessionId)|\(unit.rawValue)|\(AppLanguageSettings.exportLanguageCode)"
    }

    @discardableResult
    func prefetch(sessionId: String, accessToken: String, unit: MeasurementUnit, client: ScanServiceClient) -> Task<Data?, Never> {
        let cacheKey = key(sessionId: sessionId, unit: unit)
        if let existing = inFlightTasks[cacheKey] {
            return existing
        }
        if let cached = entries.object(forKey: cacheKey as NSString) {
            return Task { cached as Data }
        }
        let task = Task<Data?, Never> {
            let capturedGeneration = self.generations[sessionId, default: 0]
            let data: Data?
            do {
                data = try await client.fetchFloorPlanImage(sessionId: sessionId, accessToken: accessToken, unit: unit)
                if !Task.isCancelled {
                    self.lastErrors[cacheKey] = nil
                }
            } catch is CancellationError {
                if capturedGeneration == self.generations[sessionId, default: 0] {
                    self.inFlightTasks[cacheKey] = nil
                }
                return nil
            } catch {
                DiagnosticsLog.shared.record("Floor plan image prefetch failed for session \(sessionId): \(error.localizedDescription)", category: .error)
                data = nil
                if !Task.isCancelled {
                    self.lastErrors[cacheKey] = error
                }
            }
            guard !Task.isCancelled else {
                if capturedGeneration == self.generations[sessionId, default: 0] {
                    self.inFlightTasks[cacheKey] = nil
                }
                return nil
            }
            guard capturedGeneration == self.generations[sessionId, default: 0] else {
                return nil
            }
            if let data {
                self.entries.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
                self.knownKeys.insert(cacheKey)
            }
            self.inFlightTasks[cacheKey] = nil
            return data
        }
        inFlightTasks[cacheKey] = task
        return task
    }

    func cachedData(sessionId: String, unit: MeasurementUnit) -> Data? {
        entries.object(forKey: key(sessionId: sessionId, unit: unit) as NSString) as Data?
    }

    func lastError(sessionId: String, unit: MeasurementUnit) -> Error? {
        lastErrors[key(sessionId: sessionId, unit: unit)]
    }

    func invalidate(sessionId: String) {
        generations[sessionId, default: 0] += 1
        let prefix = "\(sessionId)|"
        for cacheKey in knownKeys where cacheKey.hasPrefix(prefix) {
            entries.removeObject(forKey: cacheKey as NSString)
        }
        knownKeys = knownKeys.filter { !$0.hasPrefix(prefix) }
        for (cacheKey, task) in inFlightTasks where cacheKey.hasPrefix(prefix) {
            task.cancel()
        }
        inFlightTasks = inFlightTasks.filter { !$0.key.hasPrefix(prefix) }
        lastErrors = lastErrors.filter { !$0.key.hasPrefix(prefix) }
    }

    func clearAll() {
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        entries.removeAllObjects()
        knownKeys.removeAll()
        inFlightTasks.removeAll()
        lastErrors.removeAll()
    }
}