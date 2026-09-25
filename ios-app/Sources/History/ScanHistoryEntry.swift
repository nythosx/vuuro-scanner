
import Foundation

struct CachedFloorSummary: Codable, Equatable {
    var roomCount: Int
    var areaM2: Double
}

extension CachedFloorSummary {
    static func buckets(from rooms: [FloorPlan.Room]) -> [String: CachedFloorSummary] {
        var result: [String: CachedFloorSummary] = [:]
        for room in rooms {
            let key = (room.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var existing = result[key] ?? CachedFloorSummary(roomCount: 0, areaM2: 0)
            existing.roomCount += 1
            existing.areaM2 += room.floorAreaM2
            result[key] = existing
        }
        return result
    }
}

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
    var cachedFloorAreaM2: Double? = nil
    var cachedRoomsByFloor: [String: CachedFloorSummary]? = nil
    var occupied: Bool = false
    var consentObtained: Bool = false
    var floor: String? = nil

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId, accessToken, propertyId, unitId, organisationId, purpose, createdAt, expiresAt, nickname, cachedRoomSummary, cachedFloorAreaM2, cachedRoomsByFloor, occupied, consentObtained, floor
    }

    init(sessionId: String, accessToken: String, propertyId: String, unitId: String, organisationId: String, purpose: ScanPurpose, createdAt: Date, expiresAt: String?, nickname: String? = nil, cachedRoomSummary: String? = nil, cachedFloorAreaM2: Double? = nil, cachedRoomsByFloor: [String: CachedFloorSummary]? = nil, occupied: Bool = false, consentObtained: Bool = false, floor: String? = nil) {
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
        self.cachedFloorAreaM2 = cachedFloorAreaM2
        self.cachedRoomsByFloor = cachedRoomsByFloor
        self.occupied = occupied
        self.consentObtained = consentObtained
        self.floor = floor
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
        cachedFloorAreaM2 = try container.decodeIfPresent(Double.self, forKey: .cachedFloorAreaM2)
        cachedRoomsByFloor = try container.decodeIfPresent([String: CachedFloorSummary].self, forKey: .cachedRoomsByFloor)
        occupied = try container.decodeIfPresent(Bool.self, forKey: .occupied) ?? false
        consentObtained = try container.decodeIfPresent(Bool.self, forKey: .consentObtained) ?? false
        floor = try container.decodeIfPresent(String.self, forKey: .floor)
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
            expiresAt: expiresAt ?? "",
            defaultFloor: floor
        )
    }

    func asResumableIdentity() -> ScanIdentity {
        ScanIdentity(
            propertyId: propertyId,
            unitId: unitId,
            organisationId: organisationId,
            purpose: purpose,
            occupied: occupied,
            consentObtained: consentObtained,
            floor: floor
        )
    }
}
