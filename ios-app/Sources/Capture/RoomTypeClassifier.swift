//
//  RoomTypeClassifier.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Guesses a room's type from a live or final CapturedRoom. Primary source
//  is RoomPlan's own classification (CapturedRoom.Section.label, iOS 17+,
//  confirmed via web research to ship as livingRoom/bedroom/bathroom/
//  kitchen/diningRoom — https://developer.apple.com/documentation/roomplan/
//  capturedroom/section/label-swift.enum). Falls back to a simple
//  fixture-based heuristic (a toilet means a bathroom, a bed means a
//  bedroom, ...) only when RoomPlan reported no sections at all — sections
//  are always preferred since they're Apple's own model output, not a guess
//  built on top of a guess. Shared by the live capture-screen prompt and the
//  final export so both use the exact same rule.
//

import RoomPlan

enum RoomTypeClassifier {
    struct Guess: Equatable {
        let type: String
        let source: String
    }

    static let allTypes = ["living_room", "bedroom", "bathroom", "kitchen", "dining_room"]

    static func displayName(for type: String) -> String {
        switch type {
        case "living_room": return "Living room"
        case "bedroom": return "Bedroom"
        case "bathroom": return "Bathroom"
        case "kitchen": return "Kitchen"
        case "dining_room": return "Dining room"
        case "other": return "Other"
        default: return "Room"
        }
    }

    // Checked in this order when falling back to objects — most distinctive
    // fixture first, so a bathroom (toilet) never gets mislabeled kitchen
    // just because it also has a small sink-like fixture. Keyed by string,
    // not CapturedRoom.Object.Category directly — RoomPlan's enum isn't
    // documented as Hashable, so this sidesteps that risk entirely.
    private static let objectHeuristics: [(categories: Set<String>, type: String)] = [
        (categories: ["toilet", "bathtub"], type: "bathroom"),
        (categories: ["stove", "oven", "dishwasher", "refrigerator"], type: "kitchen"),
        (categories: ["bed"], type: "bedroom"),
        (categories: ["sofa", "television"], type: "living_room"),
    ]

    static func guess(for room: CapturedRoom) -> Guess? {
        if let fromSections = guessFromSections(room.sections) {
            return fromSections
        }
        return guessFromObjects(room.objects)
    }

    private static func guessFromSections(_ sections: [CapturedRoom.Section]) -> Guess? {
        guard !sections.isEmpty else { return nil }
        // Tally labels rather than just taking sections.first — a room can
        // report more than one section, and the most-repeated label is a
        // steadier signal than whichever happened to be captured first.
        var counts: [String: Int] = [:]
        for section in sections {
            guard let label = mapSectionLabel(section.label) else { continue }
            counts[label, default: 0] += 1
        }
        guard let (topLabel, _) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Guess(type: topLabel, source: "roomplan_section")
    }

    private static func mapSectionLabel(_ label: CapturedRoom.Section.Label) -> String? {
        switch label {
        case .livingRoom: return "living_room"
        case .bedroom: return "bedroom"
        case .bathroom: return "bathroom"
        case .kitchen: return "kitchen"
        case .diningRoom: return "dining_room"
        @unknown default: return nil
        }
    }

    private static func guessFromObjects(_ objects: [CapturedRoom.Object]) -> Guess? {
        let seenCategories = Set(objects.map(mapObjectCategory))
        for rule in objectHeuristics {
            if !rule.categories.isDisjoint(with: seenCategories) {
                return Guess(type: rule.type, source: "object_heuristic")
            }
        }
        return nil
    }

    // Mirrors CapturedRoomExporter.mapObjectCategory's known-category list —
    // duplicated rather than shared across files since that one is private
    // to its own enum and this only needs the string, not the export shape.
    private static func mapObjectCategory(_ object: CapturedRoom.Object) -> String {
        switch object.category {
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .bed: return "bed"
        case .sink: return "sink"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .oven: return "oven"
        case .dishwasher: return "dishwasher"
        case .table: return "table"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        case .washerDryer: return "washerDryer"
        @unknown default: return "object"
        }
    }
}
