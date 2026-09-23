import Foundation

enum ExportNaming {
    static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(mapped)
        let collapsed = joined.split(separator: "_").joined(separator: "_")
        return collapsed.isEmpty ? "Untitled" : collapsed
    }

    static func fileName(
        property: String,
        unit: String,
        room: String?,
        date: Date,
        suffix: String,
        ext: String
    ) -> String {
        var parts: [String] = [slug(property), slug(unit)]
        if let room, !room.isEmpty { parts.append(slug(room)) }
        parts.append(dateFormatter.string(from: date))
        parts.append(slug(suffix))
        return parts.joined(separator: "_") + "." + ext
    }

    static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    static func directory(sessionId: String) -> URL {
        rootDirectory.appendingPathComponent(slug(sessionId), isDirectory: true)
    }

    static func removeExports(sessionId: String) {
        try? FileManager.default.removeItem(at: directory(sessionId: sessionId))
    }

    static func url(
        sessionId: String,
        property: String,
        unit: String,
        room: String?,
        date: Date,
        suffix: String,
        ext: String
    ) throws -> URL {
        let folder = directory(sessionId: sessionId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(
            fileName(property: property, unit: unit, room: room, date: date, suffix: suffix, ext: ext)
        )
    }
}
