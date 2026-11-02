import Foundation
import ModelIO
import SceneKit
import simd
import UIKit

enum DollhouseUSDZExporterError: Error, LocalizedError {
    case usdzNotSupported
    case emptyScene
    case writeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .usdzNotSupported: return "This device cannot write USDZ files."
        case .emptyScene: return "There is no 3D geometry to export."
        case .writeFailed(let reason): return "Couldn't write the 3D model file: \(reason)"
        }
    }
}

enum DollhouseUSDZExporter {

    static func export(_ scene: DollhouseScene, to url: URL) throws {
        guard !scene.isEmpty else { throw DollhouseUSDZExporterError.emptyScene }
        let textureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dollhouse-textures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: textureDirectory) }
        let sceneKitScene = DollhouseSceneBuilder.buildScene(from: scene, includeAnnotations: false)
        linkTexturesToFiles(in: sceneKitScene.rootNode, directory: textureDirectory)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = sceneKitScene
        _ = renderer.prepare(sceneKitScene.rootNode, shouldAbortBlock: nil)
        if sceneKitScene.write(to: url, options: nil, delegate: nil, progressHandler: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return
        }
        var modelIOError: Error?
        if MDLAsset.canExportFileExtension("usdz") {
            do {
                try exportWithModelIO(scene, to: url, textureDirectory: textureDirectory)
                return
            } catch {
                modelIOError = error
            }
        }
        throw DollhouseUSDZExporterError.writeFailed(reason: modelIOError?.localizedDescription ?? "The USDZ file could not be written to disk.")
    }

    static func linkTexturesToFiles(in root: SCNNode, directory: URL) {
        var written: [ObjectIdentifier: URL] = [:]
        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                guard let image = material.diffuse.contents as? UIImage else { continue }
                let key = ObjectIdentifier(image)
                if let existing = written[key] {
                    material.diffuse.contents = existing
                    continue
                }
                guard let fileURL = writeTexture(image.jpegData(compressionQuality: 0.85), directory: directory) else { continue }
                written[key] = fileURL
                material.diffuse.contents = fileURL
            }
        }
    }

    private static func writeTexture(_ data: Data?, directory: URL) -> URL? {
        guard let data, !data.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString).jpg")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            DiagnosticsLog.shared.record("USDZ export: could not write a wall texture: \(error.localizedDescription)", category: .error)
            return nil
        }
    }

    private static func exportWithModelIO(_ scene: DollhouseScene, to url: URL, textureDirectory: URL) throws {
        let asset = MDLAsset()

        var objectsByPath: [String: MDLObject] = [:]
        let root = MDLObject()
        root.name = "Scene"
        asset.add(root)
        objectsByPath["Scene"] = root

        for mesh in scene.meshes {
            guard !mesh.isEmpty, mesh.layer != .ceiling else { continue }
            guard let mdlMesh = makeMDLMesh(from: mesh, textureDirectory: textureDirectory) else { continue }
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

    private static func makeMDLMesh(from mesh: DollhouseMesh, textureDirectory: URL) -> MDLMesh? {
        let textured = mesh.material.imageData != nil && mesh.vertices.allSatisfy { $0.uv != nil }
        let floatsPerVertex = textured ? 8 : 6
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
        if textured {
            vertexDescriptor.attributes[2] = MDLVertexAttribute(
                name: MDLVertexAttributeTextureCoordinate,
                format: .float2,
                offset: MemoryLayout<Float>.size * 6,
                bufferIndex: 0
            )
        }
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * floatsPerVertex)

        var vertexBytes: [Float] = []
        vertexBytes.reserveCapacity(mesh.vertices.count * floatsPerVertex)
        for vertex in mesh.vertices {
            vertexBytes.append(vertex.position.x)
            vertexBytes.append(vertex.position.y)
            vertexBytes.append(vertex.position.z)
            vertexBytes.append(vertex.normal.x)
            vertexBytes.append(vertex.normal.y)
            vertexBytes.append(vertex.normal.z)
            if textured, let uv = vertex.uv {
                vertexBytes.append(uv.x)
                vertexBytes.append(uv.y)
            }
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
            material: makeMaterial(from: mesh.material, textureDirectory: textureDirectory)
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

    private static func makeMaterial(from material: DollhouseMaterial, textureDirectory: URL) -> MDLMaterial {
        let mdlMaterial = MDLMaterial(name: material.name, scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())

        if let textureURL = writeTexture(material.imageData, directory: textureDirectory) {
            mdlMaterial.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, url: textureURL))
        } else {
            let baseColor = MDLMaterialProperty(
                name: "baseColor",
                semantic: .baseColor,
                float3: SIMD3<Float>(material.color.x, material.color.y, material.color.z)
            )
            mdlMaterial.setProperty(baseColor)
        }

        let opacity = MDLMaterialProperty(name: "opacity", semantic: .opacity, float: material.color.w)
        mdlMaterial.setProperty(opacity)

        let roughness = MDLMaterialProperty(name: "roughness", semantic: .roughness, float: material.roughness)
        mdlMaterial.setProperty(roughness)

        let metallic = MDLMaterialProperty(name: "metallic", semantic: .metallic, float: material.metalness)
        mdlMaterial.setProperty(metallic)

        return mdlMaterial
    }
}
