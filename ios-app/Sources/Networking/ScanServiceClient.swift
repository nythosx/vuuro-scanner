import Foundation

enum ScanServiceError: Error {
    case unexpectedStatus(Int, body: String)
    case transport(Error)
    case noFloorPlanYet
    case notConfigured
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
        case .noFloorPlanYet:
            return "This session hasn't captured a room yet. Capture a room before attaching photos or notes."
        case .notConfigured:
            return "Scan Service isn't configured for this build — it would otherwise point at itself (127.0.0.1/localhost). Set a real Scan Service URL before testing on a device."
        }
    }
}

private struct SessionOrFloorPlanResponse: Decodable {
    let floorPlan: FloorPlan?

    private enum RootKeys: String, CodingKey {
        case floorPlan = "floor_plan"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootKeys.self)
        if container.contains(.floorPlan) {
            floorPlan = try container.decodeIfPresent(FloorPlan.self, forKey: .floorPlan)
        } else {
            floorPlan = try FloorPlan(from: decoder)
        }
    }
}

private struct ScanServiceErrorBody: Decodable {
    let error: String?
    let message: String
}

extension ScanServiceError {
    var serverCode: String? {
        guard case .unexpectedStatus(_, let body) = self, let data = body.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(ScanServiceErrorBody.self, from: data))?.error
    }
}

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

struct SessionActivityEntry: Decodable {
    let id: String
    let capturedAt: String
    let rooms: [Room]?

    struct Room: Decodable, RoomSummarySource {
        let label: String
        let floor: String?
        let floorAreaM2: Double
        let roomType: FloorPlan.RoomType?

        enum CodingKeys: String, CodingKey {
            case label
            case floor
            case floorAreaM2 = "floor_area_m2"
            case roomType = "room_type"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            floor = try c.decodeIfPresent(String.self, forKey: .floor)
            floorAreaM2 = try c.decode(Double.self, forKey: .floorAreaM2)
            roomType = try? c.decodeIfPresent(FloorPlan.RoomType.self, forKey: .roomType)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case rooms
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        capturedAt = try c.decode(String.self, forKey: .capturedAt)
        rooms = try? c.decodeIfPresent([Room].self, forKey: .rooms)
    }
}

private struct EmptyBody: Encodable {}

struct ScanServiceClient {
    var baseURL: URL
    var isConfigured: Bool
    var appKey: String? = ScanServiceClient.bundledAppKey()
    var session: URLSession = ScanServiceClient.sharedSession

    init() {
        #if DEBUG
        if let debugURL = DebugScanServiceURL.resolved {
            baseURL = debugURL
            isConfigured = true
            return
        }
        #endif
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "ScanServiceBaseURL") as? String,
           !plistValue.isEmpty,
           let plistURL = URL(string: plistValue),
           plistURL.scheme != nil,
           let host = plistURL.host,
           !Self.isLoopbackHost(host) {
            baseURL = plistURL
            isConfigured = true
        } else {
            baseURL = URL(string: "http://127.0.0.1:8089")!
            isConfigured = false
        }
    }

