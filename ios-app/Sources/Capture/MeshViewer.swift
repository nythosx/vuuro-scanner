import SceneKit
import SwiftUI
import UIKit

struct MeshViewer: View {
    let captureURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var built: MeshSceneBuilder.Built?
    @State private var mode: Mode = .clay
    @State private var isLoading = true
    @State private var loadError: String?

    enum Mode: String, CaseIterable, Identifiable {
        case clay = "Clay"
        case wireframe = "Mesh"
        case classes = "Classes"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if let built {
                MeshSceneView(
                    scene: built.scene,
                    cameraNode: built.cameraNode,
                    target: built.center,
                    background: mode == .wireframe ? .black : UIColor(white: 0.93, alpha: 1)
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                Color(white: 0.93).ignoresSafeArea(edges: .bottom)
            }
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
        .navigationTitle((built?.triangles ?? 0) > 0 ? "\(built?.triangles ?? 0) triangles" : "3D mesh")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onChange(of: mode) { _, newMode in
            if let built { MeshSceneBuilder.apply(newMode, to: built.scene) }
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
        case .success(let loaded):
            MeshSceneBuilder.apply(mode, to: loaded.scene)
            built = loaded
        case .failure(let error):
            loadError = "Could not load the mesh: \(error.localizedDescription)"
        }
    }
}

struct MeshSceneView: UIViewRepresentable {
    let scene: SCNScene
    let cameraNode: SCNNode
    let target: SCNVector3
    let background: UIColor

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = background
        view.defaultCameraController.pointOfView = cameraNode
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = target
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.backgroundColor = background
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

    static let ceilingClass: UInt8 = 3

    struct Built {
        let scene: SCNScene
        let triangles: Int
        let cameraNode: SCNNode
        let center: SCNVector3
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
            var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
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
                let (boxMin, boxMax) = node.boundingBox
                for corner in corners(SIMD3<Float>(boxMin), SIMD3<Float>(boxMax)) {
                    let world = node.simdTransform * SIMD4<Float>(corner, 1)
                    let point = SIMD3<Float>(world.x, world.y, world.z)
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
            }
            guard triangles > 0 else {
                return .failure(PlainError(message: "The capture has no mesh triangles."))
            }
            let center = (lower + upper) / 2
            let size = max(simd_length(upper - lower), 1)
            let camera = SCNCamera()
            camera.fieldOfView = 50
            camera.zNear = 0.05
            camera.zFar = Double(size * 10)
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.simdPosition = center + SIMD3<Float>(0, size * 0.8, size * 0.7)
            cameraNode.simdLook(at: center, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
            scene.rootNode.addChildNode(cameraNode)
            return .success(Built(scene: scene, triangles: triangles, cameraNode: cameraNode, center: SCNVector3(center)))
        } catch {
            return .failure(error)
        }
    }

    static func apply(_ mode: MeshViewer.Mode, to scene: SCNScene) {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                let classId = UInt8(material.name ?? "") ?? 0
                let hidden = classId == ceilingClass && mode != .wireframe
                material.colorBufferWriteMask = hidden ? [] : .all
                material.writesToDepthBuffer = !hidden
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

    private static func corners(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3(low.x, low.y, low.z), SIMD3(high.x, low.y, low.z),
            SIMD3(low.x, high.y, low.z), SIMD3(high.x, high.y, low.z),
            SIMD3(low.x, low.y, high.z), SIMD3(high.x, low.y, high.z),
            SIMD3(low.x, high.y, high.z), SIMD3(high.x, high.y, high.z)
        ]
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
