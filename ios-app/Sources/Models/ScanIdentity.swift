
import Foundation

struct ScanIdentity: Codable, Equatable {
    let propertyId: String
    let unitId: String
    let organisationId: String
    let purpose: ScanPurpose
    let occupied: Bool
    let consentObtained: Bool
    let floor: String?

    enum CodingKeys: String, CodingKey {
        case propertyId = "property_id"
        case unitId = "unit_id"
        case organisationId = "organisation_id"
        case purpose
        case occupied
        case consentObtained = "consent_obtained"
        case floor
    }

    init(
        propertyId: String,
        unitId: String,
        organisationId: String,
        purpose: ScanPurpose,
        occupied: Bool,
        consentObtained: Bool,
        floor: String? = nil
    ) {
        self.propertyId = propertyId
        self.unitId = unitId
        self.organisationId = organisationId
        self.purpose = purpose
        self.occupied = occupied
        self.consentObtained = consentObtained
        self.floor = floor
    }

    func withFloor(_ floor: String?) -> ScanIdentity {
        let trimmed = floor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ScanIdentity(
            propertyId: propertyId,
            unitId: unitId,
            organisationId: organisationId,
            purpose: purpose,
            occupied: occupied,
            consentObtained: consentObtained,
            floor: trimmed.isEmpty ? nil : trimmed
        )
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
