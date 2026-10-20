import SceneKit
import SwiftUI

struct DollhouseSceneView: UIViewRepresentable {
    let scene: DollhouseScene
    let scnScene: SCNScene
    let theme: DollhouseTheme
    var camera: DollhouseCamera? = nil
    var onHotspotTap: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = theme.backgroundColor
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
        if onHotspotTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            view.addGestureRecognizer(tap)
        }
        context.coordinator.lastSceneId = scene.id
        context.coordinator.onHotspotTap = onHotspotTap
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.backgroundColor = theme.backgroundColor
        context.coordinator.onHotspotTap = onHotspotTap
        guard context.coordinator.lastSceneId != scene.id else { return }
        context.coordinator.lastSceneId = scene.id
        view.scene = scnScene
        if let cameraNode = scnScene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            view.pointOfView = cameraNode
            context.coordinator.camera.attach(to: view, cameraNode: cameraNode, framing: scene)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: camera)
    }

    final class Coordinator: NSObject {
        let camera: DollhouseCamera
        var lastSceneId: UUID?
        var onHotspotTap: ((String) -> Void)?

        init(camera: DollhouseCamera? = nil) {
            self.camera = camera ?? DollhouseCamera()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, name.hasPrefix("hotspot-") {
                        let photoId = String(name.dropFirst("hotspot-".count))
                        onHotspotTap?(photoId)
                        return
                    }
                    node = current.parent
                }
            }
        }
    }
}
