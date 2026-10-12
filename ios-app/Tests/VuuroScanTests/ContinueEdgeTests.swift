import XCTest
@testable import VuuroScan

final class ContinueEdgeTests: XCTestCase {
    private let identity = ScanIdentity(
        propertyId: "prop-1",
        unitId: "unit-1",
        organisationId: "org-1",
        purpose: .listing,
        occupied: false,
        consentObtained: false,
        floor: "Ground"
    )

    private func captureBody(floor: String) throws -> Data {
        try JSONEncoder().encode(ScanServiceClient.CaptureBody(
            rawCapture: FakeCaptureGenerator.random(),
            captureProvider: "roomplan",
            captureLocation: nil,
            floor: floor
        ))
    }

    private func rawCapture(_ body: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["raw_capture"] as? [String: Any])
    }

    private func activity(_ json: String) throws -> SessionActivityEntry {
        try JSONDecoder().decode(SessionActivityEntry.self, from: Data(json.utf8))
    }

    private func plan(_ specs: [(floor: String, group: String)]) throws -> [FloorPlan.Room] {
        let items = specs.enumerated().map { index, spec in
            """
            {
              "room_id": "r\(index)", "label": "Room \(index)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
              "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
              "confidence": "high", "outline_m": [[0,0],[4,0],[4,3],[0,3]],
              "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
              "openings": [], "objects": [], "structure_origin_m": [0, 0], "room_type": null,
              "floor": "\(spec.floor)", "capture_group_id": "\(spec.group)", "joined_to_group_id": null
            }
            """
        }
        return try JSONDecoder().decode([FloorPlan.Room].self, from: Data(("[" + items.joined(separator: ",") + "]").utf8))
    }

    func testActivityRoomsGiveCountsAndAreasPerFloor() throws {
        let entry = try activity("""
        {"id": "s-1", "captured_at": "2026-10-05T08:00:00+00:00", "rooms": [
          {"label": "Room 1", "floor": "Ground", "floor_area_m2": 12.5, "room_type": {"guess": "kitchen", "guess_source": "objects", "confirmed": null}},
          {"label": "Room 2", "floor": "Ground", "floor_area_m2": 7.5, "room_type": null},
          {"label": "Room 3", "floor": "Attic", "floor_area_m2": 10.0, "room_type": null}
        ]}
        """)
        let rooms = try XCTUnwrap(entry.rooms)
        let buckets = CachedFloorSummary.buckets(from: rooms)
        XCTAssertEqual(buckets["Ground"], CachedFloorSummary(roomCount: 2, areaM2: 20.0))
        XCTAssertEqual(buckets["Attic"], CachedFloorSummary(roomCount: 1, areaM2: 10.0))
        XCTAssertEqual(RoomSummary.text(for: rooms), "\(RoomTypeClassifier.displayName(for: "kitchen")), Room 2, Room 3")
    }

    func testActivityFromAnOlderServerHasNoRooms() throws {
        let entry = try activity(#"{"id": "s-1", "captured_at": "2026-10-05T08:00:00+00:00"}"#)
        XCTAssertNil(entry.rooms)
        XCTAssertEqual(entry.capturedAt, "2026-10-05T08:00:00+00:00")
    }

    func testAnOddRoomTypeDoesNotBreakTheDateRefresh() throws {
        let entry = try activity("""
        {"id": "s-1", "captured_at": "2026-10-05T08:00:00+00:00", "rooms": [
          {"label": "Room 1", "floor": null, "floor_area_m2": 9.0, "room_type": "kitchen"}
        ]}
        """)
        XCTAssertEqual(entry.rooms?.count, 1)
        XCTAssertNil(entry.rooms?.first?.roomType)
        XCTAssertEqual(entry.capturedAt, "2026-10-05T08:00:00+00:00")
    }

    func testNotesOnlyScanFromTheServerShowsZeroRooms() throws {
        let entry = try activity(#"{"id": "s-1", "captured_at": "2026-10-05T08:00:00+00:00", "rooms": []}"#)
        let rooms = try XCTUnwrap(entry.rooms)
        XCTAssertNil(RoomSummary.text(for: rooms))
        XCTAssertTrue(CachedFloorSummary.buckets(from: rooms).isEmpty)
    }

    func testServerRoomsReplaceOutdatedTotalsInHistory() throws {
        let suite = "ContinueEdgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScanHistoryStore(defaults: defaults)
        store.add(ScanHistoryEntry(
            sessionId: "s-1",
            accessToken: "",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil,
            cachedRoomSummary: "Room 1",
            cachedFloorAreaM2: 12.0,
            cachedRoomsByFloor: ["Ground": CachedFloorSummary(roomCount: 1, areaM2: 12.0)]
        ))
        let entry = try activity("""
        {"id": "s-1", "captured_at": "2026-10-05T08:00:00+00:00", "rooms": [
          {"label": "Room 1", "floor": "Ground", "floor_area_m2": 12.0, "room_type": null},
          {"label": "Room 2", "floor": "Attic", "floor_area_m2": 8.0, "room_type": null}
        ]}
        """)
        XCTAssertTrue(store.applyServerActivity([entry]))
        let updated = try XCTUnwrap(store.all().first)
        XCTAssertEqual(updated.parsedRoomCount, 2)
        XCTAssertEqual(updated.cachedFloorAreaM2, 20.0)
        XCTAssertEqual(updated.cachedRoomsByFloor?["Attic"], CachedFloorSummary(roomCount: 1, areaM2: 8.0))
        XCTAssertEqual(updated.lastCapturedAt, ScanHistoryStore.parseServerDate("2026-10-05T08:00:00+00:00"))
        XCTAssertFalse(store.applyServerActivity([entry]))
    }

    func testActivityFromAnOlderServerKeepsCachedTotals() throws {
        let suite = "ContinueEdgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScanHistoryStore(defaults: defaults)
        store.add(ScanHistoryEntry(
            sessionId: "s-1",
            accessToken: "",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: .listing,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil,
            cachedRoomSummary: "Room 1",
            cachedFloorAreaM2: 12.0
        ))
        store.applyServerActivity([try activity(#"{"id": "s-1", "captured_at": "2026-10-05T08:00:00+00:00"}"#)])
        let updated = try XCTUnwrap(store.all().first)
        XCTAssertEqual(updated.cachedRoomSummary, "Room 1")
        XCTAssertEqual(updated.cachedFloorAreaM2, 12.0)
    }

    func testAGoneOrMovedReplaceTargetIsRecognised() {
        let gone = ScanServiceError.unexpectedStatus(422, body: #"{"error": "unknown_room_id", "message": "gone"}"#)
        let moved = ScanServiceError.unexpectedStatus(409, body: #"{"error": "replace_floor_mismatch", "message": "moved"}"#)
        let other = ScanServiceError.unexpectedStatus(422, body: #"{"error": "floor_required", "message": "floor"}"#)
        XCTAssertTrue(RescanResume.isStaleReplace(gone))
        XCTAssertTrue(RescanResume.isStaleReplace(moved))
        XCTAssertFalse(RescanResume.isStaleReplace(other))
        XCTAssertFalse(RescanResume.isStaleReplace(ScanServiceError.unexpectedStatus(500, body: "not json")))
        XCTAssertFalse(RescanResume.isStaleReplace(URLError(.timedOut)))
    }

    func testTheReplaceTargetIsReadFromTheCaptureBody() throws {
        let plain = try captureBody(floor: "Ground")
        XCTAssertNil(RescanResume.replacesRoomId(in: plain))
        let replacing = try XCTUnwrap(RescanResume.captureBody(plain, replacing: "room-7"))
        XCTAssertEqual(RescanResume.replacesRoomId(in: replacing), "room-7")
        let stripped = try XCTUnwrap(RescanResume.captureBody(replacing, replacing: nil))
        XCTAssertNil(RescanResume.replacesRoomId(in: stripped))
    }

    func testPendingUploadReplaceChoiceIsWrittenIntoTheCapture() throws {
        var state = PendingUploadState(session: nil, identity: identity, captures: [.init(idempotencyKey: "key-1", bodyJSON: try captureBody(floor: "Attic"))])
        state.pendingRescan = StoredRescanChoice(roomIndex: 0, candidates: [RescanCandidate(roomId: "room-7", name: "Kitchen", floorAreaM2: 12)])
        let resolved = state.resolvingRescan(replacing: "room-7")
        XCTAssertNil(resolved.pendingRescan)
        XCTAssertEqual(try rawCapture(resolved.captures[0].bodyJSON)["replaces_room_id"] as? String, "room-7")
        XCTAssertNotEqual(resolved.captures[0].idempotencyKey, "key-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: resolved.captures[0].bodyJSON) as? [String: Any])
        XCTAssertEqual(body["floor"] as? String, "Attic")
    }

    func testPendingUploadAddAsNewLeavesTheRoomUnlinked() throws {
        var state = PendingUploadState(session: nil, identity: identity, captures: [.init(idempotencyKey: "key-1", bodyJSON: try captureBody(floor: "Ground"))])
        state.pendingRescan = StoredRescanChoice(roomIndex: 0, candidates: [RescanCandidate(roomId: "room-7", name: "Kitchen", floorAreaM2: 12)])
        let resolved = state.resolvingRescan(replacing: nil)
        XCTAssertNil(resolved.pendingRescan)
        XCTAssertNil(try rawCapture(resolved.captures[0].bodyJSON)["replaces_room_id"])
    }

    func testPendingUploadWithAStaleIndexStillClearsTheQuestion() throws {
        var state = PendingUploadState(session: nil, identity: identity, captures: [.init(idempotencyKey: "key-1", bodyJSON: try captureBody(floor: "Ground"))])
        state.pendingRescan = StoredRescanChoice(roomIndex: 3, candidates: [])
        let resolved = state.resolvingRescan(replacing: "room-7")
        XCTAssertNil(resolved.pendingRescan)
        XCTAssertEqual(resolved.captures[0].idempotencyKey, "key-1")
    }

    func testPendingUploadKeepsTheQuestionThroughSaveAndLoad() throws {
        var state = PendingUploadState(session: nil, identity: identity, captures: [.init(idempotencyKey: "key-1", bodyJSON: try captureBody(floor: "Ground"))])
        let choice = StoredRescanChoice(roomIndex: 0, candidates: [RescanCandidate(roomId: "room-7", name: "Kitchen", floorAreaM2: 12)])
        state.pendingRescan = choice
        let decoded = try JSONDecoder().decode(PendingUploadState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.pendingRescan, choice)
    }

    func testPendingUploadSavedBeforeThisChangeStillLoads() throws {
        let state = PendingUploadState(session: nil, identity: identity, captures: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "pendingRescan")
        let decoded = try JSONDecoder().decode(PendingUploadState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.pendingRescan)
    }

    func testWalkthroughReplaceChoiceIsWrittenIntoOnlyThatRoom() throws {
        let first = try JSONEncoder().encode(FakeCaptureGenerator.random())
        let second = try JSONEncoder().encode(FakeCaptureGenerator.random())
        let state = WalkthroughState(
            identity: identity,
            session: nil,
            rooms: [
                .init(exportJSON: first, floor: "Ground", label: "Room 1"),
                .init(exportJSON: second, floor: "Attic", label: "Room 2")
            ],
            startedAt: Date(),
            pendingRescan: StoredRescanChoice(roomIndex: 1, candidates: [RescanCandidate(roomId: "room-7", name: "Kitchen", floorAreaM2: 12)])
        )
        let resolved = state.resolvingRescan(replacing: "room-7")
        XCTAssertNil(resolved.pendingRescan)
        XCTAssertNil(try JSONDecoder().decode(RoomPlanCaptureExport.self, from: resolved.rooms[0].exportJSON).replacesRoomId)
        XCTAssertEqual(try JSONDecoder().decode(RoomPlanCaptureExport.self, from: resolved.rooms[1].exportJSON).replacesRoomId, "room-7")
        XCTAssertEqual(resolved.rooms[1].floor, "Attic")
        XCTAssertEqual(resolved.rooms[1].label, "Room 2")
    }

    func testWalkthroughKeepsTheQuestionThroughSaveAndLoad() throws {
        let choice = StoredRescanChoice(roomIndex: 0, candidates: [RescanCandidate(roomId: "room-7", name: "Kitchen", floorAreaM2: 12)])
        let state = WalkthroughState(
            identity: identity,
            session: nil,
            rooms: [.init(exportJSON: try JSONEncoder().encode(FakeCaptureGenerator.random()), floor: "Ground", label: "Room 1")],
            startedAt: Date(),
            pendingRescan: choice
        )
        let decoded = try JSONDecoder().decode(WalkthroughState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.pendingRescan, choice)
    }

    func testNotesOnlyScanContinuesAsSingleRooms() {
        XCTAssertFalse(ContinueRoute.continuesAsUnit(rooms: [], floor: "Ground"))
        XCTAssertNil(ContinueRoute.joinTarget(rooms: [], floor: "Ground"))
        XCTAssertEqual(ContinueRoute.mapGroupIds(rooms: [], floor: "Ground"), [])
    }

    func testTwoFloorsPlacedByHandEachJoinTheirOwnFloor() throws {
        let rooms = try plan([("Ground", "walk-A"), ("Attic", "walk-B")])
        XCTAssertEqual(ContinueRoute.joinTarget(rooms: rooms, floor: "Ground"), "walk-A")
        XCTAssertEqual(ContinueRoute.joinTarget(rooms: rooms, floor: "Attic"), "walk-B")
        XCTAssertEqual(ContinueRoute.mapGroupIds(rooms: rooms, floor: "Ground"), ["walk-A"])
        XCTAssertEqual(ContinueRoute.mapGroupIds(rooms: rooms, floor: "Attic"), ["walk-B"])
    }

    func testRescanOnlyOffersRoomsOnTheSameFloor() throws {
        let rooms = try plan([("Ground", "walk-A"), ("Attic", "walk-B")])
        let attic = RescanMatcher.candidates(areaM2: 12.0, perimeterM: 14.0, roomType: nil, floor: "Attic", existing: rooms)
        XCTAssertEqual(attic.map(\.roomId), ["r1"])
    }
}
