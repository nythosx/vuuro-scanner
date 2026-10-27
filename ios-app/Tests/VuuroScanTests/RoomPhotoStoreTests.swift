import XCTest
@testable import VuuroScan

@MainActor
final class RoomPhotoStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWalkPathsSurviveANewStore() throws {
        let paths: [[[Double]]] = [[[0.5, 0.5], [1.5, 0.5]], [[3.0, 2.0]]]
        try RoomPhotoStore(rootDirectory: tempDir).saveWalkPaths(paths, captureGroupId: "walk-1", roomKey: "room-a")
        let reopened = RoomPhotoStore(rootDirectory: tempDir)
        XCTAssertEqual(reopened.loadWalkPaths(captureGroupId: "walk-1", roomKey: "room-a"), paths)
        XCTAssertEqual(reopened.loadWalkPaths(captureGroupId: "walk-1", roomKey: "room-b"), [])
        XCTAssertEqual(try reopened.allBatches(captureGroupId: "walk-1"), [])
        reopened.clearAll(captureGroupId: "walk-1")
        XCTAssertEqual(reopened.loadWalkPaths(captureGroupId: "walk-1", roomKey: "room-a"), [])
    }

    func testSaveAndLoadOnePhoto() throws {
        let store = RoomPhotoStore(rootDirectory: tempDir)
        let metadata = RoomPhotoMetadata(
            localId: "photo-1",
            capturedAt: Date(timeIntervalSince1970: 1_000_000),
            positionM: [1.5, 2.5],
            headingDeg: 90,
            pitchDeg: 0
        )
        try store.savePhoto(
            Data([0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03]),
            metadata: metadata,
            captureGroupId: "walk-1",
            roomKey: "room-a",
            structureOriginM: [10.0, 20.0]
        )

        let manifest = try store.loadManifest(captureGroupId: "walk-1", roomKey: "room-a")
        XCTAssertEqual(manifest.captureGroupId, "walk-1")
        XCTAssertEqual(manifest.roomKey, "room-a")
        XCTAssertEqual(manifest.structureOriginM, [10.0, 20.0])
        XCTAssertEqual(manifest.photos.count, 1)
        XCTAssertEqual(manifest.photos[0].localId, "photo-1")
        XCTAssertEqual(manifest.photos[0].positionM, [1.5, 2.5])
        XCTAssertEqual(manifest.photos[0].headingDeg, 90)
    }

    func testSaveTwoPhotosKeepsBothInManifest() throws {
        let store = RoomPhotoStore(rootDirectory: tempDir)
        for index in 0..<2 {
            let metadata = RoomPhotoMetadata(
                localId: "photo-\(index)",
                capturedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
                positionM: [Double(index), Double(index)],
                headingDeg: Double(index) * 45,
                pitchDeg: 0
            )
            try store.savePhoto(
                Data([0xFF, 0xD8, 0xFF, UInt8(index)]),
                metadata: metadata,
                captureGroupId: "walk-1",
                roomKey: "room-a",
                structureOriginM: nil
            )
        }
        let manifest = try store.loadManifest(captureGroupId: "walk-1", roomKey: "room-a")
        XCTAssertEqual(manifest.photos.count, 2)
        XCTAssertEqual(manifest.photos.map(\.localId).sorted(), ["photo-0", "photo-1"])
    }

    func testDeletePhotoRemovesFileAndEntry() throws {
        let store = RoomPhotoStore(rootDirectory: tempDir)
        let metadata = RoomPhotoMetadata(
            localId: "photo-x",
            capturedAt: Date(),
            positionM: [0, 0],
            headingDeg: 0,
            pitchDeg: 0
        )
        try store.savePhoto(
            Data([0xFF, 0xD8]),
            metadata: metadata,
            captureGroupId: "walk-1",
            roomKey: "room-a",
            structureOriginM: nil
        )
        try store.deletePhoto(localId: "photo-x", captureGroupId: "walk-1", roomKey: "room-a")
        let manifest = try store.loadManifest(captureGroupId: "walk-1", roomKey: "room-a")
        XCTAssertEqual(manifest.photos.count, 0)
        XCTAssertThrowsError(try store.loadPhotoData(localId: "photo-x", captureGroupId: "walk-1", roomKey: "room-a"))
    }

    func testAllBatchesReturnsEveryRoomInACaptureGroup() throws {
        let store = RoomPhotoStore(rootDirectory: tempDir)
        for room in ["room-a", "room-b", "room-c"] {
            let metadata = RoomPhotoMetadata(
                localId: "photo-\(room)",
                capturedAt: Date(timeIntervalSince1970: Double(room == "room-a" ? 1 : room == "room-b" ? 2 : 3)),
                positionM: [0, 0],
                headingDeg: 0,
                pitchDeg: 0
            )
            try store.savePhoto(
                Data([0xFF]),
                metadata: metadata,
                captureGroupId: "walk-1",
                roomKey: room,
                structureOriginM: nil
            )
        }
        let batches = try store.allBatches(captureGroupId: "walk-1")
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches.map(\.roomKey), ["room-a", "room-b", "room-c"])
    }

    func testAllBatchesIsEmptyForUnknownCaptureGroup() throws {
        let store = RoomPhotoStore(rootDirectory: tempDir)
        XCTAssertEqual(try store.allBatches(captureGroupId: "walk-none"), [])
    }

    func testClearAllRemovesEverythingForACaptureGroup() throws {
        let store = RoomPhotoStore(rootDirectory: tempDir)
        let metadata = RoomPhotoMetadata(localId: "p1", capturedAt: Date(), positionM: [0, 0], headingDeg: 0, pitchDeg: 0)
        try store.savePhoto(Data([0xFF]), metadata: metadata, captureGroupId: "walk-1", roomKey: "room-a", structureOriginM: nil)
        try store.savePhoto(Data([0xFE]), metadata: metadata, captureGroupId: "walk-2", roomKey: "room-b", structureOriginM: nil)
        store.clearAll(captureGroupId: "walk-1")
        XCTAssertEqual(try store.allBatches(captureGroupId: "walk-1"), [])
        XCTAssertEqual(try store.allBatches(captureGroupId: "walk-2").count, 1)
    }
}
