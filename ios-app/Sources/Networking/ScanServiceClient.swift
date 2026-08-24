//
//  ScanServiceClient.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//

import Foundation

enum ScanServiceError: Error {
    case unexpectedStatus(Int, body: String)
    case transport(Error)
}

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
    var baseURL: URL = {
        #if DEBUG
        if let debugURL = DebugScanServiceURL.resolved {
            return debugURL
        }
        #endif
        return URL(string: "http://127.0.0.1:8089")!
    }()
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
