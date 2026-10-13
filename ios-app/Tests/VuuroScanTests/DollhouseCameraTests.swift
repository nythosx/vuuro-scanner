import XCTest
import SceneKit
import simd
@testable import VuuroScan

final class DollhouseCameraTests: XCTestCase {

    private func makeScene(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, roomCount: Int = 1) -> DollhouseScene {
        DollhouseScene(
            meshes: [],
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            roomCount: roomCount,
            floorSections: [],
            usedEstimatedHeight: false
        )
    }

    private func distance(from node: SCNNode, to center: SIMD3<Float>) -> Float {
        let dx = node.position.x - center.x
        let dy = node.position.y - center.y
        let dz = node.position.z - center.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    func testPlaceDefaultFramesSceneAtKnownDistanceAndAngle() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene)

        let size = scene.boundsSize
        let expectedRadius = max(max(size.x, size.y), size.z) * 0.9 + 2
        let yaw: Float = .pi / 4
        let pitch: Float = .pi / 4
        let offset = SIMD3<Float>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * expectedRadius
        let center = scene.boundsCenter

        XCTAssertEqual(cameraNode.position.x, center.x + offset.x, accuracy: 0.01)
        XCTAssertEqual(cameraNode.position.y, center.y + offset.y, accuracy: 0.01)
        XCTAssertEqual(cameraNode.position.z, center.z + offset.z, accuracy: 0.01)
    }

    func testPlaceDefaultFramesLargerScenesFromFurtherAway() {
        let smallScene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(2, 2, 2))
        let largeScene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(20, 2, 20))
        let smallNode = SCNNode()
        smallNode.camera = SCNCamera()
        let largeNode = SCNNode()
        largeNode.camera = SCNCamera()
        DollhouseCamera.placeDefault(cameraNode: smallNode, framing: smallScene)
        DollhouseCamera.placeDefault(cameraNode: largeNode, framing: largeScene)

        let smallDistance = distance(from: smallNode, to: smallScene.boundsCenter)
        let largeDistance = distance(from: largeNode, to: largeScene.boundsCenter)
        XCTAssertGreaterThan(largeDistance, smallDistance, "a larger scene must be framed from further away")
    }

    func testPlaceDefaultIsIdempotentForTheSameScene() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene)
        let firstX = cameraNode.position.x
        let firstY = cameraNode.position.y
        let firstZ = cameraNode.position.z
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene)
        XCTAssertEqual(cameraNode.position.x, firstX, accuracy: 0.001)
        XCTAssertEqual(cameraNode.position.y, firstY, accuracy: 0.001)
        XCTAssertEqual(cameraNode.position.z, firstZ, accuracy: 0.001)
    }

    func testPlaceDefaultWithCameraInstancePreservesAngleAndDistance() {
        let scene = makeScene(boundsMin: SIMD3(-5, 0, -5), boundsMax: SIMD3(5, 2.6, 5))
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let camera = DollhouseCamera()
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene, camera: camera)

        let size = scene.boundsSize
        let expectedRadius = max(max(size.x, size.y), size.z) * 0.9 + 2
        let distanceFromCenter = distance(from: cameraNode, to: scene.boundsCenter)
        XCTAssertEqual(distanceFromCenter, expectedRadius, accuracy: 0.01, "a camera instance must land at the default framing distance")
    }
}
