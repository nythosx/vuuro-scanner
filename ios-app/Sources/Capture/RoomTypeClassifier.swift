
import RoomPlan

enum RoomTypeClassifier {
    struct Guess: Equatable {
        let type: String
        let source: String
    }

    static let allTypes = [
        "living_room", "bedroom", "bathroom", "kitchen", "dining_room",
        "hallway", "office", "garage", "laundry_room", "storage_room",
        "balcony", "basement", "attic", "walk_in_closet", "guest_room",
    ]

    static func displayName(for type: String) -> String {
        switch type {
        case "living_room": return "Living room"
        case "bedroom": return "Bedroom"
        case "bathroom": return "Bathroom"
        case "kitchen": return "Kitchen"
        case "dining_room": return "Dining room"
        case "hallway": return "Hallway"
        case "office": return "Office"
        case "garage": return "Garage"
        case "laundry_room": return "Laundry room"
        case "storage_room": return "Storage room"
        case "balcony": return "Balcony"
        case "basement": return "Basement"
        case "attic": return "Attic"
        case "walk_in_closet": return "Walk-in closet"
        case "guest_room": return "Guest room"
        case "other": return "Other"
        default: return type
        }
    }

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
