
import Foundation

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
struct AccessLogResponse: Codable {
    let scanSessionId: String
    let accessLog: [AccessLogEntry]

    enum CodingKeys: String, CodingKey {
        case scanSessionId = "scan_session_id"
        case accessLog = "access_log"
    }
}
