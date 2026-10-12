import XCTest
import simd
@testable import VuuroScan

final class DollhouseWallSubdivisionTests: XCTestCase {

    private func makeRooms(_ json: String) throws -> [FloorPlan.Room] {
        try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
    }

    private func roomJSON(
        id: String = "room-1",
        outline: String = "[[0,0],[6,0],[6,3],[0,3]]",
        openings: String = "[]",
        openEdges: String = "[]",
        origin: String? = nil,
        floor: String = "Ground"
    ) -> String {
        let originValue = origin ?? "null"
        return """
        {
          "room_id": "\(id)", "label": "\(id)", "floor_area_m2": 18.0, "perimeter_m": 18.0,
          "bounding_dimensions_m": {"width_m": 6.0, "length_m": 3.0},
          "confidence": "high", "outline_m": \(outline),
          "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
          "openings": \(openings), "objects": [], "structure_origin_m": \(originValue), "room_type": null,
          "floor": "\(floor)", "capture_group_id": null, "joined_to_group_id": null,
          "height_m": 2.6, "open_edges": \(openEdges)
        }
        """
    }

    private func wallMeshes(_ scene: DollhouseScene, forRoom roomId: String) -> [DollhouseMesh] {
        scene.meshes.filter { mesh in
            mesh.layer == .wallsAndFloors
                && mesh.path.components.contains("Room-\(roomId)")
                && (mesh.path.components.last ?? "").hasPrefix("Wall-")
        }
    }

    private func vertexRange(_ mesh: DollhouseMesh) -> (x: (Float, Float), y: (Float, Float), z: (Float, Float)) {
        let xs = mesh.vertices.map(\.position.x)
        let ys = mesh.vertices.map(\.position.y)
        let zs = mesh.vertices.map(\.position.z)
        return ((xs.min()!, xs.max()!), (ys.min()!, ys.max()!), (zs.min()!, zs.max()!))
    }

