import XCTest
import SceneKit
import simd
@testable import VuuroScan

final class DollhouseLayerTests: XCTestCase {

    private func makeRooms(_ json: String) throws -> [FloorPlan.Room] {
        try JSONDecoder().decode([FloorPlan.Room].self, from: Data(json.utf8))
    }

    private func roomJSON(
        id: String = "room-1",
        outline: String = "[[0,0],[4,0],[4,3],[0,3]]",
        openings: String = "[]",
        objects: String = "[]",
        floor: String = "Ground"
    ) -> String {
        """
        {
          "room_id": "\(id)", "label": "\(id)", "floor_area_m2": 12.0, "perimeter_m": 14.0,
          "bounding_dimensions_m": {"width_m": 4.0, "length_m": 3.0},
          "confidence": "high", "outline_m": \(outline),
          "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
          "openings": \(openings), "objects": \(objects), "structure_origin_m": null, "room_type": null,
          "floor": "\(floor)", "capture_group_id": null, "joined_to_group_id": null,
          "height_m": 2.6, "open_edges": []
        }
        """
    }

    func testEveryMeshIsTaggedWithALayer() throws {
        let roomWithFurniture = roomJSON(
            openings: "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[2,0],\"width_m\":0.9,\"confidence\":\"high\"}]",
            objects: "[{\"object_id\":\"o1\",\"category\":\"sofa\",\"position_m\":[2,1.5],\"dimensions_m\":[2,0.8,0.9],\"confidence\":\"high\",\"custom_name\":null,\"excluded\":false}]"
        )
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomWithFurniture)]"))
        XCTAssertFalse(scene.meshes.isEmpty)
        for mesh in scene.meshes {
            XCTAssertFalse(mesh.layer.rawValue.isEmpty)
        }
    }

    func testFurnitureMeshesCarryTheFurnitureLayer() throws {
        let json = roomJSON(objects: "[{\"object_id\":\"o1\",\"category\":\"sofa\",\"position_m\":[2,1.5],\"dimensions_m\":[2,0.8,0.9],\"confidence\":\"high\",\"custom_name\":null,\"excluded\":false}]")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(json)]"))
        let furniture = scene.meshes.filter { $0.layer == .furniture }
        XCTAssertEqual(furniture.count, 1)
        XCTAssertTrue(furniture[0].path.identifier.contains("Object-o1"))
    }

    func testDoorOpeningProducesADoorMesh() throws {
        let json = roomJSON(openings: "[{\"opening_id\":\"d1\",\"category\":\"door\",\"position_m\":[2,0],\"width_m\":0.9,\"confidence\":\"high\"}]")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(json)]"))
        let doors = scene.meshes.filter { $0.layer == .doors }
        XCTAssertEqual(doors.count, 1)
        XCTAssertTrue(doors[0].path.identifier.contains("Opening-d1"))
    }

    func testWindowOpeningProducesAWindowMesh() throws {
        let json = roomJSON(openings: "[{\"opening_id\":\"w1\",\"category\":\"window\",\"position_m\":[2,0],\"width_m\":1.2,\"confidence\":\"high\"}]")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(json)]"))
        let windows = scene.meshes.filter { $0.layer == .windows }
        XCTAssertEqual(windows.count, 1)
    }

    func testGenericOpeningProducesAnOpeningMesh() throws {
        let json = roomJSON(openings: "[{\"opening_id\":\"o1\",\"category\":\"opening\",\"position_m\":[2,0],\"width_m\":0.8,\"confidence\":\"high\"}]")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(json)]"))
        let openings = scene.meshes.filter { $0.layer == .openings }
        XCTAssertEqual(openings.count, 1)
    }

    func testWallsAndFloorsShareTheDefaultLayer() throws {
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON())]"))
        let wallsAndFloors = scene.meshes.filter { $0.layer == .wallsAndFloors }
        XCTAssertGreaterThanOrEqual(wallsAndFloors.count, 2)
    }

    func testLayerVisibilityDefaultsAndToggle() {
        var visibility = DollhouseLayerVisibility()
        XCTAssertTrue(visibility.isVisible(.wallsAndFloors))
        XCTAssertFalse(visibility.isVisible(.ceiling))
        visibility[.ceiling] = true
        visibility[.furniture] = false
        XCTAssertTrue(visibility.isVisible(.ceiling))
        XCTAssertFalse(visibility.isVisible(.furniture))
    }

    func testHiddenLayerExcludedFromScene() throws {
        let json = roomJSON(objects: "[{\"object_id\":\"o1\",\"category\":\"sofa\",\"position_m\":[2,1.5],\"dimensions_m\":[2,0.8,0.9],\"confidence\":\"high\",\"custom_name\":null,\"excluded\":false}]")
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(json)]"))
        var visibility = DollhouseLayerVisibility()
        visibility.furniture = false
        let scnScene = DollhouseSceneBuilder.buildScene(from: scene, visibility: visibility, theme: .light)
        let allNodes = scnScene.rootNode.childNodes(passingTest: { _, _ in true })
        let sofaNodes = allNodes.filter { $0.name?.contains("furniture-sofa") == true }
        XCTAssertTrue(sofaNodes.isEmpty)
    }

    func testHotspotMarkersAppearInSceneWhenVisible() throws {
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON())]"))
        var withHotspot = scene
        withHotspot.hotspots = [DollhouseHotspot(id: "photo-1", roomId: "room-1", position: SIMD3<Float>(1, 1.4, 1))]
        let scnScene = DollhouseSceneBuilder.buildScene(from: withHotspot, visibility: DollhouseLayerVisibility(), theme: .light)
        let allNodes = scnScene.rootNode.childNodes(passingTest: { _, _ in true })
        let hotspotNodes = allNodes.filter { $0.name?.hasPrefix("hotspot-") == true }
        XCTAssertEqual(hotspotNodes.count, 1)
    }

    func testHotspotMarkersExcludedWhenLayerHidden() throws {
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON())]"))
        var withHotspot = scene
        withHotspot.hotspots = [DollhouseHotspot(id: "photo-1", roomId: "room-1", position: SIMD3<Float>(1, 1.4, 1))]
        var visibility = DollhouseLayerVisibility()
        visibility.hotspotMarkers = false
        let scnScene = DollhouseSceneBuilder.buildScene(from: withHotspot, visibility: visibility, theme: .light)
        let allNodes = scnScene.rootNode.childNodes(passingTest: { _, _ in true })
        let hotspotNodes = allNodes.filter { $0.name?.hasPrefix("hotspot-") == true }
        XCTAssertTrue(hotspotNodes.isEmpty)
    }

    func testDarkThemeChangesWallColor() throws {
        let scene = try DollhouseMeshBuilder.build(rooms: try makeRooms("[\(roomJSON())]"))
        let lightScene = DollhouseSceneBuilder.buildScene(from: scene, visibility: DollhouseLayerVisibility(), theme: .light)
        let darkScene = DollhouseSceneBuilder.buildScene(from: scene, visibility: DollhouseLayerVisibility(), theme: .dark)
        let lightWall = findWallDiffuse(lightScene)
        let darkWall = findWallDiffuse(darkScene)
        XCTAssertNotNil(lightWall)
        XCTAssertNotNil(darkWall)
        XCTAssertNotEqual(lightWall, darkWall)
    }

    private func findWallDiffuse(_ scene: SCNScene) -> UIColor? {
        var found: UIColor?
        scene.rootNode.enumerateChildNodes { node, stop in
            guard let material = node.geometry?.firstMaterial,
                  let name = material.name,
                  name.hasPrefix("exteriorWall") else { return }
            found = material.diffuse.contents as? UIColor
            stop.pointee = true
        }
        return found
    }
}
