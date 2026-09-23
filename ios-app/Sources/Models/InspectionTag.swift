import Foundation

enum InspectionTag: String, CaseIterable, Codable, Identifiable {
    case damage
    case wearAndTear = "wear_and_tear"
    case missingItem = "missing_item"
    case safetyIssue = "safety_issue"
    case preExistingCondition = "pre_existing_condition"
    case maintenanceNeeded = "maintenance_needed"
    case confirmedPresent = "confirmed_present"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .damage: return "Damage"
        case .wearAndTear: return "Wear and tear"
        case .missingItem: return "Missing item"
        case .safetyIssue: return "Safety issue"
        case .preExistingCondition: return "Pre-existing condition"
        case .maintenanceNeeded: return "Maintenance needed"
        case .confirmedPresent: return "Confirmed present"
        case .other: return "Other"
        }
    }
}
