import Foundation
import SceneKit
import UIKit

final class DollhouseCamera: NSObject {

    private weak var view: SCNView?
    private weak var cameraNode: SCNNode?
    private weak var attachedView: SCNView?
    private var distance: Float = 10
    private var defaultDistance: Float = 10
    private var defaultTarget: SIMD3<Float> = .zero
    private var targetRangeM: Float = 10
    private var yaw: Float = .pi / 4
    private var pitch: Float = .pi / 4
    private var target: SIMD3<Float> = .zero
    private var lastPanLocation: CGPoint = .zero
    private var yawVelocity: Float = 0
    private var pitchVelocity: Float = 0
    private var panVelocity: SIMD3<Float> = .zero
    private var inertiaLink: CADisplayLink?
    private var lastInertiaTimestamp: CFTimeInterval = 0

    static let inertiaDecayPerSecond: Float = 0.08
    static let inertiaStopSpeed: Float = 0.01
    static let rotationSensitivity: Float = 0.008
    static let minimumFlickPointsPerSecond: CGFloat = 180
    static let maximumSpinRadiansPerSecond: Float = 5
    static let twistStartRadians: Float = 0.17
    private var twistAccumulated: Float = 0
    private var twistEngaged = false

    private var hasFramed = false

    static let zoomSpeedKey = "dollhouseZoomSpeed"
    static let rotationSpeedKey = "dollhouseRotationSpeed"
    static let defaultZoomSpeed = 1.0
    static let defaultRotationSpeed = 1.0

    private static func storedSpeed(_ key: String, fallback: Double) -> Float {
        guard let value = UserDefaults.standard.object(forKey: key) as? Double, value.isFinite, value > 0 else {
            return Float(fallback)
        }
        return Float(value)
    }

