import XCTest
@testable import VuuroScan

@MainActor
final class RoomPhotoUploaderTests: XCTestCase {

    private func room(_ id: String, origin: [Double]?, group: String? = nil, joined: String? = nil) throws -> FloorPlan.Room {
        try JSONDecoder().decode(FloorPlan.Room.self, from: Data(roomJSON(id, origin: origin, group: group, joined: joined).utf8))
    }

    private func roomJSON(_ id: String, origin: [Double]? = nil, group: String? = nil, joined: String? = nil) -> String {
        let originJSON = origin.map { "[\($0[0]), \($0[1])]" } ?? "null"
        let groupJSON = group.map { "\"\($0)\"" } ?? "null"
        let joinedJSON = joined.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "room_id": "\(id)", "label": "\(id)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
          "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
          "confidence": "high", "outline_m": [[0,0],[4,0],[4,3],[0,3]],
          "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
          "openings": [], "objects": [], "structure_origin_m": \(originJSON), "room_type": null,
          "floor": "Ground", "capture_group_id": \(groupJSON), "joined_to_group_id": \(joinedJSON)
        }
        """
        return json
    }

    private static func planJSON(rooms: [String]) -> String {
        """
        {
          "scan_session_id": "s-1", "property_id": "p-1", "unit_id": "u-1", "organisation_id": "o-1",
          "capture_provider": "roomplan", "captured_at": "2026-10-22T10:00:00+00:00",
          "measurement_basis": "indicative_nen2580_inspired", "purpose": "listing",
          "rooms": [\(rooms.joined(separator: ","))],
          "photos": [], "notes": [], "capture_location": null
        }
        """
    }

    private func batch(_ roomKey: String, origin: [Double]?, group: String = "walk-1") -> RoomPhotoManifest {
        RoomPhotoManifest(
            captureGroupId: group,
            roomKey: roomKey,
            structureOriginM: origin,
            capturedAt: Date(timeIntervalSince1970: 0),
            photos: []
        )
    }

    func testRoomsForCaptureGroupMatchesRoomsJoinedIntoThisGroup() throws {
        let rooms = [
            try room("r1", origin: [0.0, 0.0], group: "walk-1"),
            try room("r2", origin: [1.0, 0.0], group: "walk-2", joined: "walk-1"),
            try room("r3", origin: [2.0, 0.0], group: "walk-3"),
            try room("r4", origin: [3.0, 0.0], group: nil, joined: "walk-1"),
        ]
        let matched = RoomPhotoUploader.roomsForCaptureGroup(rooms, captureGroupId: "walk-1")
        XCTAssertEqual(matched.map(\.roomId), ["r1", "r2", "r4"])
    }

    func testOptimalAssignmentFindsTheOnlyValidPairing() throws {
        let batchA = batch("a", origin: [0.005, 0.0])
        let batchB = batch("b", origin: [0.015, 0.0])
        let room1 = try room("room-1", origin: [0.0, 0.0])
        let room2 = try room("room-2", origin: [0.01, 0.0])
        let result = RoomPhotoUploader.pairByStructureOrigin(
            batches: [batchA, batchB],
            serverRooms: [room2, room1]
        )
        XCTAssertNotNil(result, "A→room-1 and B→room-2 is the only pairing within 1cm of both origins; the solver must find it even when room-2 is listed first")
        XCTAssertEqual(result?.map(\.roomId), ["room-1", "room-2"])
    }

    func testOptimalAssignmentReturnsNilWhenBothBatchesShareOneRoom() throws {
        let batchA = batch("a", origin: [0.0, 0.0])
        let batchB = batch("b", origin: [0.001, 0.0])
        let room1 = try room("room-1", origin: [0.0, 0.0])
        let room2 = try room("room-2", origin: [10.0, 0.0])
        let result = RoomPhotoUploader.pairByStructureOrigin(
            batches: [batchA, batchB],
            serverRooms: [room1, room2]
        )
        XCTAssertNil(result, "only room-1 is within 1cm of either batch, so no bijection exists")
    }

    func testLargeBatchFallsBackToGreedyAndRefusesAmbiguity() throws {
        var batches: [RoomPhotoManifest] = []
        var rooms: [FloorPlan.Room] = []
        for i in 0..<10 {
            let offset = Double(i) * 0.1
            batches.append(batch("b\(i)", origin: [offset, 0.0]))
            rooms.append(try room("r\(i)", origin: [offset, 0.0]))
        }
        let clean = RoomPhotoUploader.pairByStructureOrigin(batches: batches, serverRooms: rooms)
        XCTAssertNotNil(clean)
        XCTAssertEqual(clean?.count, 10)

        var ambiguous = rooms
        ambiguous[0] = try room("r0", origin: [0.05, 0.0])
        let ambiguousResult = RoomPhotoUploader.pairByStructureOrigin(batches: batches, serverRooms: ambiguous)
        XCTAssertNil(ambiguousResult, "batch 0 and batch 5 are both within 1cm of room 0 after the shift, so the greedy fallback must refuse")
    }

    func testPairingRefusesWhenBatchAndRoomCountsDiffer() throws {
        let batchA = batch("a", origin: [0.0, 0.0])
        let room1 = try room("room-1", origin: [0.0, 0.0])
        let room2 = try room("room-2", origin: [1.0, 0.0])
        XCTAssertNil(RoomPhotoUploader.pairByStructureOrigin(batches: [batchA], serverRooms: [room1, room2]))
    }

    func testPairingRefusesWhenABatchHasNoOrigin() throws {
        let batchA = batch("a", origin: nil)
        let room1 = try room("room-1", origin: [0.0, 0.0])
        XCTAssertNil(RoomPhotoUploader.pairByStructureOrigin(batches: [batchA], serverRooms: [room1]))
    }

    func testSingleRoomScanPairsEvenWhenTheServerRoomHasNoOrigin() throws {
        let batchA = batch("a", origin: [1.234, -0.5])
        let room1 = try room("room-01-floor", origin: nil, group: "walk-1")
        let result = RoomPhotoUploader.pair(batches: [batchA], serverRooms: [room1])
        XCTAssertEqual(result?.map(\.roomId), ["room-01-floor"])
    }

    func testSingleRoomScanPairsWhenTheBatchHasNoOrigin() throws {
        let batchA = batch("a", origin: nil)
        let room1 = try room("room-1", origin: [0.0, 0.0])
        XCTAssertEqual(RoomPhotoUploader.pair(batches: [batchA], serverRooms: [room1])?.map(\.roomId), ["room-1"])
    }

    func testRoomsWithoutOriginPairInCaptureOrder() throws {
        let batches = [batch("a", origin: [0.0, 0.0]), batch("b", origin: [5.0, 0.0])]
        let rooms = [try room("room-1", origin: nil), try room("room-2", origin: nil)]
        XCTAssertEqual(RoomPhotoUploader.pair(batches: batches, serverRooms: rooms)?.map(\.roomId), ["room-1", "room-2"])
    }

    func testMultiRoomWithMismatchedOriginsStillRefuses() throws {
        let batches = [batch("a", origin: [0.0, 0.0]), batch("b", origin: [5.0, 0.0])]
        let rooms = [try room("room-1", origin: [2.0, 0.0]), try room("room-2", origin: [9.0, 0.0])]
        XCTAssertNil(RoomPhotoUploader.pair(batches: batches, serverRooms: rooms))
    }

    func testPendingPhotoCountFindsPhotosLeftOnThePhone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RoomPhotoStore(rootDirectory: dir)
        for index in 0..<3 {
            try store.savePhoto(
                Data([0xFF, 0xD8, 0xFF]),
                metadata: RoomPhotoMetadata(localId: "p\(index)", capturedAt: Date(), positionM: [1, 1], headingDeg: 0, pitchDeg: 0),
                captureGroupId: "walk-1",
                roomKey: "room-key",
                structureOriginM: nil
            )
        }
        let plan = try JSONDecoder().decode(FloorPlan.self, from: Data(Self.planJSON(rooms: [roomJSON("room-1", group: "walk-1"), roomJSON("room-2", group: "walk-9")]).utf8))
        XCTAssertEqual(RoomPhotoUploader.pendingPhotoCount(floorPlan: plan, store: store), ["walk-1": 3])
        store.clearAll(captureGroupId: "walk-1")
        XCTAssertEqual(RoomPhotoUploader.pendingPhotoCount(floorPlan: plan, store: store), [:])
    }

    func testPairingReportsHowBatchesWereMatched() throws {
        let single = RoomPhotoUploader.pairWithMethod(
            batches: [batch("a", origin: [3.0, 3.0])],
            serverRooms: [try room("room-1", origin: nil)]
        )
        XCTAssertEqual(single?.method, "single_room")

        let byOrigin = RoomPhotoUploader.pairWithMethod(
            batches: [batch("a", origin: [0.0, 0.0]), batch("b", origin: [5.0, 0.0])],
            serverRooms: [try room("room-1", origin: [0.0, 0.0]), try room("room-2", origin: [5.0, 0.0])]
        )
        XCTAssertEqual(byOrigin?.method, "origin")

        let inOrder = RoomPhotoUploader.pairWithMethod(
            batches: [batch("a", origin: [0.0, 0.0]), batch("b", origin: [5.0, 0.0])],
            serverRooms: [try room("room-1", origin: nil), try room("room-2", origin: nil)]
        )
        XCTAssertEqual(inOrder?.method, "capture_order")
    }

    func testPhotoStepSummaryEncodesWhatAdminShows() throws {
        let trace = RoomPhotoUploadTrace()
        var manifest = batch("room-key", origin: nil)
        manifest.photos = [
            RoomPhotoMetadata(localId: "p1", capturedAt: Date(), positionM: [1, 1], headingDeg: 0, pitchDeg: 0),
            RoomPhotoMetadata(localId: "p2", capturedAt: Date(), positionM: [2, 1], headingDeg: 90, pitchDeg: 0),
        ]
        manifest.finishCoverage = RoomPhotoFinishCoverage(
            overall: 0.66, position: 0.57, walls: 0.75, ready: false,
            wallsTotal: 8, wallsCovered: 6, cellsTotal: 62, cellsCovered: 35
        )
        trace.batches = [manifest]
        trace.serverRoomCount = 1
        trace.pairing = "single_room"
        trace.failures = [PhotoStepSummary.Failure(photoId: "p2", reason: "The request timed out.")]
        let outcome = RoomPhotoUploadOutcome(batchesConsidered: 1, photosUploaded: 1, photosFailed: 1, skipReason: nil)

        let summary = RoomPhotoUploader.summary(captureGroupId: "walk-1", trigger: "after_scan", trace: trace, outcome: outcome)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])

        XCTAssertEqual(json["photos_taken"] as? Int, 2)
        XCTAssertEqual(json["photos_uploaded"] as? Int, 1)
        XCTAssertEqual(json["photos_failed"] as? Int, 1)
        XCTAssertEqual(json["pairing"] as? String, "single_room")
        XCTAssertEqual(json["server_room_count"] as? Int, 1)
        XCTAssertEqual(json["capture_group_id"] as? String, "walk-1")
        XCTAssertEqual(json["trigger"] as? String, "after_scan")
        XCTAssertNotNil(json["build"] as? String)
        let failures = try XCTUnwrap(json["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.first?["photo_id"] as? String, "p2")
        let rooms = try XCTUnwrap(json["rooms"] as? [[String: Any]])
        let coverage = try XCTUnwrap(rooms.first?["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["walls_total"] as? Int, 8)
        XCTAssertEqual(coverage["walls_covered"] as? Int, 6)
        XCTAssertEqual(coverage["ready"] as? Bool, false)
    }

    func testCoverageAtFinishIsSavedWithThePhotos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RoomPhotoStore(rootDirectory: dir)
        let coverage = RoomPhotoFinishCoverage(
            overall: 0.5, position: 0.5, walls: 0.5, ready: false,
            wallsTotal: 4, wallsCovered: 2, cellsTotal: 12, cellsCovered: 6
        )
        try store.saveFinishCoverage(coverage, captureGroupId: "walk-1", roomKey: "nothing-yet")
        XCTAssertEqual(try store.allBatches(captureGroupId: "walk-1"), [])

        try store.savePhoto(
            Data([0xFF, 0xD8, 0xFF]),
            metadata: RoomPhotoMetadata(localId: "p1", capturedAt: Date(), positionM: [1, 1], headingDeg: 0, pitchDeg: 0),
            captureGroupId: "walk-1",
            roomKey: "room-key",
            structureOriginM: nil
        )
        try store.saveFinishCoverage(coverage, captureGroupId: "walk-1", roomKey: "room-key")
        let saved = try store.allBatches(captureGroupId: "walk-1")
        XCTAssertEqual(saved.first?.finishCoverage, coverage)
        XCTAssertEqual(saved.first?.photos.count, 1)
    }

    func testPermutationsProducesFactorialCounts() {
        XCTAssertEqual(RoomPhotoUploader.permutations([Int]()).count, 1)
        XCTAssertEqual(RoomPhotoUploader.permutations([1]).count, 1)
        XCTAssertEqual(RoomPhotoUploader.permutations([1, 2, 3]).count, 6)
        XCTAssertEqual(RoomPhotoUploader.permutations([1, 2, 3, 4]).count, 24)
    }
}
