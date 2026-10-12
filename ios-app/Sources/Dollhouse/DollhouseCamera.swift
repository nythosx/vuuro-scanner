import Foundation
import SceneKit
import UIKit

final class DollhouseCamera: NSObject {

    private weak var view: SCNView?
    private weak var cameraNode: SCNNode?
    private weak var attachedView: SCNView?
    private var distance: Float = 10
    private var defaultTarget: SIMD3<Float> = .zero
    private var yaw: Float = .pi / 4
    private var pitch: Float = .pi / 4
    private var target: SIMD3<Float> = .zero
    private var lastPanLocation: CGPoint = .zero

    func attach(to view: SCNView, cameraNode: SCNNode, framing scene: DollhouseScene) {
        self.view = view
        self.cameraNode = cameraNode
        defaultTarget = scene.boundsCenter
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene, camera: self)
        guard attachedView !== view else { return }
        attachedView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: twoFingerPan)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(twoFingerPan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
    }

    static func placeDefault(cameraNode: SCNNode, framing scene: DollhouseScene, camera: DollhouseCamera? = nil) {
        let size = scene.boundsSize
        let radius = max(max(size.x, size.y), size.z) * 0.9 + 2
        let center = scene.boundsCenter
        let yaw: Float = .pi / 4
        let pitch: Float = .pi / 4
        camera?.apply(yaw: yaw, pitch: pitch, distance: radius, target: center, cameraNode: cameraNode)
        if camera == nil {
            let offset = SIMD3<Float>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * radius
            cameraNode.position = SCNVector3(center.x + offset.x, center.y + offset.y, center.z + offset.z)
            cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        }
    }

    private func apply(yaw: Float, pitch: Float, distance: Float, target: SIMD3<Float>, cameraNode: SCNNode) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.target = target
        let offset = SIMD3<Float>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * distance
        cameraNode.position = SCNVector3(target.x + offset.x, target.y + offset.y, target.z + offset.z)
        cameraNode.look(at: SCNVector3(target.x, target.y, target.z))
    }

    private func update() {
        guard let cameraNode else { return }
        let offset = SIMD3<Float>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * distance
        cameraNode.position = SCNVector3(target.x + offset.x, target.y + offset.y, target.z + offset.z)
        cameraNode.look(at: SCNVector3(target.x, target.y, target.z))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        let sensitivity: Float = 0.008
        yaw -= Float(translation.x) * sensitivity
        pitch += Float(translation.y) * sensitivity
        pitch = max(0.15, min(Float.pi / 2 - 0.05, pitch))
        update()
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        let scale = distance * 0.002
        target.x -= Float(translation.x) * scale
        target.z -= Float(translation.y) * scale
        update()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let scale = Float(gesture.scale)
        gesture.scale = 1
        distance /= scale
        distance = max(1.5, min(200, distance))
        update()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        yaw = .pi / 4
        pitch = .pi / 4
        target = defaultTarget
        update()
    }
}
