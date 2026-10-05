import Foundation

protocol RoomSummarySource {
    var label: String { get }
    var floor: String? { get }
    var floorAreaM2: Double { get }
    var roomType: FloorPlan.RoomType? { get }
}

extension FloorPlan.Room: RoomSummarySource {}

enum RoomSummary {
    static func text<Room: RoomSummarySource>(for rooms: [Room]) -> String? {
        guard !rooms.isEmpty else { return nil }
        let labels = rooms.map { displayLabel(for: $0) }
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

    private static func displayLabel(for room: some RoomSummarySource) -> String {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
            return confirmed == "other" ? room.label : RoomTypeClassifier.displayName(for: confirmed)
        }
        if let guess = room.roomType?.guess, !guess.isEmpty {
            return RoomTypeClassifier.displayName(for: guess)
        }
        return room.label
    }
}