import XCTest
@testable import VuuroScan

@MainActor
final class WorldMapStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFileNaming() async {
        let store = WorldMapStore(directory: tempDir)
        _ = store.saveFile(sessionId: "sess-1", groupId: "grp-A", data: Data([0x01]))
        let names = store.allFiles().map(\.lastPathComponent)
        XCTAssertEqual(names, ["sess-1_grp-A.arworldmap"])
    }

    func testSlashSanitised() async {
        let store = WorldMapStore(directory: tempDir)
        _ = store.saveFile(sessionId: "a/b", groupId: "c/d", data: Data([0x01]))
        let names = store.allFiles().map(\.lastPathComponent)
        XCTAssertEqual(names, ["a_b_c_d.arworldmap"])
    }

    func testPruningKeepsNewestFiveTotal() async throws {
        let store = WorldMapStore(directory: tempDir)
        for i in 0..<8 {
            _ = store.saveFile(sessionId: "s-\(i)", groupId: "g", data: Data([UInt8(i)]))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.allFiles().count, WorldMapStore.maxMapsTotal)
    }

    func testDeleteAllBySession() async {
        let store = WorldMapStore(directory: tempDir)
        _ = store.saveFile(sessionId: "sess-x", groupId: "a", data: Data([0x01]))
        _ = store.saveFile(sessionId: "sess-x", groupId: "b", data: Data([0x02]))
        _ = store.saveFile(sessionId: "sess-y", groupId: "c", data: Data([0x03]))
        store.deleteAll(sessionId: "sess-x")
        let remaining = store.allFiles().map(\.lastPathComponent)
        XCTAssertEqual(remaining, ["sess-y_c.arworldmap"])
    }

    func testDeleteSingle() async {
        let store = WorldMapStore(directory: tempDir)
        _ = store.saveFile(sessionId: "sess-x", groupId: "a", data: Data([0x01]))
        _ = store.saveFile(sessionId: "sess-x", groupId: "b", data: Data([0x02]))
        store.delete(sessionId: "sess-x", groupId: "a")
        XCTAssertEqual(store.allFiles().count, 1)
    }
}
