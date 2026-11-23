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
    private var defaultYaw: Float = .pi / 4
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

    private var hasFramed = false
    private var userAdjusted = false
    private var viewportAspect: Float = 1
    private var verticalFovDeg: Float = 40
    private var framedBoundsSize: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    var onYawChange: ((Float) -> Void)?
    var followsNodePose = false

    deinit {
        inertiaLink?.invalidate()
    }

    static let minimumPitch: Float = 5 * .pi / 180
    static let maximumPitch: Float = 85 * .pi / 180
    static let minimumDistanceM: Float = 0.5
    static let maximumDistanceM: Float = 200

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
        defaultYaw = scene.defaultYaw
        let size = scene.boundsSize
        framedBoundsSize = size
        verticalFovDeg = Float(cameraNode.camera?.fieldOfView ?? 40)
        if view.bounds.width > 0, view.bounds.height > 0 {
            viewportAspect = Float(view.bounds.width / view.bounds.height)
        }
        defaultDistance = Self.fitDistance(boundsSize: size, verticalFovDeg: verticalFovDeg, aspect: viewportAspect)
        targetRangeM = max(max(size.x, size.z) * 0.75, 2)
        let sceneBoundsChanged = simd_distance(previousTarget, scene.boundsCenter) > 0.01
        let isNewView = attachedView !== view
        attachedView = view

        if hasFramed {
            if sceneBoundsChanged {
                self.target = scene.boundsCenter
                self.distance = defaultDistance
                userAdjusted = false
            }
            if isNewView {
                installGestureRecognizers(on: view)
            }
            self.update()
            return
        }

        hasFramed = true
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: scene, camera: self, aspect: viewportAspect)
        installGestureRecognizers(on: view)
    }

    func viewportChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewportAspect = Float(size.width / size.height)
        defaultDistance = Self.fitDistance(boundsSize: framedBoundsSize, verticalFovDeg: verticalFovDeg, aspect: viewportAspect)
        guard hasFramed, !userAdjusted else { return }
        distance = defaultDistance
        update()
    }

    static func fitDistance(boundsSize: SIMD3<Float>, verticalFovDeg: Float, aspect: Float) -> Float {
        let radius = max(simd_length(boundsSize) / 2, 0.5)
        let halfVertical = max(verticalFovDeg, 10) * .pi / 360
        let halfHorizontal = atan(tan(halfVertical) * max(aspect, 0.2))
        let half = min(halfVertical, halfHorizontal)
        return min(radius / sin(half) * 1.05, 200)
    }

    static func compassScreenDegrees(yaw: Float, headingDeg: Double) -> Double {
        let heading = headingDeg * .pi / 180
        let north = SIMD2<Double>(sin(heading), cos(heading))
        let forward = SIMD2<Double>(-cos(Double(yaw)), -sin(Double(yaw)))
        let right = SIMD2<Double>(sin(Double(yaw)), -cos(Double(yaw)))
        return atan2(simd_dot(north, right), simd_dot(north, forward)) * 180 / .pi
    }

    private func installGestureRecognizers(on view: SCNView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
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
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.require(toFail: pan)
        doubleTap.name = "dollhouseCamera"
        view.addGestureRecognizer(doubleTap)
    }

    static func placeDefault(cameraNode: SCNNode, framing scene: DollhouseScene, camera: DollhouseCamera? = nil, aspect: Float = 1) {
        let size = scene.boundsSize
        let radius = fitDistance(boundsSize: size, verticalFovDeg: Float(cameraNode.camera?.fieldOfView ?? 40), aspect: aspect)
        let center = scene.boundsCenter
        let yaw = scene.defaultYaw
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
        onYawChange?(yaw)
    }

    private func update() {
        guard let cameraNode else { return }
        let offset = SIMD3<Float>(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * distance
        cameraNode.position = SCNVector3(target.x + offset.x, target.y + offset.y, target.z + offset.z)
        cameraNode.look(at: SCNVector3(target.x, target.y, target.z))
        onYawChange?(yaw)
    }

    private func followNodePose() {
        guard followsNodePose, let cameraNode else { return }
        let position = SIMD3<Float>(cameraNode.position.x, cameraNode.position.y, cameraNode.position.z)
        let offset = position - target
        let length = simd_length(offset)
        guard length.isFinite, length > 0.01 else { return }
        yaw = atan2(offset.z, offset.x)
        pitch = Self.clampedPitch(asin(max(-1, min(1, offset.y / length))))
        distance = length
    }

    func setGesturesEnabled(_ enabled: Bool, on view: SCNView) {
        for recognizer in view.gestureRecognizers ?? [] where recognizer.name == "dollhouseCamera" {
            recognizer.isEnabled = enabled
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .began {
            stopInertia()
            userAdjusted = true
            followNodePose()
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

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .began {
            stopInertia()
            userAdjusted = true
            followNodePose()
        }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        target = clampedTarget(target + screenPanOffset(dx: Float(translation.x), dy: Float(translation.y)))
        update()
        if gesture.state == .ended {
            let velocity = gesture.velocity(in: view)
            guard Self.isFlick(velocity) else {
                stopInertia()
                return
            }
            panVelocity = screenPanOffset(dx: Float(velocity.x), dy: Float(velocity.y))
            startInertia()
        }
    }

    func screenPanOffset(dx: Float, dy: Float) -> SIMD3<Float> {
        let scale = distance * 0.0015
        let right = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
        return (SIMD3<Float>(0, dy, 0) - right * dx) * scale
    }

    private func clampedTarget(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let halfHeight = max(framedBoundsSize.y, 1)
        let y = max(defaultTarget.y - halfHeight, min(defaultTarget.y + halfHeight, value.y))
        let offset = SIMD2<Float>(value.x - defaultTarget.x, value.z - defaultTarget.z)
        let length = simd_length(offset)
        guard length > targetRangeM, length > 0 else { return SIMD3<Float>(value.x, y, value.z) }
        let limited = offset * (targetRangeM / length)
        return SIMD3<Float>(defaultTarget.x + limited.x, y, defaultTarget.z + limited.y)
    }

    private func surfacePoint(at location: CGPoint, in view: SCNView) -> SIMD3<Float>? {
        let options: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true
        ]
        if let hit = view.hitTest(location, options: options).first {
            let point = hit.worldCoordinates
            let focus = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
            if focus.x.isFinite, focus.y.isFinite, focus.z.isFinite {
                return focus
            }
        }
        return nil
    }

    static func clampedDistance(_ value: Float) -> Float {
        max(minimumDistanceM, min(maximumDistanceM, value))
    }

    static func clampedPitch(_ value: Float) -> Float {
        max(minimumPitch, min(maximumPitch, value))
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
        let link = CADisplayLink(target: DollhouseInertiaTarget(owner: self), selector: #selector(DollhouseInertiaTarget.tick(_:)))
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

    fileprivate func stepInertia(_ link: CADisplayLink) {
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
            followNodePose()
        }
        userAdjusted = true
        let scale = Float(gesture.scale)
        gesture.scale = 1
        guard scale > 0 else { return }
        distance /= pow(scale, Self.storedSpeed(Self.zoomSpeedKey, fallback: Self.defaultZoomSpeed))
        distance = Self.clampedDistance(distance)
        update()
    }

    func fitAll() {
        stopInertia()
        userAdjusted = false
        yaw = defaultYaw
        pitch = .pi / 4
        target = defaultTarget
        distance = defaultDistance
        animateUpdate()
    }

    func zoom(by factor: Float) {
        stopInertia()
        userAdjusted = true
        distance = Self.clampedDistance(distance * factor)
        animateUpdate()
    }

    func focus(on room: DollhouseRoomLabel) {
        stopInertia()
        userAdjusted = true
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
        if let view = gesture.view as? SCNView,
           let focus = surfacePoint(at: gesture.location(in: view), in: view) {
            followNodePose()
            userAdjusted = true
            target = clampedTarget(focus)
            distance = Self.clampedDistance(distance * 0.6)
            animateUpdate()
            return
        }
        userAdjusted = false
        yaw = defaultYaw
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
        gestureRecognizer.name == "dollhouseCamera" && otherGestureRecognizer.name == "dollhouseCamera"
    }
}

private final class DollhouseInertiaTarget: NSObject {
    weak var owner: DollhouseCamera?

    init(owner: DollhouseCamera) {
        self.owner = owner
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.stepInertia(link)
    }
}
