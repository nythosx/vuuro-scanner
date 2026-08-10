//
//  ScanSessionResponse.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ScanIdentity.swift header.
//

import Foundation

/// Response shape from `POST /scan-sessions` (scan-service/public/index.php).
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
    /// Returned exactly once, here. Every later call to this session must
    /// present it via the X-Scan-Access-Token header
    /// (docs/adr/0003-privacy-acl-session-tokens.md) — store it, don't
    /// re-derive or assume it from `id`.
    let accessToken: String

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
    }
}

/// The vendor-neutral FloorPlan contract returned by
/// `POST /scan-sessions/{id}/capture` and `GET /scan-sessions/{id}`.
/// Field-for-field mirror of contracts/floorplan.schema.json — keep in sync
/// by hand until there's a shared schema-to-Swift generation step; that's an
/// open decision, not solved here.
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
        /// [x, z] pairs, room-local only — NOT a shared coordinate frame
        /// across rooms. See docs/adr/0002-export-coordinate-frame.md.
        let outlineM: [[Double]]
        /// Scan quality signal so the app can prompt a rescan before the
        /// user leaves the room, not after (PHASES.md Phase 3).
        let coverage: Coverage

        enum CodingKeys: String, CodingKey {
            case roomId = "room_id"
            case label
            case floorAreaM2 = "floor_area_m2"
            case perimeterM = "perimeter_m"
            case boundingDimensionsM = "bounding_dimensions_m"
            case confidence
            case outlineM = "outline_m"
            case coverage
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
    }
}
