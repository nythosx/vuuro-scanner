import Foundation
import simd

struct LidarDepthMeshReport: Codable, Equatable {
    var vertices: Int
    var faces: Int
    var framesUsed: Int
    var framesFailed: Int
    var voxelM: Double
    var seconds: Double
    var floorM2: Double

    enum CodingKeys: String, CodingKey {
        case vertices
        case faces
        case framesUsed = "frames_used"
        case framesFailed = "frames_failed"
        case voxelM = "voxel_m"
        case seconds
        case floorM2 = "floor_m2"
    }
}

enum DepthMeshFusion {
    static let identifier = "depth_fusion"
    static let baseVoxel: Float = 0.04
    static let truncationVoxels = 3
    static let maxVoxels = 6_000_000
    static let pixelStride = 2
    static let minDepth: Float = 0.2
    static let maxDepth: Float = 5
    static let maxWeight: Float = 64
    static let surfaceBand: Float = 0.9
    static let padding: Float = 0.2
    static let meshFolder = "mesh"

    private struct Cloud {
        let points: [SIMD3<Float>]
        let origin: SIMD3<Float>
    }

    private struct Mesh {
        let vertices: [Float]
        let normals: [Float]
        let faces: [UInt32]
        let classes: [UInt8]
        let floorM2: Double
    }

    private static let cornerOffsets: [SIMD3<Float>] = (0..<8).map {
        SIMD3<Float>(Float($0 >> 2), Float(($0 >> 1) & 1), Float($0 & 1))
    }

    private static let cornerEdges: [(Int, Int)] = {
        var edges: [(Int, Int)] = []
        for corner in 0..<8 {
            for bit in [4, 2, 1] where corner & bit == 0 {
                edges.append((corner, corner | bit))
            }
        }
        return edges
    }()

    static func run(captureURL: URL) -> Result<LidarCaptureManifest, Error> {
        let started = Date()
        let frames: [MeshFrame]
        switch MeshFrameIndex.load(captureURL: captureURL) {
        case .success(let loaded):
            frames = loaded.frames
        case .failure(let error):
            return .failure(error)
        }
        var clouds: [Cloud] = []
        var failed = 0
        for frame in frames {
            if Task.isCancelled { return .failure(CancellationError()) }
            do {
                if let cloud = try cloud(for: frame) {
                    clouds.append(cloud)
                }
            } catch {
                failed += 1
            }
        }
        guard !clouds.isEmpty else {
            return .failure(PlainError(message: "No depth frames could be read, so no mesh could be built."))
        }
        let mesh: Mesh
        let voxel: Float
        switch fuse(clouds) {
        case .success(let result):
            mesh = result.0
            voxel = result.1
        case .failure(let error):
            return .failure(error)
        }
        do {
            try write(mesh, to: captureURL)
            var manifest = try LidarCaptureLibrary.manifest(at: captureURL)
            manifest.depthMesh = LidarDepthMeshReport(
                vertices: mesh.vertices.count / 3,
                faces: mesh.faces.count / 3,
                framesUsed: clouds.count,
                framesFailed: failed,
                voxelM: Double(voxel),
                seconds: Date().timeIntervalSince(started),
                floorM2: mesh.floorM2
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: captureURL.appendingPathComponent(LidarCaptureLibrary.manifestName), options: .atomic)
            return .success(manifest)
        } catch {
            return .failure(error)
        }
    }

