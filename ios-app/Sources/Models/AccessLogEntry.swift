//
//  AccessLogEntry.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ScanIdentity.swift header.
//

import Foundation

/// Mirrors one row of `GET /scan-sessions/{id}/access-log`'s `access_log`
/// array (scan-service/src/ScanSessionRepository.php::accessLog()) — every
/// authorization attempt for a session, granted or denied.
struct AccessLogEntry: Codable, Identifiable {
    let action: String
    let outcome: String
    let occurredAt: String

    var id: String { action + outcome + occurredAt }

    enum CodingKeys: String, CodingKey {
        case action
        case outcome
        case occurredAt = "occurred_at"
    }
}

/// Response shape from `GET /scan-sessions/{id}/access-log`.
struct AccessLogResponse: Codable {
    let scanSessionId: String
    let accessLog: [AccessLogEntry]

    enum CodingKeys: String, CodingKey {
        case scanSessionId = "scan_session_id"
        case accessLog = "access_log"
    }
}
