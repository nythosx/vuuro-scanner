
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
    var occupied: Bool = false
    var consentObtained: Bool = false

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId, accessToken, propertyId, unitId, organisationId, purpose, createdAt, expiresAt, nickname, cachedRoomSummary, occupied, consentObtained
    }

    init(sessionId: String, accessToken: String, propertyId: String, unitId: String, organisationId: String, purpose: ScanPurpose, createdAt: Date, expiresAt: String?, nickname: String? = nil, cachedRoomSummary: String? = nil, occupied: Bool = false, consentObtained: Bool = false) {
        self.sessionId = sessionId
        self.accessToken = accessToken
        self.propertyId = propertyId
        self.unitId = unitId
        self.organisationId = organisationId
        self.purpose = purpose
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nickname = nickname
        self.cachedRoomSummary = cachedRoomSummary
        self.occupied = occupied
        self.consentObtained = consentObtained
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        propertyId = try container.decode(String.self, forKey: .propertyId)
        unitId = try container.decode(String.self, forKey: .unitId)
        organisationId = try container.decode(String.self, forKey: .organisationId)
        purpose = try container.decode(ScanPurpose.self, forKey: .purpose)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        cachedRoomSummary = try container.decodeIfPresent(String.self, forKey: .cachedRoomSummary)
        occupied = try container.decodeIfPresent(Bool.self, forKey: .occupied) ?? false
        consentObtained = try container.decodeIfPresent(Bool.self, forKey: .consentObtained) ?? false
    }

    func asResumableSession() -> ScanSessionResponse {
        ScanSessionResponse(
            id: sessionId,
            propertyId: propertyId,
            unitId: unitId,
            organisationId: organisationId,
            purpose: purpose.rawValue,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            status: "unknown",
            occupied: occupied,
            consentObtained: consentObtained,
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
            occupied: occupied,
            consentObtained: consentObtained
        )
    }
}
