import SwiftUI

struct RescanCandidate: Identifiable, Equatable, Codable {
    let roomId: String
    let name: String
    let floorAreaM2: Double
    var id: String { roomId }
}

struct PendingRescanChoice: Identifiable {
    let id = UUID()
    let candidates: [RescanCandidate]
}

struct StoredRescanChoice: Codable, Equatable {
    let roomIndex: Int
    let candidates: [RescanCandidate]
}

enum RescanResume {
    static let staleReplaceCodes: Set<String> = ["unknown_room_id", "replace_floor_mismatch"]
    static let addedAsNewNotice = "The room this scan was replacing has changed, so it was added as a new room."

    static func isStaleReplace(_ error: Error) -> Bool {
        guard let code = (error as? ScanServiceError)?.serverCode else { return false }
        return staleReplaceCodes.contains(code)
    }

    static func replacesRoomId(in bodyJSON: Data) -> String? {
        guard let body = (try? JSONSerialization.jsonObject(with: bodyJSON)) as? [String: Any],
              let rawCapture = body["raw_capture"] as? [String: Any] else { return nil }
        return rawCapture["replaces_room_id"] as? String
    }

    static func captureBody(_ bodyJSON: Data, replacing roomId: String?) -> Data? {
        guard var body = (try? JSONSerialization.jsonObject(with: bodyJSON)) as? [String: Any],
              var rawCapture = body["raw_capture"] as? [String: Any] else { return nil }
        if let roomId {
            rawCapture["replaces_room_id"] = roomId
        } else {
            rawCapture.removeValue(forKey: "replaces_room_id")
        }
        body["raw_capture"] = rawCapture
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func exportJSON(_ exportJSON: Data, replacing roomId: String?) -> Data? {
        guard var export = try? JSONDecoder().decode(RoomPlanCaptureExport.self, from: exportJSON) else { return nil }
        export.replacesRoomId = roomId
        return try? JSONEncoder().encode(export)
    }
}

extension PendingUploadState {
    func resolvingRescan(replacing roomId: String?) -> PendingUploadState {
        var state = self
        state.pendingRescan = nil
        guard let choice = pendingRescan, captures.indices.contains(choice.roomIndex) else { return state }
        let capture = captures[choice.roomIndex]
        guard let body = RescanResume.captureBody(capture.bodyJSON, replacing: roomId) else { return state }
        state.captures[choice.roomIndex] = PendingCapture(idempotencyKey: UUID().uuidString, bodyJSON: body)
        return state
    }
}

extension WalkthroughState {
    func resolvingRescan(replacing roomId: String?) -> WalkthroughState {
        var state = self
        state.pendingRescan = nil
        guard let choice = pendingRescan, rooms.indices.contains(choice.roomIndex) else { return state }
        let room = rooms[choice.roomIndex]
        guard let data = RescanResume.exportJSON(room.exportJSON, replacing: roomId) else { return state }
        state.rooms[choice.roomIndex] = StoredRoom(exportJSON: data, floor: room.floor, label: room.label)
        return state
    }
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
