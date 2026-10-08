import XCTest
import simd
@testable import VuuroScan

final class DollhouseMeshBuilderTests: XCTestCase {

    private func makeRooms(_ json: String) throws -> [FloorPlan.Room] {
        try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
    }

    private func roomJSON(
        id: String = "room-1",
        outline: String = "[[0,0],[4,0],[4,3],[0,3]]",
        height: String = "2.6",
        origin: String? = "null",
        openEdges: String = "[]",
        openings: String = "[]",
        objects: String = "[]",
        floor: String = "Ground"
    ) -> String {
        let originValue = origin ?? "null"
        return """
        {
          "room_id": "\(id)", "label": "\(id)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
          "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
          "confidence": "high", "outline_m": \(outline),
          "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
          "openings": \(openings), "objects": \(objects), "structure_origin_m": \(originValue), "room_type": null,
          "floor": "\(floor)", "capture_group_id": null, "joined_to_group_id": null,
          "height_m": \(height), "open_edges": \(openEdges)
        }
        """
    }

    func testSingleRoomBoundsMatchOutline() throws {
        let rooms = try makeRooms("[\(roomJSON())]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertEqual(scene.roomCount, 1)
        XCTAssertFalse(scene.isEmpty)
        XCTAssertEqual(scene.boundsMin.x, 0, accuracy: 0.05)
        XCTAssertEqual(scene.boundsMin.y, 0, accuracy: 0.05)
        XCTAssertEqual(scene.boundsMax.x, 4, accuracy: 0.05)
        XCTAssertEqual(scene.boundsMax.z, 3, accuracy: 0.05)
        XCTAssertEqual(scene.boundsMax.y, 2.6, accuracy: 0.05)
    }

    func testNullHeightUsesDefaultAndFlagsEstimate() throws {
        let rooms = try makeRooms("[\(roomJSON(height: "null"))]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertTrue(scene.usedEstimatedHeight)
        XCTAssertEqual(scene.boundsMax.y, DollhouseConstants.defaultHeightM, accuracy: 0.05)
    }

    func testCutawayClipsWallHeight() throws {
        let rooms = try makeRooms("[\(roomJSON(height: "2.6"))]")
        let configuration = DollhouseBuildConfiguration(mode: .cutaway)
        let scene = try DollhouseMeshBuilder.build(rooms: rooms, configuration: configuration)
        XCTAssertEqual(scene.boundsMax.y, DollhouseConstants.cutawayHeightM, accuracy: 0.05)
    }

    func testDollhouseKeepsFullHeight() throws {
        let rooms = try makeRooms("[\(roomJSON(height: "2.6"))]")
        let configuration = DollhouseBuildConfiguration(mode: .dollhouse)
        let scene = try DollhouseMeshBuilder.build(rooms: rooms, configuration: configuration)
        XCTAssertEqual(scene.boundsMax.y, 2.6, accuracy: 0.05)
    }

    func testEmptyRoomsThrows() {
        XCTAssertThrowsError(try DollhouseMeshBuilder.build(rooms: []))
    }

    func testDegenerateRoomProducesNoGeometry() throws {
        let rooms = try makeRooms("[\(roomJSON(outline: "[[0,0],[0,0],[0,0]]"))]")
        XCTAssertThrowsError(try DollhouseMeshBuilder.build(rooms: rooms))
    }

    func testOpenEdgeOmitsWall() throws {
        let closedRooms = try makeRooms("[\(roomJSON())]")
        let openRooms = try makeRooms("[\(roomJSON(openEdges: "[0]"))]")
        let closedScene = try DollhouseMeshBuilder.build(rooms: closedRooms)
        let openScene = try DollhouseMeshBuilder.build(rooms: openRooms)
        XCTAssertGreaterThan(closedScene.totalTriangles, openScene.totalTriangles)
    }

    func testTwoRoomsWithOriginShareFrame() throws {
        let first = roomJSON(id: "room-a", origin: "[0, 0]")
        let second = roomJSON(id: "room-b", origin: "[6, 0]")
        let rooms = try makeRooms("[\(first),\(second)]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertEqual(scene.roomCount, 2)
        XCTAssertEqual(scene.floorSections.count, 1)
        XCTAssertGreaterThan(scene.boundsMax.x, 6)
    }

    func testTwoRoomsWithoutOriginBecomeSeparateSections() throws {
        let first = roomJSON(id: "room-a", origin: "null")
        let second = roomJSON(id: "room-b", origin: "null")
        let rooms = try makeRooms("[\(first),\(second)]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertEqual(scene.floorSections.count, 2)
    }

    func testMultiFloorCreatesSeparateSections() throws {
        let ground = roomJSON(id: "room-ground", origin: "[0, 0]", floor: "Ground")
        let attic = roomJSON(id: "room-attic", origin: "[0, 0]", floor: "Attic")
        let rooms = try makeRooms("[\(ground),\(attic)]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertEqual(scene.floorSections.count, 2)
        XCTAssertEqual(scene.floorSections[0].title, "Attic")
        XCTAssertEqual(scene.floorSections[1].title, "Ground")
    }

    func testFurnitureAddsTriangles() throws {
        let noFurniture = try makeRooms("[\(roomJSON())]")
        let withFurniture = try makeRooms("[\(roomJSON(objects: "[{\"object_id\":\"o1\",\"category\":\"sofa\",\"position_m\":[2,1.5],\"dimensions_m\":[2,0.8,0.9],\"confidence\":\"high\",\"custom_name\":null,\"excluded\":false}]"))]")
        let sceneA = try DollhouseMeshBuilder.build(rooms: noFurniture)
        let sceneB = try DollhouseMeshBuilder.build(rooms: withFurniture)
        XCTAssertGreaterThan(sceneB.totalTriangles, sceneA.totalTriangles)
    }

    func testPerformanceModeDropsFurniture() throws {
        var items: [String] = []
        for index in 0..<20 {
            items.append(roomJSON(id: "room-\(index)", origin: "[\(index * 5), 0]"))
        }
        let rooms = try makeRooms("[" + items.joined(separator: ",") + "]")
        let configuration = DollhouseBuildConfiguration(showFurniture: true, performanceMode: true)
        let scene = try DollhouseMeshBuilder.build(rooms: rooms, configuration: configuration)
        XCTAssertEqual(scene.roomCount, 20)
        XCTAssertFalse(scene.isEmpty)
    }

    func testOpeningFrameAddsTriangles() throws {
        let plain = try makeRooms("[\(roomJSON())]")
        let withDoor = try makeRooms("[\(roomJSON(openings: "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[2,0],\"confidence\":\"high\"}]"))]")
        let scenePlain = try DollhouseMeshBuilder.build(rooms: plain)
        let sceneDoor = try DollhouseMeshBuilder.build(rooms: withDoor)
        XCTAssertGreaterThan(sceneDoor.totalTriangles, scenePlain.totalTriangles)
    }

    func testOpeningFarFromWallIsSkipped() throws {
        let rooms = try makeRooms("[\(roomJSON(openings: "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[2,1.5],\"confidence\":\"high\"}]"))]")
        let base = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON())]"))
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertEqual(scene.totalTriangles, base.totalTriangles)
    }

    func testLShapedRoomTriangulates() throws {
        let outline = "[[0,0],[4,0],[4,1.8],[2.5,1.8],[2.5,3],[0,3]]"
        let rooms = try makeRooms("[\(roomJSON(outline: outline))]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertFalse(scene.isEmpty)
        XCTAssertGreaterThan(scene.totalTriangles, 24)
    }

    func testBoundsFiniteForAllFixtures() throws {
        let outline = "[[0,0],[4,0],[4,3],[0,3]]"
        let rooms = try makeRooms("[\(roomJSON(outline: outline, origin: "[100, -50]"))]")
        let scene = try DollhouseMeshBuilder.build(rooms: rooms)
        XCTAssertTrue(scene.boundsMin.x.isFinite)
        XCTAssertTrue(scene.boundsMax.x.isFinite)
        XCTAssertTrue(scene.boundsMax.z.isFinite)
    }

    private func triangles(of mesh: DollhouseMesh) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        stride(from: 0, to: mesh.indices.count, by: 3).map { start in
            (
                mesh.vertices[Int(mesh.indices[start])].position,
                mesh.vertices[Int(mesh.indices[start + 1])].position,
                mesh.vertices[Int(mesh.indices[start + 2])].position
            )
        }
    }

    private func meshes(_ scene: DollhouseScene, named prefix: String) -> [DollhouseMesh] {
        scene.meshes.filter { ($0.path.components.last ?? "").hasPrefix(prefix) }
    }

    func testWallFacesPointOutOfTheWallAndFloorsFaceUpForBothWindings() throws {
        let outlines = [
            "[[0,0],[4,0],[4,3],[0,3]]",
            "[[0,0],[0,3],[4,3],[4,0]]",
            "[[0,0],[4,0],[4,1.8],[2.5,1.8],[2.5,3],[0,3]]",
        ]
        for outline in outlines {
            let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(outline: outline))]"))
            let walls = meshes(scene, named: "Wall-")
            XCTAssertFalse(walls.isEmpty, outline)
            for wall in walls {
                let center = wall.vertices.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.position } / Float(wall.vertices.count)
                for (a, b, c) in triangles(of: wall) {
                    let normal = simd_cross(b - a, c - a)
                    let centroid = (a + b + c) / 3
                    XCTAssertGreaterThan(simd_dot(normal, centroid - center), 0, "wall face points into the wall for outline \(outline)")
                }
            }
            let floors = meshes(scene, named: "Floor")
            XCTAssertEqual(floors.count, 1, outline)
            for floor in floors {
                XCTAssertFalse(triangles(of: floor).isEmpty, outline)
                for (a, b, c) in triangles(of: floor) {
                    XCTAssertGreaterThan(simd_cross(b - a, c - a).y, 0, "floor triangle faces down for outline \(outline)")
                }
            }
        }
    }

    func testDoorSitsAtItsCapturedPositionAndWidth() throws {
        let opening = "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[1.0,0.05],\"width_m\":0.8,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: opening))]"))
        let doors = meshes(scene, named: "Opening-d1")
        XCTAssertEqual(doors.count, 1)
        let xs = doors[0].vertices.map(\.position.x)
        let zs = doors[0].vertices.map(\.position.z)
        let centerX = (xs.min()! + xs.max()!) / 2
        let centerZ = (zs.min()! + zs.max()!) / 2
        XCTAssertEqual(centerX, 1.0, accuracy: 0.01)
        XCTAssertEqual(centerZ, 0.0, accuracy: 0.01)
        XCTAssertEqual(xs.max()! - xs.min()!, 0.8, accuracy: 0.01)
    }

    func testSectionsDoNotOverlapWhenAFusedFloorHasNegativeOrigins() throws {
        let attic = roomJSON(id: "room-attic", origin: "[0, 0]", floor: "Attic")
        let ground = roomJSON(id: "room-ground", origin: "[0, -5]", floor: "Ground")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(attic),\(ground)]"))
        XCTAssertEqual(scene.floorSections.map(\.title), ["Attic", "Ground"])
        func zRange(_ roomId: String) -> (Float, Float) {
            let zs = scene.meshes.filter { $0.path.components.contains("Room-\(roomId)") }.flatMap { $0.vertices.map(\.position.z) }
            return (zs.min()!, zs.max()!)
        }
        let atticRange = zRange("room-attic")
        let groundRange = zRange("room-ground")
        XCTAssertLessThan(atticRange.1, groundRange.0)
    }
}