    func attach(to view: SCNView, cameraNode: SCNNode, framing scene: DollhouseScene) {
        self.view = view
        self.cameraNode = cameraNode

        let previousTarget = defaultTarget
        defaultTarget = scene.boundsCenter
        let size = scene.boundsSize
        defaultDistance = max(max(size.x, size.y), size.z) * 0.9 + 2
        targetRangeM = max(max(size.x, size.z) * 0.75, 2)
        let sceneBoundsChanged = simd_distance(previousTarget, scene.boundsCenter) > 0.01
        let isNewView = attachedView !== view
        attachedView = view

        if hasFramed {
            if sceneBoundsChanged {
                self.target = scene.boundsCenter
                self.distance = defaultDistance
            }
            if isNewView {
                installGestureRecognizers(on: view)
            }
            self.update()
            return
        }

        hasFramed = true
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene, camera: self)
        installGestureRecognizers(on: view)
    }

    private func installGestureRecognizers(on view: SCNView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:)))
        twist.delegate = self
        twist.name = "dollhouseCamera"
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pinch.delegate = self
        twoFingerPan.delegate = self
        pan.name = "dollhouseCamera"
        pinch.name = "dollhouseCamera"
        twoFingerPan.name = "dollhouseCamera"
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(twoFingerPan)
        view.addGestureRecognizer(twist)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.require(toFail: pan)
        doubleTap.name = "dollhouseCamera"
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
        if gesture.state == .began {
            stopInertia()
        }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        let sensitivity = Self.rotationSensitivity * Self.storedSpeed(Self.rotationSpeedKey, fallback: Self.defaultRotationSpeed)
        yaw -= Float(translation.x) * sensitivity
        pitch = Self.clampedPitch(pitch + Float(translation.y) * sensitivity)
        update()
        if gesture.state == .ended {
            let velocity = gesture.velocity(in: view)
            guard Self.isFlick(velocity) else {
                stopInertia()
                return
            }
            yawVelocity = Self.clampedSpin(-Float(velocity.x) * sensitivity)
            pitchVelocity = Self.clampedSpin(Float(velocity.y) * sensitivity)
            startInertia()
        }
    }

    static func isFlick(_ velocity: CGPoint) -> Bool {
        hypot(velocity.x, velocity.y) >= minimumFlickPointsPerSecond
    }

    static func clampedSpin(_ value: Float) -> Float {
        max(-maximumSpinRadiansPerSecond, min(maximumSpinRadiansPerSecond, value))
    }

    @objc func handleTwist(_ gesture: UIRotationGestureRecognizer) {
        if gesture.state == .began {
            stopInertia()
            twistAccumulated = 0
            twistEngaged = false
        }
        let rotation = Float(gesture.rotation)
        gesture.rotation = 0
        twistAccumulated += rotation
        if !twistEngaged {
            twistEngaged = Self.isDeliberateTwist(twistAccumulated)
            return
        }
        yaw -= rotation
        update()
    }

    static func isDeliberateTwist(_ radians: Float) -> Bool {
        abs(radians) >= twistStartRadians
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .began {
            stopInertia()
        }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        target = clampedTarget(target + groundPanOffset(dx: Float(translation.x), dy: Float(translation.y)))
        update()
        if gesture.state == .ended {
            let velocity = gesture.velocity(in: view)
            guard Self.isFlick(velocity) else {
                stopInertia()
                return
            }
            panVelocity = groundPanOffset(dx: Float(velocity.x), dy: Float(velocity.y))
            startInertia()
        }
    }

    func groundPanOffset(dx: Float, dy: Float) -> SIMD3<Float> {
        let scale = distance * 0.002
        let forward = SIMD3<Float>(-cos(yaw), 0, -sin(yaw))
        let right = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        return (forward * dy - right * dx) * scale
    }

    private func clampedTarget(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let offset = SIMD2<Float>(value.x - defaultTarget.x, value.z - defaultTarget.z)
        let length = simd_length(offset)
        guard length > targetRangeM, length > 0 else { return value }
        let limited = offset * (targetRangeM / length)
        return SIMD3<Float>(defaultTarget.x + limited.x, value.y, defaultTarget.z + limited.y)
    }

    static func zoomedTarget(target: SIMD3<Float>, focus: SIMD3<Float>, oldDistance: Float, newDistance: Float) -> SIMD3<Float> {
        guard oldDistance > 0 else { return target }
        return focus + (target - focus) * (newDistance / oldDistance)
    }

    private func groundPoint(at location: CGPoint, in view: SCNView) -> SIMD3<Float>? {
        let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
        let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
        let origin = SIMD3<Float>(near.x, near.y, near.z)
        let direction = SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z)
        guard abs(direction.y) > 1e-5 else { return nil }
        let t = (target.y - origin.y) / direction.y
        guard t > 0, t.isFinite else { return nil }
        return origin + direction * t
    }

    static func clampedPitch(_ value: Float) -> Float {
        max(0.05, min(Float.pi / 2 - 0.05, value))
    }

    private func startInertia() {
        inertiaLink?.invalidate()
        guard abs(yawVelocity) > Self.inertiaStopSpeed
            || abs(pitchVelocity) > Self.inertiaStopSpeed
            || simd_length(panVelocity) > Self.inertiaStopSpeed else {
            stopInertia()
            return
        }
        lastInertiaTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(stepInertia(_:)))
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    private func stopInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
        yawVelocity = 0
        pitchVelocity = 0
        panVelocity = .zero
    }

    @objc private func stepInertia(_ link: CADisplayLink) {
        guard cameraNode != nil else {
            stopInertia()
            return
        }
        let dt = lastInertiaTimestamp == 0 ? Float(1.0 / 60.0) : Float(min(link.timestamp - lastInertiaTimestamp, 0.05))
        lastInertiaTimestamp = link.timestamp
        yaw += yawVelocity * dt
        pitch = Self.clampedPitch(pitch + pitchVelocity * dt)
        target = clampedTarget(target + panVelocity * dt)
        let decay = pow(Self.inertiaDecayPerSecond, dt)
        yawVelocity *= decay
        pitchVelocity *= decay
        panVelocity *= decay
        update()
        if abs(yawVelocity) < Self.inertiaStopSpeed
            && abs(pitchVelocity) < Self.inertiaStopSpeed
            && simd_length(panVelocity) < Self.inertiaStopSpeed {
            stopInertia()
        }
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            stopInertia()
        }
        let scale = Float(gesture.scale)
        gesture.scale = 1
        guard scale > 0 else { return }
        let oldDistance = distance
        distance /= pow(scale, Self.storedSpeed(Self.zoomSpeedKey, fallback: Self.defaultZoomSpeed))
        distance = max(1.5, min(200, distance))
        if let view = gesture.view as? SCNView, gesture.numberOfTouches >= 2,
           let focus = groundPoint(at: gesture.location(in: view), in: view) {
            target = clampedTarget(Self.zoomedTarget(target: target, focus: focus, oldDistance: oldDistance, newDistance: distance))
        }
        update()
    }

    func fitAll() {
        stopInertia()
        pitch = .pi / 4
        target = defaultTarget
        distance = defaultDistance
        animateUpdate()
    }

    func zoom(by factor: Float) {
        stopInertia()
        distance = max(1.5, min(200, distance * factor))
        animateUpdate()
    }

    func focus(on room: DollhouseRoomLabel) {
        stopInertia()
        let size = max(sqrt(max(room.areaM2, 1)), 2)
        target = room.floorCenter + SIMD3<Float>(0, 0.4, 0)
        pitch = 35 * .pi / 180
        distance = max(size * 1.5, 3)
        animateUpdate()
    }

    private func animateUpdate() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        update()
        SCNTransaction.commit()
    }

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        stopInertia()
        yaw = .pi / 4
        pitch = .pi / 4
        target = defaultTarget
        distance = defaultDistance
        animateUpdate()
    }
}

extension DollhouseCamera: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
