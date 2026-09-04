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
    let expiresAt: String?

    var id: String { sessionId }

    /// LIDAR-4 (multi-room unit story): the real gap this closes is that
    /// once a landlord leaves the live capture flow — app killed,
    /// backgrounded past ARKit's tolerance, or they come back a different
    /// day for a room they missed — there was no way back into that
    /// session; IdentityIntakeScreen's "Start scan" always creates a brand
    /// new one, silently orphaning the room(s) already uploaded. This
    /// reconstructs just enough of ScanSessionResponse to resume: only
    /// `.id`/`.accessToken` are ever read downstream of the capturing stage
    /// (confirmed by grep — no call site reads session.status/occupied/
    /// consentObtained/propertyId/unitId/organisationId/purpose/createdAt),
    /// so the placeholder values below are never actually consumed.
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

    /// Companion to `asResumableSession()`: the capturing stage's `identity`
    /// carries occupied/consentObtained, which this device never persisted
    /// (correctly — consent is a one-time gate at session creation, not
    /// something to re-derive later). Safe as a placeholder for the same
    /// reason: resuming with a non-nil session skips session creation
    /// entirely, so `submit()` never reads these two fields off this value.
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
