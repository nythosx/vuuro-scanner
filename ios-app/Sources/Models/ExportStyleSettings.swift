import Foundation

enum ExportPlanType: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case listingPlan = "listing_plan"
    case fullReport = "full_report"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .fullReport: return "Full report"
        case .listingPlan: return "Listing plan"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: return "Uses the plan your admin chose for each scan purpose: Listing plan or Full report."
        case .fullReport: return "Plan with measurements, notes and missing items. Use this for inspections and your own records."
        case .listingPlan: return "Clean plan for a property listing: color-coded rooms, dimension lines and fixed fixtures like sink, toilet and stove. No loose furniture, walk path or notes."
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
        static let defaultsVersion = "exportStyle.defaultsVersion"
    }

    private static let currentDefaultsVersion = 4

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
        let storedVersion = d.integer(forKey: Keys.defaultsVersion)
        if storedVersion < currentDefaultsVersion {
            if storedVersion < 2 {
                d.set(ExportPlanType.listingPlan.rawValue, forKey: Keys.planType)
            }
            if storedVersion < 3 {
                d.set(false, forKey: Keys.showWalkPath)
            }
            if d.string(forKey: Keys.planType) == ExportPlanType.listingPlan.rawValue {
                d.set(ExportPlanType.automatic.rawValue, forKey: Keys.planType)
            }
            d.set(currentDefaultsVersion, forKey: Keys.defaultsVersion)
        }
        let storedCats = d.stringArray(forKey: Keys.furnitureCategories)
        let cats = Set(storedCats ?? allFurnitureCategories)
        return ExportStyleSettings(
            planType: d.string(forKey: Keys.planType).flatMap(ExportPlanType.init(rawValue:)) ?? .automatic,
            showWalkPath: d.object(forKey: Keys.showWalkPath) as? Bool ?? false,
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

    @discardableResult
    func saveIfChanged(from previous: ExportStyleSettings) -> Bool {
        guard self != previous else { return false }
        save()
        return true
    }

    var furnitureQueryValue: String {
        if !showFurniture { return "none" }
        if furnitureCategories.isEmpty { return "none" }
        if furnitureCategories.count >= Self.allFurnitureCategories.count { return "all" }
        return furnitureCategories.sorted().joined(separator: ",")
    }

    var queryItems: [URLQueryItem] {
        if planType == .automatic {
            return [URLQueryItem(name: "style", value: "auto")]
        }
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
