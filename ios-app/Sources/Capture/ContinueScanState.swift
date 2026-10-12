import Foundation

struct ContinueScanState: Equatable {
    enum Phase: Equatable {
        case notContinuing
        case lookingForMap
        case noMapOnPhone
        case relocalizing
        case notRecognised
        case scanningJoined
        case scanningSeparate
    }

    enum Event: Equatable {
        case notAContinue
        case targetFound(String)
        case mapFound
        case noMap
        case noMapAcknowledged
        case recognised
        case timedOut
        case unavailable
        case captureFailedAfterRelocalize
        case skip
        case retry
    }

    enum Effect: Equatable {
        case startScanning(afterRelocalization: Bool)
        case lookForMap
        case startRelocalizing
        case cancelRelocalization
    }

    private(set) var phase: Phase = .notContinuing
    private(set) var targetGroupId: String?

    var joinTargetGroupId: String? {
        phase == .scanningJoined ? targetGroupId : nil
    }

    var showsRelocalizeOverlay: Bool {
        phase == .relocalizing || phase == .notRecognised
    }

    var showsNoMapNotice: Bool {
        phase == .noMapOnPhone
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.notContinuing, .notAContinue):
            phase = .scanningSeparate
            return [.startScanning(afterRelocalization: false)]
        case (.notContinuing, .targetFound(let groupId)):
            targetGroupId = groupId
            phase = .lookingForMap
            return [.lookForMap]
        case (.lookingForMap, .mapFound):
            phase = .relocalizing
            return [.startRelocalizing]
        case (.lookingForMap, .noMap):
            phase = .noMapOnPhone
            return []
        case (.noMapOnPhone, .noMapAcknowledged):
            phase = .scanningSeparate
            return [.startScanning(afterRelocalization: false)]
        case (.relocalizing, .recognised):
            phase = .scanningJoined
            return [.startScanning(afterRelocalization: true)]
        case (.relocalizing, .timedOut), (.relocalizing, .unavailable):
            phase = .notRecognised
            return []
        case (.scanningJoined, .captureFailedAfterRelocalize):
            phase = .notRecognised
            return []
        case (.relocalizing, .skip), (.notRecognised, .skip):
            phase = .scanningSeparate
            return [.cancelRelocalization, .startScanning(afterRelocalization: false)]
        case (.notRecognised, .retry):
            phase = .lookingForMap
            return [.cancelRelocalization, .lookForMap]
        default:
            return []
        }
    }
}

enum ContinueRoute {
    static func floorKey(_ floor: String?) -> String {
        (floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func wholeUnitRooms(in rooms: [FloorPlan.Room], floor: String?) -> [FloorPlan.Room] {
        let wanted = floorKey(floor)
        return rooms.filter { room in
            room.captureGroupId != nil && room.structureOriginM != nil && floorKey(room.floor) == wanted
        }
    }

    static func continuesAsUnit(rooms: [FloorPlan.Room], floor: String?) -> Bool {
        !wholeUnitRooms(in: rooms, floor: floor).isEmpty
    }

    static func joinTarget(rooms: [FloorPlan.Room], floor: String?) -> String? {
        let candidates = wholeUnitRooms(in: rooms, floor: floor)
        if let root = candidates.compactMap(\.joinedToGroupId).first {
            return root
        }
        return candidates.last?.captureGroupId
    }

    static func mapGroupIds(rooms: [FloorPlan.Room], floor: String?) -> [String] {
        var ids: [String] = []
        for room in wholeUnitRooms(in: rooms, floor: floor) {
            for id in [room.captureGroupId, room.joinedToGroupId].compactMap({ $0 }) where !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }
}
