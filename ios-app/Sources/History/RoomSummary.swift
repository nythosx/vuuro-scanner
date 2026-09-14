
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

    private static func displayLabel(for room: FloorPlan.Room) -> String {
        let type = room.roomType?.confirmed ?? room.roomType?.guess
        if let type, !type.isEmpty {
            return "\(room.label) (\(type))"
        }
        return room.label
    }
}
