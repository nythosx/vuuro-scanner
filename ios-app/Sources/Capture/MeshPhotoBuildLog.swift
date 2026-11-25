import Foundation

enum MeshPhotoBuildLog {
    struct Stage: Codable, Equatable {
        let name: String
        let seconds: Double
    }

    struct Entry: Codable, Equatable {
        let finishedAt: Date
        let seconds: Double
        let outcome: Outcome
        let percentDone: Int
        let debugBuild: Bool
        let triangles: Int
        let photosUsed: Int
        let stages: [Stage]
        var photosLinedUp: Int? = nil
        var photosChecked: Int? = nil
        var photoLimit: Int? = nil
        var photosInTexture: Int? = nil
    }

    enum Outcome: String, Codable {
        case done
        case cancelled
        case failed
    }

    static let keyPrefix = "meshPhotoBuild."

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func key(_ capture: URL) -> String {
        keyPrefix + capture.lastPathComponent
    }

    static func save(_ entry: Entry, capture: URL, defaults: UserDefaults = .standard) -> Result<Void, Error> {
        do {
            defaults.set(try JSONEncoder().encode(entry), forKey: key(capture))
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func load(capture: URL, defaults: UserDefaults = .standard) -> Result<Entry?, Error> {
        guard let data = defaults.data(forKey: key(capture)) else { return .success(nil) }
        do {
            return .success(try JSONDecoder().decode(Entry.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    static func forget(capture: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(capture))
    }

    static func text(_ entry: Entry) -> String {
        var parts = [duration(entry.seconds), entry.debugBuild ? "Debug build" : "Release build"]
        switch entry.outcome {
        case .done:
            if let linedUp = entry.photosLinedUp, let checked = entry.photosChecked, let limit = entry.photoLimit, let inTexture = entry.photosInTexture {
                parts.append(countsText(linedUp: linedUp, checked: checked, chosen: entry.photosUsed, limit: limit, inTexture: inTexture))
                parts.append("\(entry.triangles) triangles")
            } else {
                parts.append("\(entry.photosUsed) photos, \(entry.triangles) triangles")
            }
        case .cancelled: parts.append("cancelled at \(entry.percentDone)%")
        case .failed: parts.append("failed at \(entry.percentDone)%")
        }
        return parts.joined(separator: ", ")
    }

    static func countsText(linedUp: Int, checked: Int, chosen: Int, limit: Int, inTexture: Int) -> String {
        "\(inTexture) of \(linedUp) lined up \(linedUp == 1 ? "photo" : "photos") really in the texture (\(checked) checked, \(chosen) chosen, limit \(limit) for this mesh and memory)"
    }

    static func stagesText(_ entry: Entry) -> String {
        entry.stages.map { "\($0.name) \(duration($0.seconds))" }.joined(separator: ", ")
    }

    static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return whole >= 60 ? "\(whole / 60) min \(whole % 60) s" : "\(whole) s"
    }
}
