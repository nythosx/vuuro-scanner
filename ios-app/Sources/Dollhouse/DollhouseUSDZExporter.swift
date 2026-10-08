import Foundation
import ModelIO
import SceneKit
import simd

enum DollhouseUSDZExporterError: Error, LocalizedError {
    case usdzNotSupported
    case emptyScene

    var errorDescription: String? {
        switch self {
        case .usdzNotSupported: return "This device cannot write USDZ files."
        case .emptyScene: return "There is no 3D geometry to export."
        }
    }
}

enum DollhouseUSDZExporter {

    static func export(_ scene: DollhouseScene, to url: URL) throws {
        guard !scene.isEmpty else { throw DollhouseUSDZExporterError.emptyScene }
        var modelIOError: Error?
        if MDLAsset.canExportFileExtension("usdz") {
            do {
                try exportWithModelIO(scene, to: url)
                return
            } catch {
                modelIOError = error
            }
        }
        let sceneKitScene = DollhouseSceneBuilder.buildScene(from: scene)
        if sceneKitScene.write(to: url, options: nil, delegate: nil, progressHandler: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return
        }
        throw modelIOError ?? DollhouseUSDZExporterError.usdzNotSupported
    }

    private static func exportWithModelIO(_ scene: DollhouseScene, to url: URL) throws {
        let asset = MDLAsset()

        var objectsByPath: [String: MDLObject] = [:]
        let root = MDLObject()
        root.name = "Scene"
        asset.add(root)
        objectsByPath["Scene"] = root

        for mesh in scene.meshes {
            guard !mesh.isEmpty else { continue }
            guard let mdlMesh = makeMDLMesh(from: mesh) else { continue }
            let parent = ensureObject(for: mesh.path, objectsByPath: &objectsByPath, root: root)
            let holder = MDLObject()
            holder.name = mesh.material.name
            holder.addChild(mdlMesh)
            parent.addChild(holder)
        }

        try asset.export(to: url)
    }

    private static func ensureObject(for path: DollhouseNodePath, objectsByPath: inout [String: MDLObject], root: MDLObject) -> MDLObject {
        var currentPath = ""
        var currentNode = root
        for component in path.components {
            if component == "Scene" { currentPath = "Scene"; continue }
            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
            if let existing = objectsByPath[currentPath] {
                currentNode = existing
                continue
            }
            let node = MDLObject()
            node.name = component
            currentNode.addChild(node)
            objectsByPath[currentPath] = node
            currentNode = node
        }
        return currentNode
    }

    private static func makeMDLMesh(from mesh: DollhouseMesh) -> MDLMesh? {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: MemoryLayout<Float>.size * 3,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 6)

        var vertexBytes: [Float] = []
        vertexBytes.reserveCapacity(mesh.vertices.count * 6)
        for vertex in mesh.vertices {
            vertexBytes.append(vertex.position.x)
            vertexBytes.append(vertex.position.y)
            vertexBytes.append(vertex.position.z)
            vertexBytes.append(vertex.normal.x)
            vertexBytes.append(vertex.normal.y)
            vertexBytes.append(vertex.normal.z)
        }
        let vertexData = vertexBytes.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexBuffer = MDLMeshBufferData(type: .vertex, data: vertexData)

        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexBuffer = MDLMeshBufferData(type: .index, data: indexData)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: mesh.indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: makeMaterial(from: mesh.material)
        )

        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: mesh.vertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )
        mdlMesh.name = mesh.material.name
        return mdlMesh
    }

    private static func makeMaterial(from material: DollhouseMaterial) -> MDLMaterial {
        let mdlMaterial = MDLMaterial(name: material.name, scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())

        let baseColor = MDLMaterialProperty(
            name: "baseColor",
            semantic: .baseColor,
            float3: SIMD3<Float>(material.color.x, material.color.y, material.color.z)
        )
        mdlMaterial.setProperty(baseColor)

        let opacity = MDLMaterialProperty(name: "opacity", semantic: .opacity, float: material.color.w)
        mdlMaterial.setProperty(opacity)

        let roughness = MDLMaterialProperty(name: "roughness", semantic: .roughness, float: material.roughness)
        mdlMaterial.setProperty(roughness)

        let metallic = MDLMaterialProperty(name: "metallic", semantic: .metallic, float: material.metalness)
        mdlMaterial.setProperty(metallic)

        return mdlMaterial
    }
}
