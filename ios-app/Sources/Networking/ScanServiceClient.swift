//
//  ScanServiceClient.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Thin HTTP client for the three Phase 1 Scan Service endpoints
//  (scan-service/public/index.php). Deliberately no retry/offline-queue
//  logic yet — Phase 1 proves the contract end to end on a reachable
//  network; resilience for spotty on-site connectivity is a real concern
//  but not one this slice needs to solve.
//

import Foundation

enum ScanServiceError: Error {
    case unexpectedStatus(Int, body: String)
    case transport(Error)
}

/// UX hardening: without this, `error.localizedDescription` anywhere in the
/// app (every `ErrorView` in VuuroScanApp.swift uses it) would fall back to
/// Swift's generic "The operation couldn't be completed" for a plain enum
/// error — never the Scan Service's own human-readable `message` field
/// (scan-service/README.md's "Error shape"), even though the server went to
/// the trouble of sending one. Parses `body` as `{"error", "message", ...}`
/// and surfaces `message` directly; only falls back to a generic sentence
/// when the body isn't in that shape (e.g. a raw HTML error from something
/// other than this app's own backend).
extension ScanServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status, let body):
            if let data = body.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ScanServiceErrorBody.self, from: data),
               !decoded.message.isEmpty {
                return decoded.message
            }
            return "The Scan Service returned an unexpected response (HTTP \(status))."
        case .transport(let underlying):
            return "Couldn't reach the Scan Service: \(underlying.localizedDescription)"
        }
    }
}

private struct ScanServiceErrorBody: Decodable {
    let error: String?
    let message: String
}

struct ScanServiceClient {
    /// Local dev default matches `scan-service/README.md`'s
    /// `php -S 127.0.0.1:8089 public/index.php`. Point this at the
    /// Dockerized service or a tunnel (ngrok/local network) when testing
    /// from a real device, per the plan in
    /// docs/adr/0001-scan-service-stack.md — never hardcode a production
    /// URL here without that being a deliberate, reviewed change.
    var baseURL = URL(string: "http://127.0.0.1:8089")!
    var session: URLSession = .shared

    func createSession(identity: ScanIdentity) async throws -> ScanSessionResponse {
        // The only call with no access token to present yet — the Scan
        // Service issues one in the response.
        try await post(path: "/scan-sessions", body: identity, accessToken: nil)
    }

    func uploadCapture(sessionId: String, accessToken: String, capture: RoomPlanCaptureExport, provider: String = "roomplan") async throws -> FloorPlan {
        struct Body: Encodable {
            let rawCapture: RoomPlanCaptureExport
            let captureProvider: String

            enum CodingKeys: String, CodingKey {
                case rawCapture = "raw_capture"
                case captureProvider = "capture_provider"
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/capture", body: Body(rawCapture: capture, captureProvider: provider), accessToken: accessToken)
    }

    func fetchSession(sessionId: String, accessToken: String) async throws -> FloorPlan {
        try await get(path: "/scan-sessions/\(sessionId)", accessToken: accessToken)
    }

    /// `url` must already be reachable over http(s) — the Scan Service does
    /// not accept or store image bytes itself yet (see
    /// scan-service/README.md "Known limits"). There is no image upload
    /// target on the client side either, so this is wired for whenever one
    /// exists; it is not exercised by the manual smoke-test flow today.
    func addPhoto(sessionId: String, accessToken: String, url: String, caption: String? = nil, roomId: String? = nil) async throws -> FloorPlan {
        struct Body: Encodable {
            let url: String
            let caption: String?
            let roomId: String?

            enum CodingKeys: String, CodingKey {
                case url
                case caption
                case roomId = "room_id"
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/photos", body: Body(url: url, caption: caption, roomId: roomId), accessToken: accessToken)
    }

    func addNote(sessionId: String, accessToken: String, text: String, roomId: String? = nil) async throws -> FloorPlan {
        struct Body: Encodable {
            let text: String
            let roomId: String?

            enum CodingKeys: String, CodingKey {
                case text
                case roomId = "room_id"
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/notes", body: Body(text: text, roomId: roomId), accessToken: accessToken)
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body, accessToken: String?) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func get<Response: Decodable>(path: String, accessToken: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ScanServiceError.transport(error)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ScanServiceError.unexpectedStatus(status, body: String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
