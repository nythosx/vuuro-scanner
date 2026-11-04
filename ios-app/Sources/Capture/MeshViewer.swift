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
    @State private var frames: [MeshFrame] = []
    @State private var skippedFrames = 0
    @State private var frameError: String?
    @State private var frameIndex: Int?
    @State private var orbitPose: simd_float4x4?
    @State private var showPhoto = false
    @State private var photo: UIImage?
    @State private var photoError: String?
    @State private var texturing = false
    @State private var textured = false
    @State private var textureNote: String?
    @State private var showFilledFloor = false
    @State private var hasFilledFloor = false

    enum Mode: String, CaseIterable, Identifiable {
        case clay = "Clay"
        case wireframe = "Mesh"
        case classes = "Classes"
        case texture = "Texture"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if let built {
                MeshSceneView(
                    scene: built.scene,
                    cameraNode: built.cameraNode,
                    target: built.center,
                    background: mode == .wireframe ? .black : UIColor(white: 0.93, alpha: 1),
                    interactive: frameIndex == nil
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                Color(white: 0.93).ignoresSafeArea(edges: .bottom)
            }
            if frameIndex != nil, showPhoto {
                photoLayer
            }
            if isLoading {
                ProgressView("Loading mesh")
            } else if texturing {
                ProgressView("Coloring the mesh from the photos")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let loadError {
                messageCard(loadError)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isLoading || texturing)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                if hasFilledFloor {
                    Toggle("Show floor filled where the camera did not see", isOn: $showFilledFloor)
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .offset(y: 40)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if built != nil {
                pathControls
            }
        }
        .navigationTitle((built?.triangles ?? 0) > 0 ? "\(built?.triangles ?? 0) triangles" : "3D mesh")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onChange(of: mode) { _, _ in
            applyMode()
        }
        .onChange(of: showFilledFloor) { _, _ in
            applyMode()
        }
        .onChange(of: frameIndex) { _, _ in
            moveCamera()
        }
        .task(id: mode) {
            if mode == .texture { await colorize() }
        }
        .task(id: photoKey) {
            await loadPhoto()
        }
        .task {
            await load()
        }
    }

    private var photoKey: String {
        guard showPhoto, let frameIndex else { return "" }
        return "\(frameIndex)"
    }

    private var photoLayer: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else if let photoError {
                    messageCard(photoError)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private var pathControls: some View {
        VStack(spacing: 10) {
            if let textureNote, mode == .texture {
                Text(textureNote)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let frameError {
                Text(frameError)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if skippedFrames > 0 {
                Text("\(skippedFrames) frames could not be read")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let frameIndex, !frames.isEmpty {
                Text("Frame \(frameIndex + 1) of \(frames.count)")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                HStack(spacing: 12) {
                    Button {
                        leavePath()
                    } label: {
                        Label("Back", systemImage: "arrow.left")
                    }
                    Slider(
                        value: Binding(
                            get: { Double(frameIndex) },
                            set: { self.frameIndex = min(max(Int($0.rounded()), 0), frames.count - 1) }
                        ),
                        in: 0...Double(max(frames.count - 1, 1)),
                        step: 1
                    )
                    .disabled(frames.count < 2)
                    Button {
                        self.frameIndex = max(frameIndex - 1, 0)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(frameIndex == 0)
                    Button {
                        self.frameIndex = min(frameIndex + 1, frames.count - 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(frameIndex >= frames.count - 1)
                }
                Toggle("Show the photo of this frame", isOn: $showPhoto)
                    .font(.system(size: 15))
            } else if !frames.isEmpty {
                Button {
                    enterPath()
                } label: {
                    Label("Walk the capture path (\(frames.count) frames)", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func messageCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
    }

    private func enterPath() {
        guard let built, !frames.isEmpty else { return }
        orbitPose = built.cameraNode.simdTransform
        frameIndex = 0
        applyMode()
        moveCamera()
    }

    private func leavePath() {
        guard let built else { return }
        frameIndex = nil
        showPhoto = false
        if let orbitPose {
            built.cameraNode.simdTransform = orbitPose
        }
        built.cameraNode.camera?.fieldOfView = MeshSceneBuilder.orbitFieldOfView
        applyMode()
    }

    private func applyMode() {
        guard let built else { return }
        MeshSceneBuilder.apply(mode, showCeiling: frameIndex != nil, showFilledFloor: showFilledFloor, parts: built.parts)
    }

    private func colorize() async {
        guard let built, !textured, !texturing else { return }
        guard !frames.isEmpty else {
            textureNote = "This capture has no frame photos to color the mesh with."
            return
        }
        texturing = true
        let inputs = built.parts.map { MeshTexturer.PartInput(vertices: $0.vertices, vertexCount: $0.vertexCount, transform: $0.transform) }
        let frameList = frames
        let work = Task.detached(priority: .userInitiated) {
            MeshTexturer.colorize(parts: inputs, frames: frameList)
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        texturing = false
        switch result {
        case .success(let output):
            for (part, colors) in zip(built.parts, output.colors) where colors.count == part.vertexCount * 12 {
                part.textured = MeshSceneBuilder.texturedGeometry(plain: part.plain, colors: colors, vertexCount: part.vertexCount)
            }
            textured = true
            let percent = output.totalVertices > 0 ? output.coloredVertices * 100 / output.totalVertices : 0
            var note = "Colored from \(output.framesUsed) photos, \(percent)% of the mesh seen in a photo"
            if output.framesFailed > 0 {
                note += ", \(output.framesFailed) photos could not be opened"
            }
            textureNote = note
            applyMode()
        case .failure(let error):
            if error is CancellationError { return }
            textureNote = "Could not color the mesh: \(error.localizedDescription)"
        }
    }

    private func moveCamera() {
        guard let built, let frameIndex, frames.indices.contains(frameIndex) else { return }
        let frame = frames[frameIndex]
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.2
        built.cameraNode.simdTransform = frame.portraitPose
        built.cameraNode.camera?.fieldOfView = frame.verticalFieldOfView
        SCNTransaction.commit()
    }

    private func loadPhoto() async {
        photo = nil
        photoError = nil
        guard showPhoto, let frameIndex, frames.indices.contains(frameIndex) else { return }
        guard let url = frames[frameIndex].imageURL else {
            photoError = "This frame has no photo."
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<UIImage, Error> in
            do {
                let data = try Data(contentsOf: url)
                guard let cgImage = UIImage(data: data)?.cgImage else {
                    return .failure(PlainError(message: "The photo of this frame could not be decoded."))
                }
                return .success(UIImage(cgImage: cgImage, scale: 1, orientation: .right))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let image):
            photo = image
        case .failure(let error):
            photoError = "Could not open the photo of this frame: \(error.localizedDescription)"
        }
    }

    private func load() async {
        let url = captureURL
        let result = await Task.detached(priority: .userInitiated) {
            MeshSceneBuilder.build(captureURL: url)
        }.value
        switch result {
        case .success(let loaded):
            MeshSceneBuilder.apply(mode, showCeiling: false, showFilledFloor: showFilledFloor, parts: loaded.parts)
            hasFilledFloor = loaded.parts.contains { part in
                part.plain.materials.contains { $0.name == String(MeshSceneBuilder.filledFloorClass) }
            }
            built = loaded
        case .failure(let error):
            loadError = "Could not load the mesh: \(error.localizedDescription)"
        }
        let frameResult = await Task.detached(priority: .userInitiated) {
            MeshFrameIndex.load(captureURL: url)
        }.value
        isLoading = false
        switch frameResult {
        case .success(let loaded):
            frames = loaded.frames.filter { $0.imageURL != nil }
            skippedFrames = loaded.skipped + loaded.frames.count - frames.count
        case .failure(let error):
            frameError = "Could not read the capture frames: \(error.localizedDescription)"
        }
    }
}

struct MeshFrame {
    let index: Int
    let cameraTransform: simd_float4x4
    let verticalFieldOfView: CGFloat
    let imageURL: URL?
    let imageWidth: Int
    let imageHeight: Int
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let depthURL: URL?
    let confidenceURL: URL?
    let depthWidth: Int
    let depthHeight: Int

    var portraitPose: simd_float4x4 {
        cameraTransform * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
    }
}

enum MeshFrameIndex {
    static let framesFolder = "frames"

    struct Loaded {
        let frames: [MeshFrame]
        let skipped: Int
    }

    private struct Meta: Decodable {
        let index: Int
        let image: String?
        let imageWidth: Int
        let imageHeight: Int
        let cameraTransform: [Float]
        let intrinsics: [Float]
        let depth: String?
        let confidence: String?
        let depthWidth: Int?
        let depthHeight: Int?

        enum CodingKeys: String, CodingKey {
            case index
            case image
            case imageWidth = "image_width"
            case imageHeight = "image_height"
            case cameraTransform = "camera_transform"
            case intrinsics = "intrinsics_fx_fy_cx_cy"
            case depth
            case confidence
            case depthWidth = "depth_width"
            case depthHeight = "depth_height"
        }
    }

    static func load(captureURL: URL, folder folderName: String = MeshFrameIndex.framesFolder) -> Result<Loaded, Error> {
        let folder = captureURL.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .success(Loaded(frames: [], skipped: 0))
        }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
            var frames: [MeshFrame] = []
            var skipped = 0
            let decoder = JSONDecoder()
            for name in names {
                do {
                    let data = try Data(contentsOf: folder.appendingPathComponent(name))
                    let meta = try decoder.decode(Meta.self, from: data)
                    guard let frame = frame(from: meta, folder: folder) else {
                        skipped += 1
                        continue
                    }
                    frames.append(frame)
                } catch {
                    skipped += 1
                }
            }
            frames.sort { $0.index < $1.index }
            return .success(Loaded(frames: frames, skipped: skipped))
        } catch {
            return .failure(error)
        }
    }

    private static func frame(from meta: Meta, folder: URL) -> MeshFrame? {
        guard meta.cameraTransform.count == 16,
              meta.cameraTransform.allSatisfy({ $0.isFinite }),
              meta.intrinsics.count == 4,
              meta.intrinsics.allSatisfy({ $0.isFinite }),
              meta.intrinsics[0] > 0,
              meta.intrinsics[1] > 0,
              meta.imageWidth > 0,
              meta.imageHeight > 0 else { return nil }
        let values = meta.cameraTransform
        let transform = simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
        let halfWidth = Float(meta.imageWidth) / 2
        let fov = 2 * atan(halfWidth / meta.intrinsics[0]) * 180 / Float.pi
        return MeshFrame(
            index: meta.index,
            cameraTransform: transform,
            verticalFieldOfView: CGFloat(fov),
            imageURL: meta.image.flatMap { $0.isEmpty ? nil : folder.appendingPathComponent($0) },
            imageWidth: meta.imageWidth,
            imageHeight: meta.imageHeight,
            fx: meta.intrinsics[0],
            fy: meta.intrinsics[1],
            cx: meta.intrinsics[2],
            cy: meta.intrinsics[3],
            depthURL: meta.depth.map { folder.appendingPathComponent($0) },
            confidenceURL: meta.confidence.map { folder.appendingPathComponent($0) },
            depthWidth: meta.depthWidth ?? 0,
            depthHeight: meta.depthHeight ?? 0
        )
    }
}

struct MeshSceneView: UIViewRepresentable {
    let scene: SCNScene
    let cameraNode: SCNNode
    let target: SCNVector3
    let background: UIColor
    let interactive: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = interactive
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
        view.allowsCameraControl = interactive
        if view.pointOfView !== cameraNode {
            view.pointOfView = cameraNode
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
        7: UIColor(red: 0.40, green: 0.80, blue: 0.45, alpha: 1),
        8: UIColor(red: 0.85, green: 0.45, blue: 0.55, alpha: 1),
        9: UIColor(red: 1.0, green: 0.82, blue: 0.55, alpha: 1)
    ]

    static let ceilingClass: UInt8 = 3
    static let filledFloorClass: UInt8 = 9
    static let orbitFieldOfView: CGFloat = 50

    final class MeshPart {
        let node: SCNNode
        let plain: SCNGeometry
        let vertices: Data
        let vertexCount: Int
        let transform: simd_float4x4
        var textured: SCNGeometry?

        init(node: SCNNode, plain: SCNGeometry, vertices: Data, vertexCount: Int, transform: simd_float4x4) {
            self.node = node
            self.plain = plain
            self.vertices = vertices
            self.vertexCount = vertexCount
            self.transform = transform
        }
    }

    struct Built {
        let scene: SCNScene
        let triangles: Int
        let cameraNode: SCNNode
        let center: SCNVector3
        let parts: [MeshPart]
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
            var parts: [MeshPart] = []
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
                parts.append(MeshPart(node: node, plain: geometry, vertices: vertices, vertexCount: entry.vertexCount, transform: node.simdTransform))
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
            camera.fieldOfView = orbitFieldOfView
            camera.zNear = 0.05
            camera.zFar = Double(size * 10)
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.simdPosition = center + SIMD3<Float>(0, size * 0.8, size * 0.7)
            cameraNode.simdLook(at: center, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
            scene.rootNode.addChildNode(cameraNode)
            return .success(Built(scene: scene, triangles: triangles, cameraNode: cameraNode, center: SCNVector3(center), parts: parts))
        } catch {
            return .failure(error)
        }
    }

    static func apply(_ mode: MeshViewer.Mode, showCeiling: Bool, showFilledFloor: Bool, parts: [MeshPart]) {
        for part in parts {
            let geometry = (mode == .texture ? part.textured : nil) ?? part.plain
            if part.node.geometry !== geometry {
                part.node.geometry = geometry
            }
            let colored = mode == .texture && part.textured != nil
            for material in part.plain.materials {
                let classId = UInt8(material.name ?? "") ?? 0
                let hidden = (!showCeiling && classId == ceilingClass && mode != .wireframe) || (!showFilledFloor && classId == filledFloorClass)
                material.colorBufferWriteMask = hidden ? [] : .all
                material.writesToDepthBuffer = !hidden
                material.lightingModel = colored ? .constant : .lambert
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
                case .texture:
                    material.fillMode = .fill
                    material.diffuse.contents = colored ? UIColor.white : UIColor(white: 0.82, alpha: 1)
                }
            }
        }
    }

    static func texturedGeometry(plain: SCNGeometry, colors: Data, vertexCount: Int) -> SCNGeometry {
        let colorSource = SCNGeometrySource(data: colors, semantic: .color, vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geometry = SCNGeometry(sources: plain.sources + [colorSource], elements: plain.elements)
        geometry.materials = plain.materials
        return geometry
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