    private static func cloud(for frame: MeshFrame) throws -> Cloud? {
        guard let depthURL = frame.depthURL, frame.depthWidth > 0, frame.depthHeight > 0 else { return nil }
        let count = frame.depthWidth * frame.depthHeight
        let depthData = try Data(contentsOf: depthURL)
        guard depthData.count >= count * 2 else {
            throw PlainError(message: "Depth file \(depthURL.lastPathComponent) is too short.")
        }
        var depth = [UInt16](repeating: 0, count: count)
        _ = depth.withUnsafeMutableBytes { depthData.copyBytes(to: $0) }
        var confidence: [UInt8]?
        if let confidenceURL = frame.confidenceURL {
            let data = try Data(contentsOf: confidenceURL)
            if data.count >= count {
                confidence = [UInt8](data.prefix(count))
            }
        }
        let scaleX = Float(frame.depthWidth) / Float(frame.imageWidth)
        let scaleY = Float(frame.depthHeight) / Float(frame.imageHeight)
        let fx = frame.fx * scaleX
        let fy = frame.fy * scaleY
        let cx = frame.cx * scaleX
        let cy = frame.cy * scaleY
        let transform = frame.cameraTransform
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count / (pixelStride * pixelStride))
        for v in stride(from: 0, to: frame.depthHeight, by: pixelStride) {
            for u in stride(from: 0, to: frame.depthWidth, by: pixelStride) {
                let index = v * frame.depthWidth + u
                if let confidence, confidence[index] < 1 { continue }
                let d = Float(depth[index]) / 1000
                if d <= minDepth || d >= maxDepth { continue }
                let x = (Float(u) + 0.5 - cx) * d / fx
                let y = -(Float(v) + 0.5 - cy) * d / fy
                let world = transform * SIMD4<Float>(x, y, -d, 1)
                points.append(SIMD3<Float>(world.x, world.y, world.z))
            }
        }
        guard !points.isEmpty else { return nil }
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        return Cloud(points: points, origin: origin)
    }

    private static func fuse(_ clouds: [Cloud]) -> Result<(Mesh, Float), Error> {
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for cloud in clouds {
            for index in stride(from: 0, to: cloud.points.count, by: 4) {
                lower = simd_min(lower, cloud.points[index])
                upper = simd_max(upper, cloud.points[index])
            }
        }
        lower -= SIMD3<Float>(repeating: padding)
        upper += SIMD3<Float>(repeating: padding)
        var voxel = baseVoxel
        var dims = dimensions(lower, upper, voxel)
        while dims.0 * dims.1 * dims.2 > maxVoxels {
            voxel *= 1.1
            dims = dimensions(lower, upper, voxel)
        }
        let (nx, ny, nz) = dims
        guard nx > 2, ny > 2, nz > 2 else {
            return .failure(PlainError(message: "The depth frames cover too small an area to build a mesh."))
        }
        let count = nx * ny * nz
        var tsdf = [Float](repeating: 1, count: count)
        var weight = [Float](repeating: 0, count: count)
        let truncation = Float(truncationVoxels) * voxel
        var cancelled = false
        tsdf.withUnsafeMutableBufferPointer { t in
            weight.withUnsafeMutableBufferPointer { w in
                for cloud in clouds {
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                    for point in cloud.points {
                        let ray = simd_normalize(point - cloud.origin)
                        for step in -truncationVoxels...truncationVoxels {
                            let offset = Float(step) * voxel
                            let grid = (point - ray * offset - lower) / voxel
                            let ix = Int(grid.x.rounded(.down))
                            let iy = Int(grid.y.rounded(.down))
                            let iz = Int(grid.z.rounded(.down))
                            if ix < 0 || iy < 0 || iz < 0 || ix >= nx || iy >= ny || iz >= nz { continue }
                            let index = (ix * ny + iy) * nz + iz
                            let current = w[index]
                            t[index] = (t[index] * current + offset / truncation) / (current + 1)
                            w[index] = min(current + 1, maxWeight)
                        }
                    }
                }
            }
        }
        if cancelled { return .failure(CancellationError()) }
        let mesh = extract(tsdf: tsdf, weight: weight, nx: nx, ny: ny, nz: nz, lower: lower, voxel: voxel)
        guard !mesh.faces.isEmpty else {
            return .failure(PlainError(message: "The depth frames did not form any surface."))
        }
        return .success((mesh, voxel))
    }

    private static func dimensions(_ lower: SIMD3<Float>, _ upper: SIMD3<Float>, _ voxel: Float) -> (Int, Int, Int) {
        let size = (upper - lower) / voxel
        return (Int(size.x.rounded(.up)), Int(size.y.rounded(.up)), Int(size.z.rounded(.up)))
    }

    private static func extract(tsdf: [Float], weight: [Float], nx: Int, ny: Int, nz: Int, lower: SIMD3<Float>, voxel: Float) -> Mesh {
        let cx = nx - 1
        let cy = ny - 1
        let cz = nz - 1
        var cellVertex = [Int32](repeating: -1, count: cx * cy * cz)
        var positions: [SIMD3<Float>] = []
        var vertexNormals: [SIMD3<Float>] = []
        let cornerLinear = (0..<8).map { (($0 >> 2) * ny + (($0 >> 1) & 1)) * nz + ($0 & 1) }
        var faces: [UInt32] = []
        tsdf.withUnsafeBufferPointer { t in
            weight.withUnsafeBufferPointer { w in
                cellVertex.withUnsafeMutableBufferPointer { cells in
                    for i in 0..<cx {
                        for j in 0..<cy {
                            for k in 0..<cz {
                                let base = (i * ny + j) * nz + k
                                var values = SIMD8<Float>()
                                var usable = true
                                var negatives = 0
                                for corner in 0..<8 {
                                    let index = base + cornerLinear[corner]
                                    let value = t[index]
                                    if w[index] <= 0 || abs(value) >= surfaceBand {
                                        usable = false
                                        break
                                    }
                                    values[corner] = value
                                    if value < 0 { negatives += 1 }
                                }
                                if !usable || negatives == 0 || negatives == 8 { continue }
                                var sum = SIMD3<Float>(repeating: 0)
                                var crossings: Float = 0
                                for (a, b) in cornerEdges {
                                    let va = values[a]
                                    let vb = values[b]
                                    if (va < 0) != (vb < 0) {
                                        let fraction = va / (va - vb)
                                        sum += cornerOffsets[a] + (cornerOffsets[b] - cornerOffsets[a]) * fraction
                                        crossings += 1
                                    }
                                }
                                let local = sum / max(crossings, 1)
                                positions.append(lower + (SIMD3<Float>(Float(i), Float(j), Float(k)) + local) * voxel)
                                let gradient = cellGradient(values)
                                let length = simd_length(gradient)
                                vertexNormals.append(length > 1e-9 ? gradient / length : SIMD3<Float>(0, 1, 0))
                                cells[(i * cy + j) * cz + k] = Int32(positions.count - 1)
                            }
                        }
                    }
                }
            }
        }
        cellVertex.withUnsafeBufferPointer { cells in
            tsdf.withUnsafeBufferPointer { t in
                weight.withUnsafeBufferPointer { w in
                    func cell(_ i: Int, _ j: Int, _ k: Int) -> Int32 {
                        if i < 0 || j < 0 || k < 0 || i >= cx || j >= cy || k >= cz { return -1 }
                        return cells[(i * cy + j) * cz + k]
                    }
                    for i in 0..<nx {
                        for j in 0..<ny {
                            for k in 0..<nz {
                                let index = (i * ny + j) * nz + k
                                let a = t[index]
                                if w[index] <= 0 || abs(a) >= surfaceBand { continue }
                                for axis in 0..<3 {
                                    let ni = axis == 0 ? i + 1 : i
                                    let nj = axis == 1 ? j + 1 : j
                                    let nk = axis == 2 ? k + 1 : k
                                    if ni >= nx || nj >= ny || nk >= nz { continue }
                                    let neighbor = (ni * ny + nj) * nz + nk
                                    let b = t[neighbor]
                                    if w[neighbor] <= 0 || abs(b) >= surfaceBand || (a < 0) == (b < 0) { continue }
                                    var quad: [Int32] = []
                                    for (d0, d1) in [(0, 0), (-1, 0), (-1, -1), (0, -1)] {
                                        switch axis {
                                        case 0: quad.append(cell(i, j + d0, k + d1))
                                        case 1: quad.append(cell(i + d0, j, k + d1))
                                        default: quad.append(cell(i + d0, j + d1, k))
                                        }
                                    }
                                    if quad.contains(where: { $0 < 0 }) { continue }
                                    faces.append(contentsOf: [quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]].map { UInt32($0) })
                                }
                            }
                        }
                    }
                }
            }
        }
        return finish(positions: positions, normals: vertexNormals, faces: faces)
    }

    private static func cellGradient(_ v: SIMD8<Float>) -> SIMD3<Float> {
        let highX: Float = v[4] + v[5] + v[6] + v[7]
        let lowX: Float = v[0] + v[1] + v[2] + v[3]
        let highY: Float = v[2] + v[3] + v[6] + v[7]
        let lowY: Float = v[0] + v[1] + v[4] + v[5]
        let highZ: Float = v[1] + v[3] + v[5] + v[7]
        let lowZ: Float = v[0] + v[2] + v[4] + v[6]
        return SIMD3<Float>(highX - lowX, highY - lowY, highZ - lowZ)
    }

    private static func finish(positions: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [UInt32]) -> Mesh {
        let faceCount = faces.count / 3
        var faceNormals: [SIMD3<Float>] = []
        var faceHeights: [Float] = []
        faceNormals.reserveCapacity(faceCount)
        faceHeights.reserveCapacity(faceCount)
        var upHeights: [Float] = []
        for face in 0..<faceCount {
            let a = Int(faces[face * 3])
            let b = Int(faces[face * 3 + 1])
            let c = Int(faces[face * 3 + 2])
            let sum = normals[a] + normals[b] + normals[c]
            let length = simd_length(sum)
            let normal = length > 1e-9 ? sum / length : SIMD3<Float>(0, 1, 0)
            let height = (positions[a].y + positions[b].y + positions[c].y) / 3
            faceNormals.append(normal)
            faceHeights.append(height)
            if normal.y > 0.8 { upHeights.append(height) }
        }
        let floorY: Float
        if upHeights.isEmpty {
            floorY = positions.map(\.y).min() ?? 0
        } else {
            upHeights.sort()
            floorY = upHeights[min(upHeights.count - 1, upHeights.count / 20)]
        }
        var classes = [UInt8](repeating: 0, count: faceCount)
        var floorArea: Double = 0
        for face in 0..<faceCount {
            let normal = faceNormals[face]
            let height = faceHeights[face]
            if abs(normal.y) < 0.3 {
                classes[face] = 1
            }
            if normal.y > 0.8, height < floorY + 0.15 {
                classes[face] = 2
                let a = positions[Int(faces[face * 3])]
                let b = positions[Int(faces[face * 3 + 1])]
                let c = positions[Int(faces[face * 3 + 2])]
                floorArea += Double(abs(simd_cross(b - a, c - a).y) / 2)
            }
            if normal.y < -0.3, height > floorY + 1.2 {
                classes[face] = 3
            }
        }
        var vertexFloats: [Float] = []
        vertexFloats.reserveCapacity(positions.count * 3)
        for point in positions { vertexFloats.append(contentsOf: [point.x, point.y, point.z]) }
        var normalFloats: [Float] = []
        normalFloats.reserveCapacity(normals.count * 3)
        for normal in normals { normalFloats.append(contentsOf: [normal.x, normal.y, normal.z]) }
        return Mesh(vertices: vertexFloats, normals: normalFloats, faces: faces, classes: classes, floorM2: floorArea)
    }

    private static func write(_ mesh: Mesh, to captureURL: URL) throws {
        let fileManager = FileManager.default
        let target = captureURL.appendingPathComponent(meshFolder, isDirectory: true)
        let staging = captureURL.appendingPathComponent(meshFolder + ".tmp", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let stem = "anchor_0000"
        try mesh.vertices.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: staging.appendingPathComponent("\(stem).vertices"))
        try mesh.faces.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: staging.appendingPathComponent("\(stem).faces"))
        try mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: staging.appendingPathComponent("\(stem).normals"))
        try Data(mesh.classes).write(to: staging.appendingPathComponent("\(stem).classes"))
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let entry: [String: Any] = [
            "identifier": identifier,
            "file_stem": stem,
            "transform": identity,
            "vertex_count": mesh.vertices.count / 3,
            "face_count": mesh.faces.count / 3,
            "vertices_format": "float32_le_xyz",
            "faces_format": "uint32_le_triangles",
            "normals_format": "float32_le_xyz",
            "classes_format": "uint8_per_face_armeshclassification"
        ]
        let json = try JSONSerialization.data(withJSONObject: ["anchors": [entry], "source": identifier], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: staging.appendingPathComponent("anchors.json"))
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)
    }
}
