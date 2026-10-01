import ARKit
import Foundation

@MainActor
final class WorldMapStore {
    static let shared = WorldMapStore()
    static let maxMapsTotal = 5
    static let mapExtension = "arworldmap"

    private let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("WorldMaps", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func save(_ map: ARWorldMap, sessionId: String, groupId: String) -> Result<URL, Error> {
        let url = fileURL(sessionId: sessionId, groupId: groupId)
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            prune(keeping: Self.maxMapsTotal)
            DiagnosticsLog.shared.record("World map saved for \(sessionId)/\(groupId) (\(data.count) bytes)", category: .info)
            return .success(url)
        } catch {
            DiagnosticsLog.shared.record("World map save failed: \(error.localizedDescription)", category: .error)
            return .failure(error)
        }
    }

    func saveFile(sessionId: String, groupId: String, data: Data) -> Result<URL, Error> {
        let url = fileURL(sessionId: sessionId, groupId: groupId)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            prune(keeping: Self.maxMapsTotal)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    func load(sessionId: String, groupId: String) -> ARWorldMap? {
        let url = fileURL(sessionId: sessionId, groupId: groupId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                DiagnosticsLog.shared.record("World map decode returned nil for \(sessionId)/\(groupId)", category: .error)
                return nil
            }
            return map
        } catch {
            DiagnosticsLog.shared.record("World map load failed: \(error.localizedDescription)", category: .error)
            return nil
        }
    }

    func latestMap(sessionId: String, groupIds: [String]) -> ARWorldMap? {
        var best: (Date, ARWorldMap)?
        for groupId in groupIds {
            let url = fileURL(sessionId: sessionId, groupId: groupId)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            if let existing = best, existing.0 >= date { continue }
            if let data = try? Data(contentsOf: url),
               let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                best = (date, map)
            }
        }
        return best?.1
    }

    func deleteAll(sessionId: String) {
        let prefix = "\(sessionId)_"
        for url in allFiles() where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    func delete(sessionId: String, groupId: String) {
        try? fileManager.removeItem(at: fileURL(sessionId: sessionId, groupId: groupId))
    }

    func allFiles() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func fileURL(sessionId: String, groupId: String) -> URL {
        let safeSession = sessionId.replacingOccurrences(of: "/", with: "_")
        let safeGroup = groupId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safeSession)_\(safeGroup).\(Self.mapExtension)")
    }

    private func prune(keeping: Int) {
        let files = allFiles()
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        guard files.count > keeping else { return }
        for (url, _) in files.dropFirst(keeping) {
            try? fileManager.removeItem(at: url)
        }
    }
}