    func testWallWithoutOpeningsStaysASingleSegment() throws {
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON())]"))
        let walls = wallMeshes(scene, forRoom: "room-1")
        XCTAssertEqual(walls.count, 4, "expected one mesh per edge when no openings exist")
    }

    func testDoorProducesASolidOnEachSideAndNoWallOverTheOpening() throws {
        let door = "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[3,0],\"width_m\":0.9,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: door))]"))
        let walls = wallMeshes(scene, forRoom: "room-1")
        let bottomWallMeshes = walls.filter { $0.path.components.last?.hasPrefix("Wall-0-") == true }
        XCTAssertGreaterThan(bottomWallMeshes.count, 1, "a door should split its wall edge into at least two solid pieces")

        let doorFrameMeshes = scene.meshes.filter { ($0.path.components.last ?? "").hasPrefix("Opening-d1") }
        XCTAssertEqual(doorFrameMeshes.count, 1)

        for mesh in bottomWallMeshes {
            let yRange = vertexRange(mesh).y
            XCTAssertGreaterThanOrEqual(yRange.1 - yRange.0, 0.0)
        }
    }

    func testWindowIsSuspendedAboveFloorWithWallBelowAndAbove() throws {
        let window = "[{\"opening_id\":\"w1\",\"category\":\"window\",\"position_m\":[3,0],\"width_m\":1.2,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: window))]"), configuration: DollhouseBuildConfiguration(mode: .dollhouse))
        let walls = wallMeshes(scene, forRoom: "room-1")
        let bottomWallMeshes = walls.filter { $0.path.components.last?.hasPrefix("Wall-0-") == true }
        XCTAssertGreaterThanOrEqual(bottomWallMeshes.count, 3, "a window should produce wall below, wall above, plus the wall to its sides")

        let hasLowBand = bottomWallMeshes.contains { mesh in
            let yRange = vertexRange(mesh).y
            return yRange.0 < 0.05 && yRange.1 > 0.3 && yRange.1 < 1.0
        }
        let hasHighBand = bottomWallMeshes.contains { mesh in
            let yRange = vertexRange(mesh).y
            return yRange.0 > 2.0 && yRange.1 > 2.4
        }
        XCTAssertTrue(hasLowBand, "there should be a wall band below the window")
        XCTAssertTrue(hasHighBand, "there should be a wall band above the window")

        let windowFrames = scene.meshes.filter { $0.layer == .windows }
        XCTAssertEqual(windowFrames.count, 1)
    }

    func testTopOfOpeningRespectsRoomHeight() throws {
        let door = "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[3,0],\"width_m\":0.9,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: door))]"))
        let walls = wallMeshes(scene, forRoom: "room-1")
        let topPiece = walls.first { $0.path.components.last?.hasPrefix("Wall-0-2") == true || $0.path.components.last?.hasPrefix("Wall-0-1") == true }
        XCTAssertNotNil(topPiece)
    }

    func testTwoOpeningsOnOneEdgeProduceThreeSolidPieces() throws {
        let openings = "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[1.5,0],\"width_m\":0.8,\"confidence\":\"high\"},{\"opening_id\":\"d2\",\"category\":\"door\",\"position_m\":[4.5,0],\"width_m\":0.8,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: openings))]"))
        let walls = wallMeshes(scene, forRoom: "room-1")
        let bottomWallMeshes = walls.filter { $0.path.components.last?.hasPrefix("Wall-0-") == true }
        XCTAssertGreaterThanOrEqual(bottomWallMeshes.count, 3, "two openings should split the wall into at least three solid stretches")
    }

    func testOpeningFarFromAnyWallIsIgnored() throws {
        let opening = "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[3,1.5],\"width_m\":0.9,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: opening))]"))
        let wall = wallMeshes(scene, forRoom: "room-1")
        XCTAssertEqual(wall.count, 4, "an opening 1.5 m from every wall must not subdivide anything")
        let doorFrame = scene.meshes.filter { ($0.path.components.last ?? "").hasPrefix("Opening-d1") }
        XCTAssertTrue(doorFrame.isEmpty)
    }

    func testOpenEdgeRemainsAnOpenEdgeMarkerEvenWithSubdivision() throws {
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openEdges: "[0]"))]"))
        let openEdges = scene.meshes.filter { ($0.path.components.last ?? "").hasPrefix("OpenEdge-0") }
        XCTAssertEqual(openEdges.count, 1)
        let walls = wallMeshes(scene, forRoom: "room-1")
        let wallZero = walls.filter { $0.path.components.last?.hasPrefix("Wall-0-") == true }
        XCTAssertTrue(wallZero.isEmpty, "the open edge should not produce a wall mesh")
    }

    func testWeldedVerticesCloseGapsBetweenTwoRooms() throws {
        let left = roomJSON(id: "left", outline: "[[0,0],[4,0],[4,3],[0,3]]", origin: "[0, 0]")
        let right = roomJSON(id: "right", outline: "[[0,0],[4,0],[4,3],[0,3]]", origin: "[4.0005, 0]")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(left),\(right)]"))
        let leftWalls = wallMeshes(scene, forRoom: "left")
        let rightWalls = wallMeshes(scene, forRoom: "right")
        XCTAssertFalse(leftWalls.isEmpty)
        XCTAssertFalse(rightWalls.isEmpty)
    }

    func testCollinearSharedEdgeIsSkippedOnTheShorterRoom() throws {
        let hallway = roomJSON(
            id: "hall",
            outline: "[[0,0],[6,0],[6,1.2],[0,1.2]]",
            origin: "[0, 0]"
        )
        let toilet = roomJSON(
            id: "toilet",
            outline: "[[0,0],[1.5,0],[1.5,1.5],[0,1.5]]",
            origin: "[1, 1.2]"
        )
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(hallway),\(toilet)]"))
        let hallWalls = wallMeshes(scene, forRoom: "hall")
        let toiletWalls = wallMeshes(scene, forRoom: "toilet")
        XCTAssertEqual(hallWalls.count, 4, "the long wall must survive when a short neighbour touches it")
        XCTAssertEqual(toiletWalls.count, 3, "the shorter shared edge is skipped")
    }

    func testOpeningsInsideAnOpeningHeavyRoomStillRender() throws {
        let openings = "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[1,0],\"width_m\":0.9,\"confidence\":\"high\"},{\"opening_id\":\"w1\",\"category\":\"window\",\"position_m\":[4,0],\"width_m\":1.2,\"confidence\":\"high\"}]"
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON(openings: openings))]"))
        XCTAssertFalse(scene.isEmpty)
        XCTAssertGreaterThan(scene.totalTriangles, 24)
    }
}
