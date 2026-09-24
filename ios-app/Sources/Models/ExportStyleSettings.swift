import Foundation

enum ExportPlanType: String, CaseIterable, Identifiable {
    case fullReport = "full_report"
    case listingPlan = "listing_plan"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullReport: return "Full report"
        case .listingPlan: return "Listing plan"
        }
    }

    var explanation: String {
        switch self {
        case .fullReport: return "Plan with measurements, notes and missing items. Use this for inspections and your own records."
        case .listingPlan: return "Clean plan for a property listing: white rooms, dimension lines, no furniture, walk path or notes."
        }
    }
}

struct ExportStyleSettings: Equatable {
    var planType: ExportPlanType
    var showWalkPath: Bool
    var showFurniture: Bool
    var furnitureCategories: Set<String>
    var orientation: String
    var roomFill: String

    private enum Keys {
        static let planType = "exportStyle.planType"
        static let showWalkPath = "exportStyle.showWalkPath"
        static let showFurniture = "exportStyle.showFurniture"
        static let furnitureCategories = "exportStyle.furnitureCategories"
        static let orientation = "exportStyle.orientation"
        static let roomFill = "exportStyle.roomFill"
    }

    static let allFurnitureCategories: [String] = [
        "bed", "sofa", "chair", "table", "desk",
        "television", "storage", "other",
        "sink", "toilet", "bathtub", "stove", "oven",
        "dishwasher", "refrigerator", "fireplace", "stairs", "washerDryer",
    ]

    private static let labels: [String: String] = [
        "bed": "Bed",
        "sofa": "Sofa",
        "chair": "Chair",
        "table": "Table",
        "desk": "Desk",
        "television": "TV",
        "storage": "Storage",
        "other": "Other",
        "sink": "Sink",
        "toilet": "Toilet",
        "bathtub": "Bathtub",
        "stove": "Stove",
        "oven": "Oven",
        "dishwasher": "Dishwasher",
        "refrigerator": "Fridge",
        "fireplace": "Fireplace",
        "stairs": "Stairs",
        "washerDryer": "Washer/Dryer",
    ]

    static func furnitureLabel(for category: String) -> String {
        labels[category] ?? category.capitalized
    }

    static func load() -> ExportStyleSettings {
        let d = UserDefaults.standard
        let storedCats = d.stringArray(forKey: Keys.furnitureCategories)
        let cats = Set(storedCats ?? allFurnitureCategories)
        return ExportStyleSettings(
            planType: d.string(forKey: Keys.planType).flatMap(ExportPlanType.init(rawValue:)) ?? .fullReport,
            showWalkPath: d.object(forKey: Keys.showWalkPath) as? Bool ?? true,
            showFurniture: d.object(forKey: Keys.showFurniture) as? Bool ?? true,
            furnitureCategories: cats,
            orientation: d.string(forKey: Keys.orientation) ?? "as_captured",
            roomFill: d.string(forKey: Keys.roomFill) ?? "default"
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(planType.rawValue, forKey: Keys.planType)
        d.set(showWalkPath, forKey: Keys.showWalkPath)
        d.set(showFurniture, forKey: Keys.showFurniture)
        d.set(Array(furnitureCategories), forKey: Keys.furnitureCategories)
        d.set(orientation, forKey: Keys.orientation)
        d.set(roomFill, forKey: Keys.roomFill)
    }

    var furnitureQueryValue: String {
        if !showFurniture { return "none" }
        if furnitureCategories.isEmpty { return "none" }
        if furnitureCategories.count >= Self.allFurnitureCategories.count { return "all" }
        return furnitureCategories.sorted().joined(separator: ",")
    }

    var queryItems: [URLQueryItem] {
        if planType == .listingPlan {
            return [URLQueryItem(name: "style", value: "funda")]
        }
        return [
            URLQueryItem(name: "walk_path", value: showWalkPath ? "1" : "0"),
            URLQueryItem(name: "furniture", value: furnitureQueryValue),
            URLQueryItem(name: "orientation", value: orientation),
            URLQueryItem(name: "room_fill", value: roomFill),
        ]
    }
}
