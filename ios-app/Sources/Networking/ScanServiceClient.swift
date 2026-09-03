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

/// Response from `POST /scan-sessions/{id}/photo-uploads` — the `url` here
/// is what gets passed straight into `addPhoto(url:)` below, unchanged.
struct PhotoUploadResponse: Decodable {
    let url: String
    let photoUploadId: String

    enum CodingKeys: String, CodingKey {
        case url
        case photoUploadId = "photo_upload_id"
    }
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

    func uploadCapture(sessionId: String, accessToken: String, capture: RoomPlanCaptureExport, provider: String = "roomplan", location: CaptureLocation? = nil) async throws -> FloorPlan {
        struct Body: Encodable {
            let rawCapture: RoomPlanCaptureExport
            let captureProvider: String
            let captureLocation: CaptureLocation?

            enum CodingKeys: String, CodingKey {
                case rawCapture = "raw_capture"
                case captureProvider = "capture_provider"
                case captureLocation = "capture_location"
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/capture", body: Body(rawCapture: capture, captureProvider: provider, captureLocation: location), accessToken: accessToken)
    }

    func fetchSession(sessionId: String, accessToken: String) async throws -> FloorPlan {
        try await get(path: "/scan-sessions/\(sessionId)", accessToken: accessToken)
    }

    func fetchFloorPlanImage(sessionId: String, accessToken: String) async throws -> Data {
        try await getData(path: "/scan-sessions/\(sessionId)/export/floorplan.png", accessToken: accessToken)
    }

    func fetchFloorPlanPDF(sessionId: String, accessToken: String) async throws -> Data {
        try await getData(path: "/scan-sessions/\(sessionId)/export/floorplan.pdf", accessToken: accessToken)
    }

    func fetchAccessLog(sessionId: String, accessToken: String) async throws -> AccessLogResponse {
        try await get(path: "/scan-sessions/\(sessionId)/access-log", accessToken: accessToken)
    }

    /// Uploads real image bytes and gets back a url — pass that straight into
    /// `addPhoto(url:)` below, same as any externally-hosted photo url would
    /// be. Two separate calls, not one, so the existing /photos contract
    /// (and its own room_id/caption validation) never has to know whether a
    /// url came from this upload path or from somewhere else.
    func uploadPhoto(sessionId: String, accessToken: String, imageData: Data, filename: String, mimeType: String) async throws -> PhotoUploadResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("/scan-sessions/\(sessionId)/photo-uploads"))
        request.httpMethod = "POST"
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        return try await send(request)
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

    /// Like `get`, but for the two export routes, which return image/png or
    /// application/pdf bytes rather than JSON — nothing here to decode.
    private func getData(path: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            #if DEBUG
            await logRequest(request, status: nil)
            #endif
            throw ScanServiceError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        #if DEBUG
        await logRequest(request, status: status)
        #endif

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ScanServiceError.unexpectedStatus(status ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }

        return data
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            #if DEBUG
            await logRequest(request, status: nil)
            #endif
            throw ScanServiceError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        #if DEBUG
        await logRequest(request, status: status)
        #endif

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ScanServiceError.unexpectedStatus(status ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    // Per Mark's 2026-09-01 request: "each request with its response code and
    // the VS code on failure." AppError already provides the VS code half —
    // this is the other half, logged here (not at each call site) so no
    // request path can add a new call without this coming along for free.
    // Logs every request, success or failure, not just failures: a report
    // with only failure entries can't show what a healthy run's request
    // pattern even looks like for comparison.
    #if DEBUG
    private func logRequest(_ request: URLRequest, status: Int?) async {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "?"
        let statusText = status.map(String.init) ?? "no response (transport error)"
        await DiagnosticsLog.shared.record("\(method) \(path) -> \(statusText)", category: .request)
    }
    #endif
}
