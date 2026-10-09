import Foundation
import SceneKit
import UIKit
import simd

enum DollhouseSceneBuilder {

    static func buildScene(from dollhouse: DollhouseScene, includeAnnotations: Bool = true) -> SCNScene {
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

        if includeAnnotations {
            for section in dollhouse.floorSections where dollhouse.floorSections.count > 1 && !section.title.isEmpty && !section.title.hasPrefix("Floor not set") && section.boundsMin.x.isFinite && section.boundsMax.x.isFinite {
                let text = SCNText(string: section.title, extrusionDepth: 0.02)
                text.font = UIFont.systemFont(ofSize: 1.0, weight: .semibold)
                text.flatness = 0.05
                let textMaterial = SCNMaterial()
                textMaterial.diffuse.contents = UIColor(white: 0.1, alpha: 1.0)
                textMaterial.lightingModel = .constant
                textMaterial.isDoubleSided = true
                text.materials = [textMaterial]
                let textNode = SCNNode(geometry: text)
                textNode.scale = SCNVector3(0.4, 0.4, 0.4)
                let cx = (section.boundsMin.x + section.boundsMax.x) * 0.5
                let cz = (section.boundsMin.z + section.boundsMax.z) * 0.5
                let cy = section.boundsMax.y + 0.35
                let (minBound, maxBound) = text.boundingBox
                let textWidth = (maxBound.x - minBound.x) * 0.4
                textNode.position = SCNVector3(cx - textWidth * 0.5, cy, cz)
                root.addChildNode(textNode)
            }

            if let rawHeadingDeg = dollhouse.headingDeg, rawHeadingDeg.isFinite, dollhouse.boundsMin.x.isFinite {
                let headingDeg = ((rawHeadingDeg.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
                let compassText = SCNText(string: "N", extrusionDepth: 0.02)
                compassText.font = UIFont.systemFont(ofSize: 1.2, weight: .bold)
                compassText.flatness = 0.05
                let compassMaterial = SCNMaterial()
                compassMaterial.diffuse.contents = UIColor(red: 0.84, green: 0.27, blue: 0.24, alpha: 1.0)
                compassMaterial.lightingModel = .constant
                compassMaterial.isDoubleSided = true
                compassText.materials = [compassMaterial]
                let compassNode = SCNNode(geometry: compassText)
                compassNode.scale = SCNVector3(0.4, 0.4, 0.4)
                let baseX = dollhouse.boundsMin.x - 0.8
                let baseZ = dollhouse.boundsMin.z - 0.8
                let baseY = dollhouse.boundsMin.y + 0.1
                compassNode.position = SCNVector3(baseX, baseY, baseZ)
                root.addChildNode(compassNode)
                let headingRad = Float(headingDeg) * .pi / 180.0
                let length: Float = 1.5
                let dx = sin(headingRad)
                let dz = cos(headingRad)
                let lineGeom = SCNBox(width: 0.06, height: 0.02, length: CGFloat(length), chamferRadius: 0)
                lineGeom.firstMaterial?.diffuse.contents = UIColor(red: 0.84, green: 0.27, blue: 0.24, alpha: 1.0)
                lineGeom.firstMaterial?.lightingModel = .constant
                let lineNode = SCNNode(geometry: lineGeom)
                lineNode.position = SCNVector3(baseX + dx * length * 0.5, baseY, baseZ + dz * length * 0.5)
                lineNode.eulerAngles = SCNVector3(0, atan2(dx, dz), 0)
                root.addChildNode(lineNode)
            }
        }

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
