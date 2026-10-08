import Foundation
import SceneKit
import simd

enum DollhouseSceneBuilder {

    static func buildScene(from dollhouse: DollhouseScene) -> SCNScene {
        let scene = SCNScene()

        var nodesByPath: [String: SCNNode] = [:]
        let root = SCNNode()
        root.name = "Scene"
        scene.rootNode.addChildNode(root)
        nodesByPath["Scene"] = root

        let grouped = Dictionary(grouping: dollhouse.meshes) { $0.path.identifier }

        for (identifier, meshes) in grouped {
            let path = meshes.first!.path
            let parent = ensureNode(for: path, nodesByPath: &nodesByPath, root: root)
            for mesh in meshes {
                guard let geometry = makeGeometry(mesh) else { continue }
                let node = SCNNode(geometry: geometry)
                node.name = mesh.material.name
                parent.addChildNode(node)
            }
            if identifier.isEmpty { continue }
        }

        addLights(to: scene)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 500
        cameraNode.camera?.fieldOfView = 40
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(SCNNode())
        DollhouseCamera.placeDefault(cameraNode: cameraNode, framing: dollhouse)
        return scene
    }

    static func makeGeometry(_ mesh: DollhouseMesh) -> SCNGeometry? {
        guard !mesh.isEmpty else { return nil }
        let positionSource = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) })
        let normalSource = SCNGeometrySource(normals: mesh.vertices.map { SCNVector3($0.normal.x, $0.normal.y, $0.normal.z) })
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [positionSource, normalSource], elements: [element])
        let material = SCNMaterial()
        material.name = mesh.material.name
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(
            red: CGFloat(mesh.material.color.x),
            green: CGFloat(mesh.material.color.y),
            blue: CGFloat(mesh.material.color.z),
            alpha: CGFloat(mesh.material.color.w)
        )
        material.roughness.contents = NSNumber(value: mesh.material.roughness)
        material.metalness.contents = NSNumber(value: mesh.material.metalness)
        material.isDoubleSided = false
        geometry.materials = [material]
        return geometry
    }

    private static func ensureNode(for path: DollhouseNodePath, nodesByPath: inout [String: SCNNode], root: SCNNode) -> SCNNode {
        let components = path.components
        guard let first = components.first else { return root }
        var currentPath = first
        var currentNode = nodesByPath[currentPath] ?? {
            let node = SCNNode()
            node.name = first
            root.addChildNode(node)
            nodesByPath[currentPath] = node
            return node
        }()
        for component in components.dropFirst() {
            currentPath += "/" + component
            if let existing = nodesByPath[currentPath] {
                currentNode = existing
                continue
            }
            let node = SCNNode()
            node.name = component
            currentNode.addChildNode(node)
            nodesByPath[currentPath] = node
            currentNode = node
        }
        return currentNode
    }

    private static func addLights(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.75, alpha: 1.0)
        ambient.light?.intensity = 300
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.color = UIColor.white
        directional.light?.intensity = 800
        directional.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(directional)
    }
}
