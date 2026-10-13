import XCTest
@testable import VuuroScan

@MainActor
final class RoomPhotoUploaderTests: XCTestCase {

    private func room(_ id: String, origin: [Double]?, group: String? = nil, joined: String? = nil) throws -> FloorPlan.Room {
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
        return try JSONDecoder().decode(FloorPlan.Room.self, from: Data(json.utf8))
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

    func testPermutationsProducesFactorialCounts() {
        XCTAssertEqual(RoomPhotoUploader.permutations([Int]()).count, 1)
        XCTAssertEqual(RoomPhotoUploader.permutations([1]).count, 1)
        XCTAssertEqual(RoomPhotoUploader.permutations([1, 2, 3]).count, 6)
        XCTAssertEqual(RoomPhotoUploader.permutations([1, 2, 3, 4]).count, 24)
    }
}
