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
        let expectedRadius = DollhouseCamera.fitDistance(boundsSize: size, verticalFovDeg: 60, aspect: 1)
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
        let expectedRadius = DollhouseCamera.fitDistance(boundsSize: size, verticalFovDeg: 60, aspect: 1)
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
        let expectedRadius = DollhouseCamera.fitDistance(boundsSize: size, verticalFovDeg: 60, aspect: 1)
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
        let expectedRadius = DollhouseCamera.fitDistance(boundsSize: size, verticalFovDeg: 60, aspect: 1)
        let distanceToSecond = distance(from: secondCameraNode, to: secondScene.boundsCenter)
        XCTAssertEqual(distanceToSecond, expectedRadius, accuracy: 0.01)
    }

    func testRemountPreservesUserCameraPose() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let camera = DollhouseCamera()

        let firstView = SCNView()
        let firstNode = SCNNode()
        firstNode.camera = SCNCamera()
        camera.attach(to: firstView, cameraNode: firstNode, framing: scene)
        let initialPosition = firstNode.position

        let secondView = SCNView()
        let secondNode = SCNNode()
        secondNode.camera = SCNCamera()
        camera.attach(to: secondView, cameraNode: secondNode, framing: scene)
        let remountPosition = secondNode.position

        XCTAssertEqual(remountPosition.x, initialPosition.x, accuracy: 0.01)
        XCTAssertEqual(remountPosition.y, initialPosition.y, accuracy: 0.01)
        XCTAssertEqual(remountPosition.z, initialPosition.z, accuracy: 0.01)
    }

    private func ourRecognizerCount(_ view: SCNView) -> Int {
        (view.gestureRecognizers ?? []).filter { $0.name == "dollhouseCamera" }.count
    }

    func testRemountReinstallsGestureRecognizersOnTheNewView() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let camera = DollhouseCamera()

        let firstView = SCNView()
        let firstNode = SCNNode()
        firstNode.camera = SCNCamera()
        camera.attach(to: firstView, cameraNode: firstNode, framing: scene)
        XCTAssertEqual(ourRecognizerCount(firstView), 5, "first attach must install pan/pinch/two-finger-pan/twist/double-tap")

        let secondView = SCNView()
        let secondNode = SCNNode()
        secondNode.camera = SCNCamera()
        camera.attach(to: secondView, cameraNode: secondNode, framing: scene)
        XCTAssertEqual(ourRecognizerCount(secondView), 5, "a rebuild swaps in a new SCNView (theme/mode/layer/floor toggle) — gestures must still work on it, not only the pose")
    }

    func testReattachingTheSameViewDoesNotDuplicateGestureRecognizers() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let camera = DollhouseCamera()

        let view = SCNView()
        let node = SCNNode()
        node.camera = SCNCamera()
        camera.attach(to: view, cameraNode: node, framing: scene)
        camera.attach(to: view, cameraNode: node, framing: scene)

        XCTAssertEqual(ourRecognizerCount(view), 5, "re-attaching the same view (e.g. a scene-data-only update) must not stack duplicate recognizers")
    }

    func testPinchZoomKeepsThePointUnderTheFingersInPlace() {
        let target = SIMD3<Float>(0, 0, 0)
        let focus = SIMD3<Float>(4, 0, 2)
        let zoomed = DollhouseCamera.zoomedTarget(target: target, focus: focus, oldDistance: 10, newDistance: 5)
        XCTAssertEqual(zoomed.x, 2, accuracy: 1e-5)
        XCTAssertEqual(zoomed.z, 1, accuracy: 1e-5)
        let unchanged = DollhouseCamera.zoomedTarget(target: target, focus: focus, oldDistance: 10, newDistance: 10)
        XCTAssertEqual(unchanged, target)
    }

    func testSlowReleaseDoesNotGlide() {
        XCTAssertFalse(DollhouseCamera.isFlick(CGPoint(x: 60, y: 40)))
        XCTAssertTrue(DollhouseCamera.isFlick(CGPoint(x: 600, y: 0)))
    }

    func testSmallRotationDuringATwoFingerDragDoesNotSpin() {
        XCTAssertFalse(DollhouseCamera.isDeliberateTwist(0.05))
        XCTAssertFalse(DollhouseCamera.isDeliberateTwist(-0.1))
        XCTAssertTrue(DollhouseCamera.isDeliberateTwist(0.3))
        XCTAssertTrue(DollhouseCamera.isDeliberateTwist(-0.3))
    }

    func testFastFlickSpinIsCapped() {
        XCTAssertEqual(DollhouseCamera.clampedSpin(40), DollhouseCamera.maximumSpinRadiansPerSecond)
        XCTAssertEqual(DollhouseCamera.clampedSpin(-40), -DollhouseCamera.maximumSpinRadiansPerSecond)
        XCTAssertEqual(DollhouseCamera.clampedSpin(1), 1)
    }

    func testDoubleTapResetsZoomDistance() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let camera = DollhouseCamera()
        let view = SCNView()
        let node = SCNNode()
        node.camera = SCNCamera()
        camera.attach(to: view, cameraNode: node, framing: scene)

        let defaultDistanceFromTarget = distance(from: node, to: scene.boundsCenter)

        let pinch = UIPinchGestureRecognizer()
        pinch.scale = 3.0
        camera.handlePinch(pinch)
        let zoomedDistance = distance(from: node, to: scene.boundsCenter)
        XCTAssertLessThan(zoomedDistance, defaultDistanceFromTarget, "pinching with scale > 1 must zoom in")

        let doubleTap = UITapGestureRecognizer()
        camera.handleDoubleTap(doubleTap)
        let resetDistance = distance(from: node, to: scene.boundsCenter)
        XCTAssertEqual(resetDistance, defaultDistanceFromTarget, accuracy: 0.01, "double-tap must also reset zoom, not just yaw/pitch/target")
    }

    func testTwoFingerDragFollowsTheCameraDirection() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let camera = DollhouseCamera()
        let view = SCNView()
        let node = SCNNode()
        node.camera = SCNCamera()
        camera.attach(to: view, cameraNode: node, framing: scene)
        let toCamera = simd_normalize(SIMD3<Float>(node.position.x - scene.boundsCenter.x, 0, node.position.z - scene.boundsCenter.z))
        let dragDown = simd_normalize(camera.groundPanOffset(dx: 0, dy: 100))
        XCTAssertEqual(simd_dot(dragDown, toCamera), -1, accuracy: 0.001, "dragging down moves the view away from the camera, whatever the rotation")
        let dragRight = camera.groundPanOffset(dx: 100, dy: 0)
        XCTAssertEqual(simd_dot(dragRight, toCamera), 0, accuracy: 0.001)
        XCTAssertEqual(dragRight.y, 0)
    }

    func testTiltStaysBetweenTwentyAndEightyDegrees() {
        XCTAssertEqual(DollhouseCamera.clampedPitch(-1), DollhouseCamera.minimumPitch)
        XCTAssertEqual(DollhouseCamera.clampedPitch(3), DollhouseCamera.maximumPitch)
        XCTAssertEqual(DollhouseCamera.clampedPitch(0.8), 0.8)
        XCTAssertEqual(DollhouseCamera.minimumPitch, 20 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(DollhouseCamera.maximumPitch, 80 * .pi / 180, accuracy: 1e-5)
    }

    func testPortraitScreensFrameTheWholeModelFromFurtherAway() {
        let size = SIMD3<Float>(10.8, 3.6, 5.8)
        let portrait = DollhouseCamera.fitDistance(boundsSize: size, verticalFovDeg: 40, aspect: 0.46)
        let landscape = DollhouseCamera.fitDistance(boundsSize: size, verticalFovDeg: 40, aspect: 2.1)
        XCTAssertGreaterThan(portrait, landscape)
        let halfWidthVisible = portrait * tan(atan(tan(20 * Float.pi / 180) * 0.46))
        XCTAssertGreaterThanOrEqual(halfWidthVisible, simd_length(size) / 2, "the bounding sphere must fit the narrow side of a portrait screen")
    }

    func testViewportChangeReframesUntilTheUserMovesTheCamera() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(10, 3, 6))
        let camera = DollhouseCamera()
        let view = SCNView()
        let node = SCNNode()
        node.camera = SCNCamera()
        node.camera?.fieldOfView = 40
        camera.attach(to: view, cameraNode: node, framing: scene)
        let square = distance(from: node, to: scene.boundsCenter)
        camera.viewportChanged(CGSize(width: 390, height: 844))
        let portrait = distance(from: node, to: scene.boundsCenter)
        XCTAssertGreaterThan(portrait, square, "a tall phone screen must pull the camera back so the model is not cut off")
        let pinch = UIPinchGestureRecognizer()
        pinch.scale = 2
        camera.handlePinch(pinch)
        let zoomed = distance(from: node, to: scene.boundsCenter)
        camera.viewportChanged(CGSize(width: 844, height: 390))
        XCTAssertEqual(distance(from: node, to: scene.boundsCenter), zoomed, accuracy: 0.01, "a layout change must not undo the user's zoom")
    }

    func testCompassPointsUpWhenTheCameraLooksNorth() {
        XCTAssertEqual(DollhouseCamera.compassScreenDegrees(yaw: -.pi / 2, headingDeg: 0), 0, accuracy: 0.01)
        XCTAssertEqual(DollhouseCamera.compassScreenDegrees(yaw: .pi, headingDeg: 0), 90, accuracy: 0.01)
        XCTAssertEqual(abs(DollhouseCamera.compassScreenDegrees(yaw: .pi / 2, headingDeg: 0)), 180, accuracy: 0.01)
    }

    func testContinuousGestureRecognizersAllowSimultaneousRecognition() {
        let scene = makeScene(boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(4, 2.6, 3))
        let camera = DollhouseCamera()
        let view = SCNView()
        let node = SCNNode()
        node.camera = SCNCamera()
        camera.attach(to: view, cameraNode: node, framing: scene)

        let continuous = (view.gestureRecognizers ?? []).filter { $0.name == "dollhouseCamera" && !($0 is UITapGestureRecognizer) }
        XCTAssertEqual(continuous.count, 4, "expected pan, pinch, two-finger pan and twist")
        let foreign = UIPanGestureRecognizer()
        for recognizer in continuous {
            XCTAssertFalse(camera.gestureRecognizer(recognizer, shouldRecognizeSimultaneouslyWith: foreign), "a drag on the 3D view must not also scroll the page")
        }
        for recognizer in continuous {
            XCTAssertNotNil(recognizer.delegate, "pan/pinch/two-finger-pan/twist must have a delegate so they can recognize simultaneously — otherwise a one-finger drag that grows into a pinch drops one of them")
        }
    }
}
