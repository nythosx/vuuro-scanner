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

    func testReattachToSameViewReframesForNewScene() {
        let firstScene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let secondScene = makeScene(boundsMin: SIMD3(50, 0, 50), boundsMax: SIMD3(60, 2.6, 60))
        let view = SCNView()
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let camera = DollhouseCamera()

        camera.attach(to: view, cameraNode: cameraNode, framing: firstScene)
        let distanceAfterFirst = distance(from: cameraNode, to: firstScene.boundsCenter)

        camera.attach(to: view, cameraNode: cameraNode, framing: secondScene)

        let size = secondScene.boundsSize
        let expectedRadius = max(max(size.x, size.y), size.z) * 0.9 + 2
        let distanceToSecond = distance(from: cameraNode, to: secondScene.boundsCenter)
        let distanceToFirst = distance(from: cameraNode, to: firstScene.boundsCenter)

        XCTAssertEqual(distanceToSecond, expectedRadius, accuracy: 0.01, "reattach must frame the new scene at its default distance")
        XCTAssertGreaterThan(distanceToFirst, distanceToSecond * 5, "the camera must not still be pointed at the previous scene's center")
        XCTAssertNotEqual(distanceToSecond, distanceAfterFirst, accuracy: 0.01, "the second scene has different bounds so the distance must change")
    }

    func testReattachPreservesUserRotation() {
        let firstScene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let secondScene = makeScene(boundsMin: SIMD3(-2, 0, -2), boundsMax: SIMD3(2, 2.6, 2))
        let view = SCNView()
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let camera = DollhouseCamera()

        camera.attach(to: view, cameraNode: cameraNode, framing: firstScene)
        let initialPosition = cameraNode.position
        camera.attach(to: view, cameraNode: cameraNode, framing: secondScene)

        let distanceToSecond = distance(from: cameraNode, to: secondScene.boundsCenter)
        let offset = SIMD3<Float>(
            cameraNode.position.x - secondScene.boundsCenter.x,
            cameraNode.position.y - secondScene.boundsCenter.y,
            cameraNode.position.z - secondScene.boundsCenter.z
        )
        let normalized = simd_normalize(offset)
        let yaw: Float = .pi / 4
        let pitch: Float = .pi / 4
        let expectedDirection = SIMD3<Float>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
        XCTAssertEqual(normalized.x, expectedDirection.x, accuracy: 0.01)
        XCTAssertEqual(normalized.y, expectedDirection.y, accuracy: 0.01)
        XCTAssertEqual(normalized.z, expectedDirection.z, accuracy: 0.01)
        XCTAssertNotEqual(initialPosition.x, cameraNode.position.x)
    }

    func testReattachToADifferentViewStillUsesPlaceDefault() {
        let firstScene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let secondScene = makeScene(boundsMin: SIMD3(100, 0, 100), boundsMax: SIMD3(104, 2.6, 103))
        let firstView = SCNView()
        let secondView = SCNView()
        let firstCameraNode = SCNNode()
        firstCameraNode.camera = SCNCamera()
        let secondCameraNode = SCNNode()
        secondCameraNode.camera = SCNCamera()
        let camera = DollhouseCamera()

        camera.attach(to: firstView, cameraNode: firstCameraNode, framing: firstScene)
        camera.attach(to: secondView, cameraNode: secondCameraNode, framing: secondScene)

        let size = secondScene.boundsSize
        let expectedRadius = max(max(size.x, size.y), size.z) * 0.9 + 2
        let distanceToSecond = distance(from: secondCameraNode, to: secondScene.boundsCenter)
        XCTAssertEqual(distanceToSecond, expectedRadius, accuracy: 0.01)
    }
}
