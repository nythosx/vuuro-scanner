import XCTest
import simd
@testable import VuuroScan

final class DollhouseWallTexturingTests: XCTestCase {
    private func rooms(_ json: String) throws -> [FloorPlan.Room] {
        try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
    }

    private func roomJSON(
        id: String = "room-1",
        outline: String = "[[0,0],[4,0],[4,3],[0,3]]",
        height: String = "2.6",
        headingDeg: String = "0.0"
    ) -> String {
        """
        {
          "room_id": "\(id)", "label": "\(id)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
          "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
          "confidence": "high", "outline_m": \(outline),
          "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
          "openings": [], "objects": [], "structure_origin_m": null, "room_type": null,
          "floor": "Ground", "capture_group_id": null, "joined_to_group_id": null,
          "height_m": \(height), "open_edges": [], "heading_deg": \(headingDeg)
        }
        """
    }

    private func photo(roomId: String, position: [Double], headingDeg: Double) -> FloorPlan.Photo360 {
        FloorPlan.Photo360(
            photoId: "p1",
            roomId: roomId,
            url: "test://room/photo.jpg",
            positionM: position,
            headingDeg: headingDeg,
            capturedAt: "2026-10-14T00:00:00Z"
        )
    }

    private func texturedVertexCount(_ scene: DollhouseScene) -> Int {
        scene.meshes.reduce(0) { total, mesh in
            total + mesh.vertices.filter { $0.uv != nil }.count
        }
    }

    private func texturedMaterialCount(_ scene: DollhouseScene) -> Int {
        scene.meshes.filter { $0.material.imageData != nil }.count
    }

    func testNoPhotosMeansNoTexture() throws {
        let plan = try rooms("[\(roomJSON())]")
        let scene = try DollhouseMeshBuilder.build(rooms: plan, configuration: DollhouseBuildConfiguration(mode: .dollhouse))
        XCTAssertEqual(texturedMaterialCount(scene), 0)
        XCTAssertEqual(texturedVertexCount(scene), 0)
        XCTAssertFalse(scene.meshes.isEmpty)
    }

    func testPhotoFacingOneWallTexturesThatWall() throws {
        let plan = try rooms("[\(roomJSON())]")
        let wallPhoto = photo(roomId: "room-1", position: [2.0, 0.5], headingDeg: 0.0)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let scene = try DollhouseMeshBuilder.build(
            rooms: plan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse),
            photos360: [wallPhoto],
            photoBytesByURL: ["test://room/photo.jpg": bytes]
        )
        XCTAssertGreaterThan(texturedMaterialCount(scene), 0)
        XCTAssertGreaterThan(texturedVertexCount(scene), 0)
        XCTAssertGreaterThan(texturedVertexCount(scene), 0)
        for mesh in scene.meshes where mesh.material.imageData != nil {
            XCTAssertEqual(mesh.material.imageData, bytes)
            XCTAssertEqual(mesh.vertices.count, 4)
            for vertex in mesh.vertices {
                XCTAssertNotNil(vertex.uv)
            }
        }
    }

    func testPhotoFacingAwayLeavesEverythingFlat() throws {
        let plan = try rooms("[\(roomJSON())]")
        let awayPhoto = photo(roomId: "room-1", position: [2.0, 1.5], headingDeg: 90.0)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let scene = try DollhouseMeshBuilder.build(
            rooms: plan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse),
            photos360: [awayPhoto],
            photoBytesByURL: ["test://room/photo.jpg": bytes]
        )
        XCTAssertEqual(texturedMaterialCount(scene), 0)
        XCTAssertEqual(texturedVertexCount(scene), 0)
    }

    func testRoomWithoutHeadingDegLeavesEverythingFlat() throws {
        let plan = try rooms("[\(roomJSON(headingDeg: "null"))]")
        let wallPhoto = photo(roomId: "room-1", position: [2.0, 0.5], headingDeg: 0.0)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let scene = try DollhouseMeshBuilder.build(
            rooms: plan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse),
            photos360: [wallPhoto],
            photoBytesByURL: ["test://room/photo.jpg": bytes]
        )
        XCTAssertEqual(texturedMaterialCount(scene), 0)
        XCTAssertEqual(texturedVertexCount(scene), 0)
    }

    func testPhotoWithoutBytesLeavesEverythingFlat() throws {
        let plan = try rooms("[\(roomJSON())]")
        let wallPhoto = photo(roomId: "room-1", position: [2.0, 0.5], headingDeg: 0.0)
        let scene = try DollhouseMeshBuilder.build(
            rooms: plan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse),
            photos360: [wallPhoto],
            photoBytesByURL: [:]
        )
        XCTAssertEqual(texturedMaterialCount(scene), 0)
        XCTAssertEqual(texturedVertexCount(scene), 0)
    }

    func testTexturingIsUnaffectedByOutlineNotStartingAtOrigin() throws {
        let shiftedPlan = try rooms("[\(roomJSON(outline: "[[0,5],[4,5],[4,8],[0,8]]"))]")
        let shiftedPhoto = photo(roomId: "room-1", position: [2.0, 5.5], headingDeg: 0.0)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let scene = try DollhouseMeshBuilder.build(
            rooms: shiftedPlan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse),
            photos360: [shiftedPhoto],
            photoBytesByURL: ["test://room/photo.jpg": bytes]
        )
        XCTAssertGreaterThan(texturedMaterialCount(scene), 0)
        XCTAssertGreaterThan(texturedVertexCount(scene), 0)
    }

    func testPerformanceModeSuppressesTexturing() throws {
        let plan = try rooms("[\(roomJSON())]")
        let wallPhoto = photo(roomId: "room-1", position: [2.0, 0.5], headingDeg: 0.0)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let scene = try DollhouseMeshBuilder.build(
            rooms: plan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse, performanceMode: true),
            photos360: [wallPhoto],
            photoBytesByURL: ["test://room/photo.jpg": bytes]
        )
        XCTAssertEqual(texturedMaterialCount(scene), 0)
        XCTAssertEqual(texturedVertexCount(scene), 0)
    }

    func testTexturedSceneHasMoreMeshesThanFlatScene() throws {
        let plan = try rooms("[\(roomJSON())]")
        let wallPhoto = photo(roomId: "room-1", position: [2.0, 0.5], headingDeg: 0.0)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let flat = try DollhouseMeshBuilder.build(rooms: plan, configuration: DollhouseBuildConfiguration(mode: .dollhouse))
        let textured = try DollhouseMeshBuilder.build(
            rooms: plan,
            configuration: DollhouseBuildConfiguration(mode: .dollhouse),
            photos360: [wallPhoto],
            photoBytesByURL: ["test://room/photo.jpg": bytes]
        )
        XCTAssertGreaterThan(textured.meshes.count, flat.meshes.count)
    }
}
