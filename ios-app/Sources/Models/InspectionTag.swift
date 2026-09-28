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
        case .damage: return vuuroLocalized("Damage")
        case .wearAndTear: return vuuroLocalized("Wear and tear")
        case .missingItem: return vuuroLocalized("Missing item")
        case .safetyIssue: return vuuroLocalized("Safety issue")
        case .preExistingCondition: return vuuroLocalized("Pre-existing condition")
        case .maintenanceNeeded: return vuuroLocalized("Maintenance needed")
        case .confirmedPresent: return vuuroLocalized("Confirmed present")
        case .other: return vuuroLocalized("Other")
        }
    }
}
