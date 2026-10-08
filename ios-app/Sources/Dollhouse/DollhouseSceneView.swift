import SceneKit
import SwiftUI

struct DollhouseSceneView: UIViewRepresentable {
    let scene: DollhouseScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        let scnScene = DollhouseSceneBuilder.buildScene(from: scene)
        view.scene = scnScene
        if let cameraNode = scnScene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            view.pointOfView = cameraNode
            context.coordinator.camera.attach(to: view, cameraNode: cameraNode, framing: scene)
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let scnScene = DollhouseSceneBuilder.buildScene(from: scene)
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
    }
}
