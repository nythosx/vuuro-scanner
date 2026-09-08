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

struct HealthResponse: Decodable {
    let status: String
}

struct RotateTokenResponse: Decodable {
    let id: String
    let accessToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

private struct EmptyBody: Encodable {}

struct ScanServiceClient {
    var baseURL: URL = {
        #if DEBUG
        if let debugURL = DebugScanServiceURL.resolved {
            return debugURL
        }
        #endif
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "ScanServiceBaseURL") as? String,
           !plistValue.isEmpty,
           let plistURL = URL(string: plistValue),
           plistURL.scheme != nil {
            return plistURL
        }
        return URL(string: "http://127.0.0.1:8089")!
    }()
    var session: URLSession = .shared

    func createSession(identity: ScanIdentity) async throws -> ScanSessionResponse {
        // The only call with no access token to present yet — the Scan
        // Service issues one in the response.
        try await post(path: "/scan-sessions", body: identity, accessToken: nil)
    }

    func checkHealth() async throws {
        let _: HealthResponse = try await get(path: "/health", accessToken: nil)
    }

    func rotateToken(sessionId: String, accessToken: String) async throws -> RotateTokenResponse {
        try await post(path: "/scan-sessions/\(sessionId)/rotate-token", body: EmptyBody(), accessToken: accessToken)
    }

    func deleteSession(sessionId: String, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/scan-sessions/\(sessionId)"))
        request.httpMethod = "DELETE"
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        struct DeleteResponse: Decodable { let deleted: Bool }
        let _: DeleteResponse = try await send(request)
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

    func fetchFloorPlanImage(sessionId: String, accessToken: String, unit: MeasurementUnit = .metric, label: String? = nil) async throws -> Data {
        try await getData(path: "/scan-sessions/\(sessionId)/export/floorplan.png\(exportQuery(unit: unit, label: label))", accessToken: accessToken)
    }

    func fetchFloorPlanPDF(sessionId: String, accessToken: String, unit: MeasurementUnit = .metric, label: String? = nil) async throws -> Data {
        try await getData(path: "/scan-sessions/\(sessionId)/export/floorplan.pdf\(exportQuery(unit: unit, label: label))", accessToken: accessToken)
    }

    private func exportQuery(unit: MeasurementUnit, label: String?) -> String {
        var items = [URLQueryItem(name: "unit", value: unit.rawValue)]
        if let label, !label.isEmpty {
            items.append(URLQueryItem(name: "label", value: label))
        }
        var components = URLComponents()
        components.queryItems = items
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return "?" + query
    }

    func updateRoomType(sessionId: String, accessToken: String, roomId: String, roomType: String?) async throws -> FloorPlan {
        struct Body: Encodable {
            let roomType: String?

            enum CodingKeys: String, CodingKey {
                case roomType = "room_type"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(roomType, forKey: .roomType)
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/rooms/\(roomId)/room-type", body: Body(roomType: roomType), accessToken: accessToken)
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

    private func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path)
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body, accessToken: String?) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func get<Response: Decodable>(path: String, accessToken: String?) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        }
        return try await send(request)
    }

    /// Like `get`, but for the two export routes, which return image/png or
    /// application/pdf bytes rather than JSON — nothing here to decode.
    private func getData(path: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url(for: path))
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