    private static func bundledAppKey() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ScanServiceAppKey") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        case "ws": return 80
        case "wss": return 443
        case "ftp": return 21
        default: return nil
        }
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let explicit = url.port { return explicit }
        guard let scheme = url.scheme else { return nil }
        return defaultPort(for: scheme)
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased()
        else { return false }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    func createSession(identity: ScanIdentity) async throws -> ScanSessionResponse {


        try await post(path: "/scan-sessions", body: identity, accessToken: nil, extraHeaders: appKey.map { ["X-Scan-App-Key": $0] } ?? [:])
    }

    func checkHealth() async throws {
        let _: HealthResponse = try await get(path: "/health", accessToken: nil)
    }

    func rotateToken(sessionId: String, accessToken: String) async throws -> RotateTokenResponse {
        try await post(path: "/scan-sessions/\(sessionId)/rotate-token", body: EmptyBody(), accessToken: accessToken)
    }

    struct DefaultFloorResponse: Decodable {
        let id: String
        let defaultFloor: String

        enum CodingKeys: String, CodingKey {
            case id
            case defaultFloor = "default_floor"
        }
    }

    func setDefaultFloor(sessionId: String, accessToken: String, floor: String?) async throws -> DefaultFloorResponse {
        struct Body: Encodable {
            let floor: String
        }
        return try await post(path: "/scan-sessions/\(sessionId)/default-floor", body: Body(floor: floor ?? ""), accessToken: accessToken)
    }

    func deleteSession(sessionId: String, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/scan-sessions/\(sessionId)"))
        request.httpMethod = "DELETE"
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        struct DeleteResponse: Decodable { let deleted: Bool }
        let _: DeleteResponse = try await send(request)
    }

    struct CaptureBody: Encodable {
        let rawCapture: RoomPlanCaptureExport
        let captureProvider: String
        let captureLocation: CaptureLocation?
        let floor: String?

        enum CodingKeys: String, CodingKey {
            case rawCapture = "raw_capture"
            case captureProvider = "capture_provider"
            case captureLocation = "capture_location"
            case floor
        }
    }

    func encodeCaptureBody(
        capture: RoomPlanCaptureExport,
        provider: String = "roomplan",
        location: CaptureLocation? = nil,
        floor: String? = nil
    ) throws -> Data {
        try JSONEncoder().encode(CaptureBody(
            rawCapture: capture,
            captureProvider: provider,
            captureLocation: location,
            floor: floor
        ))
    }

    func uploadCapture(sessionId: String, accessToken: String, idempotencyKey: String, bodyJSON: Data) async throws -> FloorPlan {
        var request = URLRequest(url: url(for: "/scan-sessions/\(sessionId)/capture"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = bodyJSON
        return try await send(request, timeoutSeconds: 90)
    }

    func uploadCaptureKeepingRoom(sessionId: String, accessToken: String, idempotencyKey: String, bodyJSON: Data) async throws -> (floorPlan: FloorPlan, addedAsNew: Bool) {
        do {
            let floorPlan = try await uploadCapture(sessionId: sessionId, accessToken: accessToken, idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)
            return (floorPlan, false)
        } catch {
            guard RescanResume.isStaleReplace(error),
                  let target = RescanResume.replacesRoomId(in: bodyJSON),
                  let plainBody = RescanResume.captureBody(bodyJSON, replacing: nil) else { throw error }
            DiagnosticsLog.shared.record("Rescan: room \(target) can no longer be replaced (\((error as? ScanServiceError)?.serverCode ?? "unknown")), uploading as a new room", category: .info)
            let floorPlan = try await uploadCapture(sessionId: sessionId, accessToken: accessToken, idempotencyKey: UUID().uuidString, bodyJSON: plainBody)
            return (floorPlan, true)
        }
    }

    struct ReplaceRoomsBody: Encodable {
        let captures: [CaptureBody]
    }

    func replaceRooms(
        sessionId: String,
        accessToken: String,
        exports: [RoomPlanCaptureExport],
        provider: String = "roomplan",
        location: CaptureLocation?,
        floor: String? = nil,
        floors: [String?]? = nil
    ) async throws -> FloorPlan {
        let body = ReplaceRoomsBody(captures: exports.enumerated().map { index, export in
            CaptureBody(
                rawCapture: export,
                captureProvider: provider,
                captureLocation: location,
                floor: floors.map { $0.indices.contains(index) ? ($0[index] ?? "") : floor } ?? floor
            )
        })
        return try await post(path: "/scan-sessions/\(sessionId)/rooms", body: body, accessToken: accessToken, timeoutSeconds: 90)
    }

    struct RequestDeletionResponse: Decodable {
        let requested: Bool
        let deletionRequestedAt: String
        let purgeAfter: String?
        let gracePeriodDays: Int
        let requestsEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case requested
            case deletionRequestedAt = "deletion_requested_at"
            case purgeAfter = "purge_after"
            case gracePeriodDays = "grace_period_days"
            case requestsEnabled = "requests_enabled"
        }
    }

    func fetchDeletionStatus(sessionId: String, accessToken: String) async throws -> RequestDeletionResponse {
        try await get(path: "/scan-sessions/\(sessionId)/deletion-request", accessToken: accessToken)
    }

    func cancelSessionDeletion(sessionId: String, accessToken: String) async throws -> RequestDeletionResponse {
        struct Body: Encodable {}
        return try await post(path: "/scan-sessions/\(sessionId)/cancel-deletion", body: Body(), accessToken: accessToken)
    }

    func markNoteOnly(sessionId: String, accessToken: String) async throws -> FloorPlan {
        struct Body: Encodable {}
        return try await post(path: "/scan-sessions/\(sessionId)/note-only", body: Body(), accessToken: accessToken)
    }

    func requestSessionDeletion(sessionId: String, accessToken: String) async throws -> RequestDeletionResponse {
        struct Body: Encodable {}
        return try await post(path: "/scan-sessions/\(sessionId)/request-deletion", body: Body(), accessToken: accessToken)
    }

    func fetchSession(sessionId: String, accessToken: String) async throws -> FloorPlan {
        let response: SessionOrFloorPlanResponse = try await get(path: "/scan-sessions/\(sessionId)", accessToken: accessToken)
        guard let floorPlan = response.floorPlan else {
            throw ScanServiceError.noFloorPlanYet
        }
        ScanHistoryStore.shared.noteServerCapture(sessionId: sessionId, capturedAt: floorPlan.capturedAt)
        return floorPlan
    }

    func fetchActivity(entries: [(id: String, token: String)]) async throws -> [SessionActivityEntry] {
        struct Body: Encodable {
            struct Entry: Encodable {
                let id: String
                let token: String
            }

            let sessions: [Entry]
        }
        struct Response: Decodable {
            let sessions: [SessionActivityEntry]
        }
        let response: Response = try await post(
            path: "/scan-sessions/activity",
            body: Body(sessions: entries.map { Body.Entry(id: $0.id, token: $0.token) }),
            accessToken: nil
        )
        return response.sessions
    }

    func noteActivity(_ entries: [ScanHistoryEntry]) async {
        let pairs = entries.filter { !$0.accessToken.isEmpty }.map { (id: $0.sessionId, token: $0.accessToken) }
        guard !pairs.isEmpty else { return }
        do {
            let results = try await fetchActivity(entries: pairs)
            ScanHistoryStore.shared.applyServerActivity(results)
        } catch is CancellationError {
        } catch {
            DiagnosticsLog.shared.record("Activity refresh failed: \(error.localizedDescription)", category: .error)
        }
    }

    func fetchPhotoData(url: String, accessToken: String) async throws -> Data {
        let resolved = URL(string: url, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(url)





        guard Self.isSameOrigin(resolved, baseURL) else {
            let (data, response) = try await session.data(from: resolved)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw ScanServiceError.unexpectedStatus((response as? HTTPURLResponse)?.statusCode ?? -1, body: "")
            }
            return data
        }
        guard isConfigured else { throw ScanServiceError.notConfigured }
        var request = URLRequest(url: resolved)
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            logRequest(request, status: nil)
            throw ScanServiceError.transport(unreachableError(request, underlying: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        logRequest(request, status: status)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ScanServiceError.unexpectedStatus(status ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func fetchFloorPlanImage(sessionId: String, accessToken: String, unit: MeasurementUnit = .metric, label: String? = nil, style: ExportStyleSettings? = nil, roomId: String? = nil, floor: String? = nil, group: String? = nil) async throws -> Data {
        let resolved = style ?? ExportStyleSettings.load()
        return try await getData(path: "/scan-sessions/\(sessionId)/export/floorplan.png\(exportQuery(unit: unit, label: label, style: resolved, roomId: roomId, floor: floor, group: group))", accessToken: accessToken)
    }

    func fetchFloorPlanPDF(sessionId: String, accessToken: String, unit: MeasurementUnit = .metric, label: String? = nil, style: ExportStyleSettings? = nil) async throws -> Data {
        let resolved = style ?? ExportStyleSettings.load()
        return try await getData(path: "/scan-sessions/\(sessionId)/export/floorplan.pdf\(exportQuery(unit: unit, label: label, style: resolved))", accessToken: accessToken)
    }

    private func exportQuery(unit: MeasurementUnit, label: String?, style: ExportStyleSettings, roomId: String? = nil, floor: String? = nil, group: String? = nil) -> String {
        var items = [URLQueryItem(name: "unit", value: unit.rawValue)]
        if let label, !label.isEmpty {
            items.append(URLQueryItem(name: "label", value: label))
        }
        if let roomId {
            items.append(URLQueryItem(name: "room_id", value: roomId))
        }
        if let floor {
            items.append(URLQueryItem(name: "floor", value: floor))
        }
        if let group {
            items.append(URLQueryItem(name: "group", value: group))
        }
        items.append(contentsOf: style.queryItems)
        items.append(URLQueryItem(name: "lang", value: AppLanguageSettings.exportLanguageCode))
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

    func updateRoomFloor(sessionId: String, accessToken: String, roomId: String, floor: String?) async throws -> FloorPlan {
        struct Body: Encodable {
            let floor: String?

            enum CodingKeys: String, CodingKey {
                case floor
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(floor, forKey: .floor)
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/rooms/\(roomId)/floor", body: Body(floor: floor), accessToken: accessToken)
    }

    func deleteRoom(sessionId: String, accessToken: String, roomId: String) async throws -> FloorPlan {
        try await delete(path: "/scan-sessions/\(sessionId)/rooms/\(roomId)", accessToken: accessToken)
    }

    func updateRoomLabel(sessionId: String, accessToken: String, roomId: String, label: String) async throws -> FloorPlan {
        struct Body: Encodable {
            let label: String
        }
        return try await post(path: "/scan-sessions/\(sessionId)/rooms/\(roomId)/label", body: Body(label: label), accessToken: accessToken)
    }

    enum RoomSplitMode: String, Encodable {
        case split
        case trim
    }

    func splitRoom(sessionId: String, accessToken: String, roomId: String, line: [[Double]], keepPoint: [Double], mode: RoomSplitMode) async throws -> FloorPlan {
        struct Body: Encodable {
            let lineM: [[Double]]
            let keepPointM: [Double]
            let mode: RoomSplitMode

            enum CodingKeys: String, CodingKey {
                case lineM = "line_m"
                case keepPointM = "keep_point_m"
                case mode
            }
        }
        return try await post(path: "/scan-sessions/\(sessionId)/rooms/\(roomId)/split", body: Body(lineM: line, keepPointM: keepPoint, mode: mode), accessToken: accessToken)
    }

    func undoRoomSplit(sessionId: String, accessToken: String) async throws -> FloorPlan {
        struct Body: Encodable {}
        return try await post(path: "/scan-sessions/\(sessionId)/room-splits/undo", body: Body(), accessToken: accessToken)
    }


    func placeGroup(
        sessionId: String,
        accessToken: String,
        groupId: String,
        joinTo: String?,
        rotationDeg: Double,
        translationM: [Double],
        floor: String?
    ) async throws -> FloorPlan {
        struct Body: Encodable {
            let joinToGroupId: String?
            let rotationDeg: Double
            let translationM: [Double]
            let floor: String?
            enum CodingKeys: String, CodingKey {
                case joinToGroupId = "join_to_group_id"
                case rotationDeg = "rotation_deg"
                case translationM = "translation_m"
                case floor
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(joinToGroupId, forKey: .joinToGroupId)
                try container.encode(rotationDeg, forKey: .rotationDeg)
                try container.encode(translationM, forKey: .translationM)
                try container.encode(floor, forKey: .floor)
            }
        }
        return try await post(
            path: "/scan-sessions/\(sessionId)/groups/\(groupId)/placement",
            body: Body(joinToGroupId: joinTo, rotationDeg: rotationDeg, translationM: translationM, floor: floor),
            accessToken: accessToken
        )
    }

    func fetchAccessLog(sessionId: String, accessToken: String) async throws -> AccessLogResponse {
        try await get(path: "/scan-sessions/\(sessionId)/access-log", accessToken: accessToken)
    }

    func batchUpdateObjects(sessionId: String, accessToken: String, changes: [ObjectChangeRequest]) async throws -> FloorPlan {
        struct Body: Encodable {
            let changes: [ObjectChangeRequest]
        }
        return try await post(
            path: "/scan-sessions/\(sessionId)/objects/batch",
            body: Body(changes: changes),
            accessToken: accessToken
        )
    }

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

        return try await send(request, timeoutSeconds: 90)
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

    func addNote(
        sessionId: String,
        accessToken: String,
        text: String,
        roomId: String? = nil,
        tags: [InspectionTag] = []
    ) async throws -> FloorPlan {
        struct Body: Encodable {
            let text: String
            let roomId: String?
            let tags: [String]

            enum CodingKeys: String, CodingKey {
                case text
                case roomId = "room_id"
                case tags
            }
        }
        return try await post(
            path: "/scan-sessions/\(sessionId)/notes",
            body: Body(text: text, roomId: roomId, tags: tags.map(\.rawValue)),
            accessToken: accessToken
        )
    }

    func updateNote(
        sessionId: String,
        accessToken: String,
        noteId: String,
        text: String,
        tags: [InspectionTag]? = nil
    ) async throws -> FloorPlan {
        struct Body: Encodable {
            let text: String
            let tags: [String]?
        }
        return try await post(
            path: "/scan-sessions/\(sessionId)/notes/\(noteId)",
            body: Body(text: text, tags: tags?.map(\.rawValue)),
            accessToken: accessToken
        )
    }

    func deleteNote(sessionId: String, accessToken: String, noteId: String) async throws -> FloorPlan {
        try await delete(path: "/scan-sessions/\(sessionId)/notes/\(noteId)", accessToken: accessToken)
    }

    func deletePhoto(sessionId: String, accessToken: String, photoId: String) async throws -> FloorPlan {
        try await delete(path: "/scan-sessions/\(sessionId)/photos/\(photoId)", accessToken: accessToken)
    }

    private func delete<Response: Decodable>(path: String, accessToken: String) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "DELETE"
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        return try await send(request)
    }

    private func url(for path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let withPath = baseURL.appendingPathComponent(String(parts[0]))
        guard parts.count == 2, !parts[1].isEmpty else {
            return withPath
        }
        var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = String(parts[1])
        return components?.url ?? withPath
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body, accessToken: String?, timeoutSeconds: TimeInterval = ScanServiceClient.requestTimeoutSeconds, extraHeaders: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, timeoutSeconds: timeoutSeconds)
    }

    private static let requestTimeoutSeconds: TimeInterval = 25

    private func get<Response: Decodable>(path: String, accessToken: String?) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.timeoutInterval = Self.requestTimeoutSeconds
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")
        }
        return try await send(request)
    }



    private func getData(path: String, accessToken: String) async throws -> Data {
        guard isConfigured else { throw ScanServiceError.notConfigured }
        var request = URLRequest(url: url(for: path))
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue(accessToken, forHTTPHeaderField: "X-Scan-Access-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            logRequest(request, status: nil)
            throw ScanServiceError.transport(unreachableError(request, underlying: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        logRequest(request, status: status)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ScanServiceError.unexpectedStatus(status ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }

        return data
    }

    private func send<Response: Decodable>(_ request: URLRequest, timeoutSeconds: TimeInterval = ScanServiceClient.requestTimeoutSeconds) async throws -> Response {
        guard isConfigured else { throw ScanServiceError.notConfigured }
        var request = request
        request.timeoutInterval = timeoutSeconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            logRequest(request, status: nil)
            throw ScanServiceError.transport(unreachableError(request, underlying: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        logRequest(request, status: status)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ScanServiceError.unexpectedStatus(status ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }

        await recordSessionChange(request)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func recordSessionChange(_ request: URLRequest) async {
        guard let method = request.httpMethod?.uppercased(), method != "GET", let path = request.url?.path else { return }
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "scan-sessions"), parts.count > index + 1 else { return }
        let sessionId = String(parts[index + 1])
        await FloorPlanImageCache.shared.invalidate(sessionId: sessionId)
        if method == "POST", parts.count == index + 3, parts[index + 2] == "capture" || parts[index + 2] == "rooms" {
            ScanHistoryStore.shared.markCaptured(sessionId: sessionId)
        }
    }
    private func unreachableError(_ request: URLRequest, underlying: Error) -> Error {
        let attempted = request.url?.absoluteString ?? baseURL.absoluteString
        return PlainError(message: "Couldn't reach the Scan Service at \(attempted): \(underlying.localizedDescription)")
    }

    private func logRequest(_ request: URLRequest, status: Int?) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "?"
        let statusText = status.map(String.init) ?? "no response (transport error)"
        DiagnosticsLog.shared.record("\(method) \(path) -> \(statusText)", category: .request)
    }
}