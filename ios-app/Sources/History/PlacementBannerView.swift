import SwiftUI

struct PlacementTarget: Identifiable {
    let floor: String?
    let movingGroupId: String
    var id: String { "\(floor ?? "__none__")|\(movingGroupId)" }
}

struct PlacementBannerView: View {
    let rooms: [FloorPlan.Room]
    let onPlace: (PlacementTarget) -> Void

    private var unjoinedTargets: [PlacementTarget] {
        let fused = rooms.filter { $0.captureGroupId != nil && $0.structureOriginM != nil }
        let byFloor = Dictionary(grouping: fused) { ($0.floor ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        return byFloor.compactMap { floorKey, floorRooms -> PlacementTarget? in
            let blocks = Dictionary(grouping: floorRooms) { $0.joinedToGroupId ?? $0.captureGroupId ?? "" }
            let keys = blocks.keys.filter { !$0.isEmpty }
            guard keys.count >= 2 else { return nil }
            let newest = keys.max { a, b in
                let ai = floorRooms.lastIndex { ($0.joinedToGroupId ?? $0.captureGroupId) == a } ?? 0
                let bi = floorRooms.lastIndex { ($0.joinedToGroupId ?? $0.captureGroupId) == b } ?? 0
                return ai < bi
            } ?? keys[0]
            let realFloor = floorKey.isEmpty ? nil : floorRooms.first?.floor
            return PlacementTarget(floor: realFloor, movingGroupId: newest)
        }
    }

    private var joinedTargets: [PlacementTarget] {
        let joinedRooms = rooms.filter {
            $0.joinedToGroupId != nil && $0.captureGroupId != nil && $0.structureOriginM != nil
        }
        var seen = Set<String>()
        var result: [PlacementTarget] = []
        for room in joinedRooms {
            guard let movingId = room.captureGroupId else { continue }
            let floorKey = (room.floor ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let key = "\(floorKey)|\(movingId)"
            if !seen.insert(key).inserted { continue }
            let realFloor = floorKey.isEmpty ? nil : room.floor
            result.append(PlacementTarget(floor: realFloor, movingGroupId: movingId))
        }
        return result
    }

    var body: some View {
        let unjoined = unjoinedTargets
        let joined = joinedTargets
        if !unjoined.isEmpty || !joined.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !unjoined.isEmpty {
                    Text(vuuroLocalized("These rooms aren't joined to the plan yet"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VuuroColor.textPrimary)
                    ForEach(unjoined) { target in
                        Button(target.floor.map { String(format: vuuroLocalized("Place rooms on %@"), $0) } ?? vuuroLocalized("Place the rooms you added")) {
                            onPlace(target)
                        }
                        .accessibilityIdentifier("placementBanner.place.\(target.id)")
                        .buttonStyle(.vuuroOutlineSmall)
                    }
                }
                if !joined.isEmpty {
                    Text(vuuroLocalized("Adjust placement"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VuuroColor.textPrimary)
                    ForEach(joined) { target in
                        Button(target.floor.map { String(format: vuuroLocalized("Adjust rooms on %@"), $0) } ?? vuuroLocalized("Adjust the rooms you added")) {
                            onPlace(target)
                        }
                        .accessibilityIdentifier("placementBanner.adjust.\(target.id)")
                        .buttonStyle(.vuuroOutlineSmall)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}
