
import Foundation

struct ScanIdentity: Codable, Equatable {
    let propertyId: String
    let unitId: String
    let organisationId: String
    let purpose: ScanPurpose
    let occupied: Bool
    let consentObtained: Bool

    enum CodingKeys: String, CodingKey {
        case propertyId = "property_id"
        case unitId = "unit_id"
        case organisationId = "organisation_id"
        case purpose
        case occupied
        case consentObtained = "consent_obtained"
    }
}

enum ScanPurpose: String, Codable, CaseIterable, Identifiable, Hashable {
    case listing
    case checkIn = "check_in"
    case checkOut = "check_out"
    case renovation
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .listing: return "Listing"
        case .checkIn: return "Check-in"
        case .checkOut: return "Check-out"
        case .renovation: return "Renovation"
        case .other: return "Other"
        }
    }
}
