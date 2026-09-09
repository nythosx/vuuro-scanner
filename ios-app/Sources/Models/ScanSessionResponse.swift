
import Foundation

struct ScanSessionResponse: Codable {
    let id: String
    let propertyId: String
    let unitId: String
    let organisationId: String
    let purpose: String
    let createdAt: String
    let status: String
    let occupied: Bool
    let consentObtained: Bool
    let accessToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case propertyId = "property_id"
        case unitId = "unit_id"
        case organisationId = "organisation_id"
        case purpose
        case createdAt = "created_at"
        case status
        case occupied
        case consentObtained = "consent_obtained"
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

struct FloorPlan: Codable {
    let scanSessionId: String
    let propertyId: String
    let unitId: String
    let organisationId: String
    let captureProvider: String
    let capturedAt: String
    let measurementBasis: String
    let purpose: String
    let rooms: [Room]
    let photos: [Photo]
    let notes: [Note]
    let captureLocation: CaptureLocation?

    struct Photo: Codable {
        let photoId: String
        let url: String
        let caption: String
        let roomId: String?
        let takenAt: String

        enum CodingKeys: String, CodingKey {
            case photoId = "photo_id"
            case url
            case caption
            case roomId = "room_id"
            case takenAt = "taken_at"
        }
    }

    struct Note: Codable {
        let noteId: String
        let text: String
        let roomId: String?
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case noteId = "note_id"
            case text
            case roomId = "room_id"
            case createdAt = "created_at"
        }
    }

    struct Room: Codable {
        let roomId: String
        let label: String
        let floorAreaM2: Double
        let perimeterM: Double
        let boundingDimensionsM: BoundingDimensions
        let confidence: String
        let outlineM: [[Double]]
        let coverage: Coverage
        let openings: [Opening]
        let heightM: Double?
        let volumeM3Indicative: Double?
        let objects: [CapturedObject]
        let structureOriginM: [Double]?
        let roomType: RoomType?

        enum CodingKeys: String, CodingKey {
            case roomId = "room_id"
            case label
            case floorAreaM2 = "floor_area_m2"
            case perimeterM = "perimeter_m"
            case boundingDimensionsM = "bounding_dimensions_m"
            case confidence
            case outlineM = "outline_m"
            case coverage
            case openings
            case heightM = "height_m"
            case volumeM3Indicative = "volume_m3_indicative"
            case objects
            case structureOriginM = "structure_origin_m"
            case roomType = "room_type"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            roomId = try c.decode(String.self, forKey: .roomId)
            label = try c.decode(String.self, forKey: .label)
            floorAreaM2 = try c.decode(Double.self, forKey: .floorAreaM2)
            perimeterM = try c.decode(Double.self, forKey: .perimeterM)
            boundingDimensionsM = try c.decode(BoundingDimensions.self, forKey: .boundingDimensionsM)
            confidence = try c.decode(String.self, forKey: .confidence)
            outlineM = try c.decode([[Double]].self, forKey: .outlineM)
            coverage = try c.decode(Coverage.self, forKey: .coverage)
            heightM = try c.decodeIfPresent(Double.self, forKey: .heightM)
            volumeM3Indicative = try c.decodeIfPresent(Double.self, forKey: .volumeM3Indicative)
            openings = try c.decodeIfPresent([Opening].self, forKey: .openings) ?? []
            objects = try c.decodeIfPresent([CapturedObject].self, forKey: .objects) ?? []
            structureOriginM = try c.decodeIfPresent([Double].self, forKey: .structureOriginM)
            roomType = try c.decodeIfPresent(RoomType.self, forKey: .roomType)
        }
    }

    struct RoomType: Codable {
        let guess: String?
        let guessSource: String?
        let confirmed: String?

        enum CodingKeys: String, CodingKey {
            case guess
            case guessSource = "guess_source"
            case confirmed
        }
    }

    struct Opening: Codable {
        let openingId: String
        let category: String
        let positionM: [Double]
        let confidence: String

        enum CodingKeys: String, CodingKey {
            case openingId = "opening_id"
            case category
            case positionM = "position_m"
            case confidence
        }
    }

    struct CapturedObject: Codable {
        let objectId: String
        let category: String
        let positionM: [Double]
        let dimensionsM: [Double]
        let confidence: String

        enum CodingKeys: String, CodingKey {
            case objectId = "object_id"
            case category
            case positionM = "position_m"
            case dimensionsM = "dimensions_m"
            case confidence
        }
    }

    struct Coverage: Codable {
        let score: Int
        let confidenceCounts: ConfidenceCounts
        let usable: Bool
        let message: String?

        enum CodingKeys: String, CodingKey {
            case score
            case confidenceCounts = "confidence_counts"
            case usable
            case message
        }

        struct ConfidenceCounts: Codable {
            let high: Int
            let medium: Int
            let low: Int
        }
    }

    struct BoundingDimensions: Codable {
        let widthM: Double
        let lengthM: Double

        enum CodingKeys: String, CodingKey {
            case widthM = "width_m"
            case lengthM = "length_m"
        }
    }

    enum CodingKeys: String, CodingKey {
        case scanSessionId = "scan_session_id"
        case propertyId = "property_id"
        case unitId = "unit_id"
        case organisationId = "organisation_id"
        case captureProvider = "capture_provider"
        case capturedAt = "captured_at"
        case measurementBasis = "measurement_basis"
        case purpose
        case rooms
        case photos
        case notes
        case captureLocation = "capture_location"
    }
}
