
import Foundation

struct ScanHistoryEntry: Codable, Identifiable, Equatable {
    let sessionId: String
    var accessToken: String
    let propertyId: String
    let unitId: String
    let organisationId: String
    let purpose: ScanPurpose
    let createdAt: Date
    let expiresAt: String?
    var nickname: String? = nil
    var cachedRoomSummary: String? = nil

    var id: String { sessionId }

    func asResumableSession() -> ScanSessionResponse {
        ScanSessionResponse(
            id: sessionId,
            propertyId: propertyId,
            unitId: unitId,
            organisationId: organisationId,
            purpose: purpose.rawValue,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            status: "unknown",
            occupied: false,
            consentObtained: false,
            accessToken: accessToken,
            expiresAt: expiresAt ?? ""
        )
    }

    func asResumableIdentity() -> ScanIdentity {
        ScanIdentity(
            propertyId: propertyId,
            unitId: unitId,
            organisationId: organisationId,
            purpose: purpose,
            occupied: false,
            consentObtained: false
        )
    }
}
