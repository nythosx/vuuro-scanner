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
}
