import Foundation

enum RoomSummary {
    static func text(for rooms: [FloorPlan.Room]) -> String? {
        guard !rooms.isEmpty else { return nil }
        let labels = rooms.map(displayLabel)
        if labels.count == 1 {
            return labels[0]
        }
        let shown = labels.prefix(3).joined(separator: ", ")
        return labels.count > 3 ? "\(shown), +\(labels.count - 3) more" : shown
    }

    static func pills(for summary: String?) -> (labels: [String], more: Int) {
        guard let summary, !summary.isEmpty else { return ([], 0) }
        let parts = summary.components(separatedBy: ", ")
        var labels: [String] = []
        var more = 0
        for part in parts {
            if part.hasPrefix("+"), part.hasSuffix(" more") {
                let countString = part
                    .dropFirst()
                    .dropLast(" more".count)
                more = Int(countString) ?? 0
            } else {
                labels.append(part)
            }
        }
        return (labels, more)
    }

    private static func displayLabel(for room: FloorPlan.Room) -> String {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
            return RoomTypeClassifier.displayName(for: confirmed)
        }
        if let guess = room.roomType?.guess, !guess.isEmpty {
            return RoomTypeClassifier.displayName(for: guess)
        }
        return room.label
    }
}