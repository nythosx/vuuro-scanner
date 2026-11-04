import SceneKit
import SwiftUI
import UIKit

struct MeshViewer: View {
    let captureURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var scene: SCNScene = {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        return scene
    }()
    @State private var mode: Mode = .clay
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var triangleCount = 0

    enum Mode: String, CaseIterable, Identifiable {
        case clay = "Clay"
        case wireframe = "Mesh"
        case classes = "Classes"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .background(mode == .wireframe ? Color.black : Color(white: 0.93))
                .ignoresSafeArea(edges: .bottom)
            if isLoading {
                ProgressView("Loading mesh")
            } else if let loadError {
                Text(loadError)
                    .font(.system(size: 15))
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(triangleCount > 0 ? "\(triangleCount) triangles" : "3D mesh")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onChange(of: mode) { _, newMode in
            MeshSceneBuilder.apply(newMode, to: scene)
        }
        .task {
            await load()
        }
    }

    private func load() async {
        let url = captureURL
        let result = await Task.detached(priority: .userInitiated) {
            MeshSceneBuilder.build(captureURL: url)
        }.value
        isLoading = false
        switch result {
        case .success(let built):
            for child in built.scene.rootNode.childNodes {
                child.removeFromParentNode()
                scene.rootNode.addChildNode(child)
            }
            triangleCount = built.triangles
            MeshSceneBuilder.apply(mode, to: scene)
        case .failure(let error):
            loadError = "Could not load the mesh: \(error.localizedDescription)"
        }
    }
}

enum MeshSceneBuilder {
    static let classColors: [UInt8: UIColor] = [
        0: UIColor(white: 0.7, alpha: 1),
        1: UIColor(red: 0.62, green: 0.74, blue: 0.86, alpha: 1),
        2: UIColor(red: 0.72, green: 0.56, blue: 0.40, alpha: 1),
        3: UIColor(white: 0.95, alpha: 1),
        4: UIColor(red: 0.95, green: 0.62, blue: 0.25, alpha: 1),
        5: UIColor(red: 0.62, green: 0.45, blue: 0.85, alpha: 1),
        6: UIColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1),
        7: UIColor(red: 0.40, green: 0.80, blue: 0.45, alpha: 1)
    ]

    struct Built {
        let scene: SCNScene
        let triangles: Int
    }

    struct AnchorEntry: Decodable {
        let fileStem: String
        let transform: [Float]
        let vertexCount: Int
        let faceCount: Int
        let normalsFormat: String?
        let classesFormat: String?

        enum CodingKeys: String, CodingKey {
            case fileStem = "file_stem"
            case transform
            case vertexCount = "vertex_count"
            case faceCount = "face_count"
            case normalsFormat = "normals_format"
            case classesFormat = "classes_format"
        }
    }

    struct AnchorIndex: Decodable {
        let anchors: [AnchorEntry]
    }

    static func build(captureURL: URL) -> Result<Built, Error> {
        let meshURL = captureURL.appendingPathComponent("mesh", isDirectory: true)
        do {
            let index = try JSONDecoder().decode(AnchorIndex.self, from: Data(contentsOf: meshURL.appendingPathComponent("anchors.json")))
            let scene = SCNScene()
            var triangles = 0
            for entry in index.anchors {
                guard entry.transform.count == 16, entry.vertexCount > 0, entry.faceCount > 0 else { continue }
                let vertices = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).vertices"))
                let faces = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).faces"))
                guard vertices.count == entry.vertexCount * 12, faces.count == entry.faceCount * 12 else { continue }
                var sources = [SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: entry.vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)]
                if entry.normalsFormat != nil {
                    let normals = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).normals"))
                    if normals.count == vertices.count {
                        sources.append(SCNGeometrySource(data: normals, semantic: .normal, vectorCount: entry.vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
                    }
                }
                var classes: Data?
                if entry.classesFormat != nil {
                    let loaded = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).classes"))
                    if loaded.count == entry.faceCount { classes = loaded }
                }
                let (elements, materials) = elementsByClass(faces: faces, faceCount: entry.faceCount, classes: classes)
                let geometry = SCNGeometry(sources: sources, elements: elements)
                geometry.materials = materials
                let node = SCNNode(geometry: geometry)
                node.simdTransform = matrix(entry.transform)
                scene.rootNode.addChildNode(node)
                triangles += entry.faceCount
            }
            guard triangles > 0 else {
                return .failure(PlainError(message: "The capture has no mesh triangles."))
            }
            return .success(Built(scene: scene, triangles: triangles))
        } catch {
            return .failure(error)
        }
    }

    static func apply(_ mode: MeshViewer.Mode, to scene: SCNScene) {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                let classId = UInt8(material.name ?? "") ?? 0
                switch mode {
                case .clay:
                    material.fillMode = .fill
                    material.diffuse.contents = UIColor(white: 0.82, alpha: 1)
                case .wireframe:
                    material.fillMode = .lines
                    material.diffuse.contents = UIColor(red: 0.45, green: 0.45, blue: 1, alpha: 1)
                case .classes:
                    material.fillMode = .fill
                    material.diffuse.contents = classColors[classId] ?? UIColor.gray
                }
            }
        }
    }

    private static func elementsByClass(faces: Data, faceCount: Int, classes: Data?) -> ([SCNGeometryElement], [SCNMaterial]) {
        guard let classes else {
            return ([SCNGeometryElement(data: faces, primitiveType: .triangles, primitiveCount: faceCount, bytesPerIndex: 4)], [material(classId: 0)])
        }
        var buckets: [UInt8: Data] = [:]
        faces.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for face in 0..<faceCount {
                let classId = classes[classes.startIndex + face]
                let slice = UnsafeRawBufferPointer(rebasing: raw[(face * 12)..<(face * 12 + 12)])
                buckets[classId, default: Data()].append(contentsOf: slice)
            }
        }
        let ordered = buckets.keys.sorted()
        let elements = ordered.map { key -> SCNGeometryElement in
            let data = buckets[key] ?? Data()
            return SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: data.count / 12, bytesPerIndex: 4)
        }
        return (elements, ordered.map(material(classId:)))
    }

    private static func material(classId: UInt8) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = String(classId)
        material.isDoubleSided = true
        material.lightingModel = .lambert
        return material
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }
}
