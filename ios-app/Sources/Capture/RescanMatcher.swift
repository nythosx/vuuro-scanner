import SwiftUI

struct RescanCandidate: Identifiable, Equatable {
    let roomId: String
    let name: String
    let floorAreaM2: Double
    var id: String { roomId }
}

struct PendingRescanChoice: Identifiable {
    let id = UUID()
    let candidates: [RescanCandidate]
}

enum RescanMatcher {
    static let areaTolerance = 0.20
    static let perimeterTolerance = 0.15

    static func candidates(
        areaM2: Double,
        perimeterM: Double,
        roomType: String?,
        floor: String?,
        existing: [FloorPlan.Room],
        excluding: Set<String> = []
    ) -> [RescanCandidate] {
        guard areaM2 > 0, perimeterM > 0 else { return [] }
        let wantedFloor = floorKey(floor)
        let matches = existing.filter { room in
            guard !excluding.contains(room.roomId), floorKey(room.floor) == wantedFloor else { return false }
            guard room.floorAreaM2 > 0, room.perimeterM > 0 else { return false }
            let areaOff = abs(areaM2 - room.floorAreaM2) / room.floorAreaM2
            let perimeterOff = abs(perimeterM - room.perimeterM) / room.perimeterM
            return areaOff <= areaTolerance && perimeterOff <= perimeterTolerance
        }
        let sorted = matches.sorted { lhs, rhs in
            let lhsSameType = roomType != nil && lhs.roomType?.confirmed == roomType
            let rhsSameType = roomType != nil && rhs.roomType?.confirmed == roomType
            if lhsSameType != rhsSameType {
                return lhsSameType
            }
            return abs(lhs.floorAreaM2 - areaM2) < abs(rhs.floorAreaM2 - areaM2)
        }
        return sorted.map { room in
            RescanCandidate(roomId: room.roomId, name: displayName(room), floorAreaM2: room.floorAreaM2)
        }
    }

    static func candidates(
        for export: RoomPlanCaptureExport,
        floor: String?,
        existing: [FloorPlan.Room],
        excluding: Set<String> = []
    ) -> [RescanCandidate] {
        candidates(
            areaM2: export.floorAreaM2,
            perimeterM: perimeter(of: export),
            roomType: export.roomType?.confirmed ?? export.roomType?.guess,
            floor: floor,
            existing: existing,
            excluding: excluding
        )
    }

    static func perimeter(of export: RoomPlanCaptureExport) -> Double {
        export.floors.reduce(0.0) { sum, floor in
            guard let corners = floor.polygonCorners, corners.count >= 3 else { return sum }
            var length = 0.0
            for index in corners.indices {
                let a = corners[index]
                let b = corners[(index + 1) % corners.count]
                guard a.count >= 3, b.count >= 3 else { continue }
                length += ((b[0] - a[0]) * (b[0] - a[0]) + (b[2] - a[2]) * (b[2] - a[2])).squareRoot()
            }
            return sum + length
        }
    }

    static func floorKey(_ floor: String?) -> String {
        (floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayName(_ room: FloorPlan.Room) -> String {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty, confirmed != "other" {
            return RoomTypeClassifier.displayName(for: confirmed)
        }
        return room.label
    }
}

struct RescanChoiceSheet: View {
    let choice: PendingRescanChoice
    let onReplace: (String) -> Void
    let onAddNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This looks like a room you already scanned")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(VuuroColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Replace it to keep one copy with its notes and photos, or add this scan as a new room. Nothing is removed unless you choose Replace.")
                .font(.system(size: 14))
                .foregroundStyle(VuuroColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(choice.candidates) { candidate in
                Button {
                    onReplace(candidate.roomId)
                } label: {
                    Text(String(format: vuuroLocalized("Replace %@ (%.1f m²)"), candidate.name, candidate.floorAreaM2))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vuuroOutlineSmall)
                .accessibilityIdentifier("rescan.replace.\(candidate.roomId)")
            }
            Button {
                onAddNew()
            } label: {
                Text("Add as a new room")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.vuuroPrimary)
            .accessibilityIdentifier("rescan.addNew")
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
    }
}
