//
//  ScanHistoryEntry.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  One locally-remembered scan session, created by this device. The Scan
//  Service deliberately has no "list all sessions" endpoint — a session id
//  alone (or the whole set of sessions) must never be listable without each
//  session's own token, per ../../docs/adr/0003-privacy-acl-session-tokens.md.
//  So "scan history" here can only ever be what this device itself remembers
//  creating, never a server-side listing — there is nothing to fetch a real
//  history from.
//

import Foundation

struct ScanHistoryEntry: Codable, Identifiable, Equatable {
    let sessionId: String
    let accessToken: String
    let propertyId: String
    let unitId: String
    let organisationId: String
    let purpose: ScanPurpose
    let createdAt: Date

    var id: String { sessionId }

    /// LIDAR-4: reconstructs enough of ScanSessionResponse to resume a past
    /// session and add another room — see ios-app/'s copy of this file for
    /// why the placeholder values are safe (only .id/.accessToken are ever
    /// read downstream of the capturing stage).
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
            accessToken: accessToken
        )
    }

    /// See ios-app/'s copy of this file for why occupied/consentObtained are
    /// safe placeholders here.
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
