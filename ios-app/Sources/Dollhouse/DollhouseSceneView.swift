import SceneKit
import SwiftUI

struct DollhouseSceneView: UIViewRepresentable {
    let scene: DollhouseScene
    let scnScene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isAccessibilityElement = true
        view.accessibilityLabel = vuuroLocalized("3D floor plan")
        view.accessibilityValue = scene.roomCount == 1
            ? vuuroLocalized("1 room")
            : String(format: vuuroLocalized("%d rooms"), scene.roomCount)
        view.accessibilityHint = vuuroLocalized("Drag with one finger to rotate, pinch to zoom, and drag with two fingers to pan.")
        view.scene = scnScene
        if let cameraNode = scnScene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            view.pointOfView = cameraNode
            context.coordinator.camera.attach(to: view, cameraNode: cameraNode, framing: scene)
        }
        context.coordinator.lastSceneId = scene.id
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.lastSceneId != scene.id else { return }
        context.coordinator.lastSceneId = scene.id
        view.scene = scnScene
        if let cameraNode = scnScene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            view.pointOfView = cameraNode
            context.coordinator.camera.attach(to: view, cameraNode: cameraNode, framing: scene)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        let camera = DollhouseCamera()
        var lastSceneId: UUID?
    }
}
