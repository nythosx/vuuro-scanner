import ModelIO
import XCTest
@testable import VuuroScan

final class DollhouseUSDZExporterTests: XCTestCase {

    private func makeRooms(_ json: String) throws -> [FloorPlan.Room] {
        try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
    }

    private func roomJSON(id: String = "room-1", outline: String = "[[0,0],[4,0],[4,3],[0,3]]", origin: String = "[0, 0]") -> String {
        """
        {
          "room_id": "\(id)", "label": "\(id)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
          "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
          "confidence": "high", "outline_m": \(outline),
          "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
          "openings": [], "objects": [], "structure_origin_m": \(origin), "room_type": null,
          "floor": "Ground", "capture_group_id": null, "joined_to_group_id": null,
          "height_m": 2.6, "open_edges": []
        }
        """
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dollhouse-usdz-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testExportWritesAReadableFile() throws {
        let rooms = try makeRooms("[\(roomJSON())]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.usdz")

        try DollhouseUSDZExporter.export(scene, to: url, metadata: ["property_id": "prop-1"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 100)
    }

    func testExportedFileHasUSDZMagicBytes() throws {
        let rooms = try makeRooms("[\(roomJSON())]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.usdz")

        try DollhouseUSDZExporter.export(scene, to: url)

        let handle = try FileHandle(forReadingFrom: url)
        let header = handle.readData(ofLength: 4)
        try handle.close()
        XCTAssertEqual(header[0], 0x50)
        XCTAssertEqual(header[1], 0x4B)
    }

    func testExportedFileReloadsWithExpectedMeshCount() throws {
        let rooms = try makeRooms("[\(roomJSON(id: "room-a")),\(roomJSON(id: "room-b", origin: "[6, 0]"))]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.usdz")

        try DollhouseUSDZExporter.export(scene, to: url)

        let reloaded = MDLAsset(url: url)
        XCTAssertGreaterThan(reloaded.count, 0)

        var meshCount = 0
        func walk(_ object: MDLObject) {
            if object.components.contains(where: { $0 is MDLMesh }) { meshCount += 1 }
            for child in object.children.objects {
                walk(child)
            }
        }
        for index in 0..<reloaded.count {
            if let object = reloaded.object(at: index) as MDLObject? {
                walk(object)
            }
        }
        XCTAssertGreaterThan(meshCount, 0)
    }

    func testMetadataSurvivesRoundTrip() throws {
        let rooms = try makeRooms("[\(roomJSON())]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.usdz")

        try DollhouseUSDZExporter.export(scene, to: url, metadata: [
            "property_id": "prop-round-trip",
            "unit_id": "unit-2b",
            "measurement_basis": "indicative_nen2580_inspired",
        ])

        let reloaded = MDLAsset(url: url)
        let metadata = reloaded.metadata as? [String: Any]
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?["format"] as? String, "vuuro-dollhouse/1")
    }

    func testEmptySceneThrows() {
        let emptyScene = DollhouseScene(
            meshes: [],
            boundsMin: SIMD3<Float>(repeating: 0),
            boundsMax: SIMD3<Float>(repeating: 0),
            roomCount: 0,
            floorSections: [],
            usedEstimatedHeight: false
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dollhouse-empty-\(UUID().uuidString).usdz")
        XCTAssertThrowsError(try DollhouseUSDZExporter.export(emptyScene, to: dir))
    }

    func testLargerSceneStaysUnderSizeBudget() throws {
        var items: [String] = []
        for index in 0..<5 {
            items.append(roomJSON(id: "room-\(index)", origin: "[\(index * 5), 0]"))
        }
        let rooms = try makeRooms("[" + items.joined(separator: ",") + "]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.usdz")

        try DollhouseUSDZExporter.export(scene, to: url)

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(size, 10 * 1024 * 1024)
    }
}
