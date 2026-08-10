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
