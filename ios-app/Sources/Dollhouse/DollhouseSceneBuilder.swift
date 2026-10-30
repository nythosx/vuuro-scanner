import Foundation
import SceneKit
import UIKit
import simd

enum DollhouseSceneBuilder {

    static func buildScene(
        from dollhouse: DollhouseScene,
        includeAnnotations: Bool = true,
        visibility: DollhouseLayerVisibility = DollhouseLayerVisibility(),
        theme: DollhouseTheme = .light
    ) -> SCNScene {
        let scene = SCNScene()

        var nodesByPath: [String: SCNNode] = [:]
        let root = SCNNode()
        root.name = "Scene"
        scene.rootNode.addChildNode(root)
        nodesByPath["Scene"] = root

        let visibleMeshes = dollhouse.meshes.filter { visibility.isVisible($0.layer) }
        let grouped = Dictionary(grouping: visibleMeshes) { $0.path.identifier }

        for (_, meshes) in grouped {
            let path = meshes.first!.path
            let parent = ensureNode(for: path, nodesByPath: &nodesByPath, root: root)
            for mesh in meshes {
                guard let geometry = makeGeometry(mesh, theme: theme) else { continue }
                let node = SCNNode(geometry: geometry)
                node.name = mesh.material.name
                parent.addChildNode(node)
            }
        }

        addLights(to: scene, theme: theme)

        if includeAnnotations, visibility.roomLabels {
            addFloorLabels(to: root, dollhouse: dollhouse, theme: theme)
            addRoomLabels(to: root, dollhouse: dollhouse, theme: theme)
        }
        if includeAnnotations, visibility.hotspotMarkers {
            addHotspots(to: root, dollhouse: dollhouse)
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

    static func makeGeometry(_ mesh: DollhouseMesh, theme: DollhouseTheme = .light) -> SCNGeometry? {
        guard !mesh.isEmpty else { return nil }
        let positionSource = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) })
        let normalSource = SCNGeometrySource(normals: mesh.vertices.map { SCNVector3($0.normal.x, $0.normal.y, $0.normal.z) })
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)

        var sources: [SCNGeometrySource] = [positionSource, normalSource]
        if mesh.vertices.allSatisfy({ $0.uv != nil }) {
            let uvSource = SCNGeometrySource(textureCoordinates: mesh.vertices.map {
                CGPoint(x: CGFloat($0.uv!.x), y: CGFloat($0.uv!.y))
            })
            sources.append(uvSource)
        }
        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.name = mesh.material.name
        material.lightingModel = .physicallyBased
        if let imageData = mesh.material.imageData, let image = UIImage(data: imageData) {
            material.diffuse.contents = image
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
        } else {
            var color = mesh.material.color
            if mesh.material == DollhouseMaterial.exteriorWall {
                color = theme.exteriorWallColor
            } else if mesh.material == DollhouseMaterial.interiorWall {
                color = theme.interiorWallColor
            } else if mesh.material == DollhouseMaterial.door {
                color = theme.doorColor
            } else if mesh.material == DollhouseMaterial.window {
                color = theme.windowColor
            }
            material.diffuse.contents = UIColor(
                red: CGFloat(color.x),
                green: CGFloat(color.y),
                blue: CGFloat(color.z),
                alpha: CGFloat(color.w)
            )
        }
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

    private static func addLights(to scene: SCNScene, theme: DollhouseTheme) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = theme == .light
            ? UIColor(white: 0.85, alpha: 1.0)
            : UIColor(white: 0.45, alpha: 1.0)
        ambient.light?.intensity = theme.ambientIntensity
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.color = UIColor.white
        directional.light?.intensity = theme.directionalIntensity
        directional.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(directional)
    }

    private static func addFloorLabels(to root: SCNNode, dollhouse: DollhouseScene, theme: DollhouseTheme) {
        for section in dollhouse.floorSections where dollhouse.floorSections.count > 1 && !section.title.isEmpty && !section.title.hasPrefix("Floor not set") && section.boundsMin.x.isFinite && section.boundsMax.x.isFinite {
            let text = SCNText(string: section.title, extrusionDepth: 0.02)
            text.font = UIFont.systemFont(ofSize: 1.0, weight: .semibold)
            text.flatness = 0.05
            let textMaterial = SCNMaterial()
            textMaterial.diffuse.contents = theme == .light ? UIColor(white: 0.1, alpha: 1.0) : UIColor(white: 0.92, alpha: 1.0)
            textMaterial.lightingModel = .constant
            textMaterial.isDoubleSided = true
            text.materials = [textMaterial]
            let textNode = SCNNode(geometry: text)
            textNode.name = "floorLabel-\(section.id)"
            textNode.scale = SCNVector3(0.4, 0.4, 0.4)
            let cz = (section.boundsMin.z + section.boundsMax.z) * 0.5
            let (minBound, maxBound) = text.boundingBox
            let textWidth = (maxBound.x - minBound.x) * 0.4
            textNode.position = SCNVector3(section.boundsMin.x - textWidth - 0.4, section.boundsMin.y + 0.3, cz)
            root.addChildNode(textNode)
        }
    }

    private static func addRoomLabels(to root: SCNNode, dollhouse: DollhouseScene, theme: DollhouseTheme) {
        for label in dollhouse.roomLabels where !label.text.isEmpty && label.floorCenter.x.isFinite && label.floorCenter.z.isFinite {
            let small = label.areaM2 < 4
            let maxCharacters = small ? 10 : 22
            let shown = label.text.count > maxCharacters ? String(label.text.prefix(maxCharacters - 1)) + "\u{2026}" : label.text
            let text = SCNText(string: shown, extrusionDepth: 0.01)
            text.font = UIFont.systemFont(ofSize: 1.0, weight: .semibold)
            text.flatness = 0.05
            let material = SCNMaterial()
            material.diffuse.contents = theme == .light ? UIColor(white: 0.12, alpha: 1.0) : UIColor(white: 0.95, alpha: 1.0)
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.readsFromDepthBuffer = false
            text.materials = [material]
            let textNode = SCNNode(geometry: text)
            let (minBound, maxBound) = text.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation((minBound.x + maxBound.x) / 2, (minBound.y + maxBound.y) / 2, 0)
            let scale: Float = small ? 0.22 : 0.3
            textNode.scale = SCNVector3(scale, scale, scale)
            textNode.renderingOrder = 10
            let node = SCNNode()
            node.name = "roomLabel-\(label.id)"
            node.position = SCNVector3(label.floorCenter.x, label.floorCenter.y + label.labelHeightM, label.floorCenter.z)
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            node.constraints = [billboard]
            node.addChildNode(textNode)
            root.addChildNode(node)
        }
    }

    private static func addHotspots(to root: SCNNode, dollhouse: DollhouseScene) {
        for hotspot in dollhouse.hotspots {
            let sphere = SCNSphere(radius: 0.12)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: 1.0, green: 0.51, blue: 0.07, alpha: 1.0)
            material.lightingModel = .constant
            material.isDoubleSided = true
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.name = "hotspot-\(hotspot.id)"
            node.position = SCNVector3(hotspot.position.x, hotspot.position.y, hotspot.position.z)
            root.addChildNode(node)
        }
    }
}
