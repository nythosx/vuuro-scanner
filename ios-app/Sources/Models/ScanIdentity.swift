//
//  ScanIdentity.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN. No Mac/Xcode was reachable when this file
//  was authored (see ../README.md and ../../docs/adr/0001-scan-service-stack.md).
//  Treat this as a design draft, not verified working code, until it has
//  actually been opened, built, and run in Xcode.
//

import Foundation

/// The Vuuro identity every scan session must carry from creation onward.
/// Mirrors the Scan Service's required fields for `POST /scan-sessions`
/// (hard constraint #1: identity-native captures, no orphan captures).
struct ScanIdentity: Codable, Equatable {
    let propertyId: String
    let unitId: String
    let organisationId: String
    let purpose: ScanPurpose
    /// Privacy by design (hard constraint #3, docs/adr/0003-privacy-acl-session-tokens.md).
    /// Required — there is deliberately no default, so the app must force
    /// this to be a real answer, not an assumption, before every session.
    let occupied: Bool
    /// Required by the Scan Service (403) whenever `occupied` is true. Must
    /// reflect an actual recorded consent step in the app's UI, never be
    /// hardcoded true — that would defeat the whole point of the gate.
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

/// Matches the Scan Service's `purpose` enum exactly
/// (contracts/floorplan.schema.json) — "ops memory" is first-class, not an
/// afterthought tag, so this must not silently default to "listing".
enum ScanPurpose: String, Codable, CaseIterable, Identifiable {
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
