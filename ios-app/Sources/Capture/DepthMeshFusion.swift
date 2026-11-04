import Foundation
import simd

struct LidarDepthMeshReport: Codable, Equatable {
    var vertices: Int
    var faces: Int
    var framesUsed: Int
    var depthOnlyFramesUsed: Int
    var framesFailed: Int
    var voxelM: Double
    var seconds: Double
    var floorSeenM2: Double
    var floorFilledM2: Double
    var footprintM2: Double
    var fillClippedToRoomPlan: Bool
    var floorSeenInsideRoomPlanPercent: Double?
    var roomBoxes: Int
    var roomBoxesMatched: Int
    var roomBoxesUnreadable: Bool
    var openingFaces: Int
    var objectFaces: Int

    enum CodingKeys: String, CodingKey {
        case vertices
        case faces
        case framesUsed = "frames_used"
        case depthOnlyFramesUsed = "depth_only_frames_used"
        case framesFailed = "frames_failed"
        case voxelM = "voxel_m"
        case seconds
        case floorSeenM2 = "floor_seen_m2"
        case floorFilledM2 = "floor_filled_m2"
        case footprintM2 = "footprint_m2"
        case fillClippedToRoomPlan = "fill_clipped_to_roomplan"
        case floorSeenInsideRoomPlanPercent = "floor_seen_inside_roomplan_percent"
        case roomBoxes = "room_boxes"
        case roomBoxesMatched = "room_boxes_matched"
        case roomBoxesUnreadable = "room_boxes_unreadable"
        case openingFaces = "door_window_faces"
        case objectFaces = "object_faces"
    }
}

enum DepthMeshFusion {
    static let identifier = "depth_fusion"
    static let baseVoxel: Float = 0.04
    static let truncationVoxels = 3
    static let maxVoxels = 10_000_000
    static let pixelStride = 2
    static let boundsStride = 8
    static let minDepth: Float = 0.2
    static let maxDepth: Float = 5
    static let maxWeight: Float = 64
    static let surfaceBand: Float = 0.9
    static let padding: Float = 0.2
    static let meshFolder = "mesh"
    static let framesFolder = "frames"
    static let depthFramesFolder = "depth_frames"
    static let reportName = "report.json"
    static let roomBoxesName = "roomplan_boxes.json"
    static let fillCell: Float = 0.05
    static let closingSteps = 3
    static let maxFillCells = 4_000_000
    static let wallClass: UInt8 = 1
    static let floorClass: UInt8 = 2
    static let ceilingClass: UInt8 = 3
    static let tableClass: UInt8 = 4
    static let seatClass: UInt8 = 5
    static let windowClass: UInt8 = 6
    static let doorClass: UInt8 = 7
    static let objectClass: UInt8 = 8
    static let filledFloorClass: UInt8 = 9

    private struct Cloud {
        let points: [SIMD3<Float>]
        let origin: SIMD3<Float>
    }

    private struct Mesh {
        let vertices: [Float]
        let normals: [Float]
        let faces: [UInt32]
        let classes: [UInt8]
        let floorSeenM2: Double
        let floorFilledM2: Double
        let footprintM2: Double
        let fillClipped: Bool
        let floorSeenInsidePercent: Double?
        let boxesMatched: Int
        let openingFaces: Int
        let objectFaces: Int
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

    static func loadReport(captureURL: URL) -> Result<LidarDepthMeshReport?, Error> {
        let url = captureURL.appendingPathComponent(meshFolder, isDirectory: true).appendingPathComponent(reportName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        do {
            return .success(try JSONDecoder().decode(LidarDepthMeshReport.self, from: Data(contentsOf: url)))
        } catch {
            return .failure(error)
        }
    }

    static func run(captureURL: URL, progress: (@Sendable (Double) -> Void)? = nil) -> Result<LidarDepthMeshReport, Error> {
        let started = Date()
        var frames: [MeshFrame] = []
        for folder in [framesFolder, depthFramesFolder] {
            switch MeshFrameIndex.load(captureURL: captureURL, folder: folder) {
            case .success(let loaded):
                frames.append(contentsOf: loaded.frames.filter { $0.depthURL != nil })
            case .failure(let error):
                return .failure(error)
            }
        }
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var usable: [MeshFrame] = []
        var failed = 0
        for frame in frames {
            if Task.isCancelled { return .failure(CancellationError()) }
            do {
                guard let cloud = try cloud(for: frame, stride: boundsStride) else { continue }
                for point in cloud.points {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
                usable.append(frame)
            } catch {
                failed += 1
            }
        }
        guard !usable.isEmpty else {
            return .failure(PlainError(message: "No depth frames could be read, so no mesh could be built."))
        }
        let loadedBoxes = loadBoxes(captureURL: captureURL)
        let mesh: Mesh
        let voxel: Float
        switch fuse(usable, lower: lower, upper: upper, boxes: loadedBoxes.boxes, progress: progress) {
        case .success(let result):
            mesh = result.0
            voxel = result.1
        case .failure(let error):
            return .failure(error)
        }
        let report = LidarDepthMeshReport(
            vertices: mesh.vertices.count / 3,
            faces: mesh.faces.count / 3,
            framesUsed: usable.count,
            depthOnlyFramesUsed: usable.filter { $0.depthURL?.deletingLastPathComponent().lastPathComponent == depthFramesFolder }.count,
            framesFailed: failed,
            voxelM: Double(voxel),
            seconds: Date().timeIntervalSince(started),
            floorSeenM2: mesh.floorSeenM2,
            floorFilledM2: mesh.floorFilledM2,
            footprintM2: mesh.footprintM2,
            fillClippedToRoomPlan: mesh.fillClipped,
            floorSeenInsideRoomPlanPercent: mesh.floorSeenInsidePercent,
            roomBoxes: loadedBoxes.boxes.filter { $0.kind != "floor" }.count,
            roomBoxesMatched: mesh.boxesMatched,
            roomBoxesUnreadable: loadedBoxes.unreadable,
            openingFaces: mesh.openingFaces,
            objectFaces: mesh.objectFaces
        )
        do {
            try write(mesh, report: report, to: captureURL)
            progress?(1)
            return .success(report)
        } catch {
            return .failure(error)
        }
    }

    private static func cloud(for frame: MeshFrame, stride pixelStep: Int) throws -> Cloud? {
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
        points.reserveCapacity(count / (pixelStep * pixelStep))
        for v in Swift.stride(from: 0, to: frame.depthHeight, by: pixelStep) {
            for u in Swift.stride(from: 0, to: frame.depthWidth, by: pixelStep) {
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

    private static func fuse(_ frames: [MeshFrame], lower rawLower: SIMD3<Float>, upper rawUpper: SIMD3<Float>, boxes: [LidarRoomBox], progress: (@Sendable (Double) -> Void)?) -> Result<(Mesh, Float), Error> {
        let lower = rawLower - SIMD3<Float>(repeating: padding)
        let upper = rawUpper + SIMD3<Float>(repeating: padding)
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
        var readError: Error?
        var cancelled = false
        tsdf.withUnsafeMutableBufferPointer { t in
            weight.withUnsafeMutableBufferPointer { w in
                for (number, frame) in frames.enumerated() {
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                    let cloud: Cloud
                    do {
                        guard let loaded = try Self.cloud(for: frame, stride: pixelStride) else { continue }
                        cloud = loaded
                    } catch {
                        readError = error
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
                    progress?(0.8 * Double(number + 1) / Double(frames.count))
                }
            }
        }
        if cancelled { return .failure(CancellationError()) }
        if let readError { return .failure(readError) }
        let mesh = extract(tsdf: tsdf, weight: weight, nx: nx, ny: ny, nz: nz, lower: lower, voxel: voxel, boxes: boxes)
        guard !mesh.faces.isEmpty else {
            return .failure(PlainError(message: "The depth frames did not form any surface."))
        }
        return .success((mesh, voxel))
    }

    private static func dimensions(_ lower: SIMD3<Float>, _ upper: SIMD3<Float>, _ voxel: Float) -> (Int, Int, Int) {
        let size = (upper - lower) / voxel
        return (Int(size.x.rounded(.up)), Int(size.y.rounded(.up)), Int(size.z.rounded(.up)))
    }

    private static func extract(tsdf: [Float], weight: [Float], nx: Int, ny: Int, nz: Int, lower: SIMD3<Float>, voxel: Float, boxes: [LidarRoomBox]) -> Mesh {
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
        return finish(positions: positions, normals: vertexNormals, faces: faces, boxes: boxes)
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

    private struct Box {
        let inverse: simd_float4x4
        let half: SIMD3<Float>
        let label: UInt8
        let isOpening: Bool
    }

    static func loadBoxes(captureURL: URL) -> (boxes: [LidarRoomBox], unreadable: Bool) {
        let url = captureURL.appendingPathComponent(roomBoxesName)
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        do {
            let boxes = try JSONDecoder().decode([LidarRoomBox].self, from: Data(contentsOf: url))
            return (boxes, false)
        } catch {
            return ([], true)
        }
    }

    private static func prepare(_ boxes: [LidarRoomBox]) -> [Box] {
        let prepared: [Box] = boxes.compactMap { box in
            guard box.kind != "floor", box.transform.count == 16, box.dimensions.count == 3,
                  box.transform.allSatisfy({ $0.isFinite }),
                  box.dimensions.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            let values = box.transform
            let transform = simd_float4x4(
                SIMD4<Float>(values[0], values[1], values[2], values[3]),
                SIMD4<Float>(values[4], values[5], values[6], values[7]),
                SIMD4<Float>(values[8], values[9], values[10], values[11]),
                SIMD4<Float>(values[12], values[13], values[14], values[15])
            )
            let isOpening = box.kind == "door" || box.kind == "window"
            let margin = isOpening ? SIMD3<Float>(0.05, 0.05, 0.15) : SIMD3<Float>(repeating: 0.05)
            let label: UInt8
            switch box.kind {
            case "door":
                label = doorClass
            case "window":
                label = windowClass
            default:
                let category = box.category.lowercased()
                if category.contains("table") {
                    label = tableClass
                } else if category.contains("chair") || category.contains("sofa") {
                    label = seatClass
                } else {
                    label = objectClass
                }
            }
            let size = SIMD3<Float>(box.dimensions[0], box.dimensions[1], box.dimensions[2])
            return Box(inverse: transform.inverse, half: size / 2 + margin, label: label, isOpening: isOpening)
        }
        return prepared.filter(\.isOpening) + prepared.filter { !$0.isOpening }
    }

    private static func finish(positions inputPositions: [SIMD3<Float>], normals inputNormals: [SIMD3<Float>], faces inputFaces: [UInt32], boxes roomBoxes: [LidarRoomBox]) -> Mesh {
        var positions = inputPositions
        var normals = inputNormals
        var faces = inputFaces
        let faceCount = faces.count / 3
        var faceNormals: [SIMD3<Float>] = []
        var centroids: [SIMD3<Float>] = []
        faceNormals.reserveCapacity(faceCount)
        centroids.reserveCapacity(faceCount)
        var upHeights: [Float] = []
        for face in 0..<faceCount {
            let a = Int(faces[face * 3])
            let b = Int(faces[face * 3 + 1])
            let c = Int(faces[face * 3 + 2])
            let sum = normals[a] + normals[b] + normals[c]
            let length = simd_length(sum)
            let normal = length > 1e-9 ? sum / length : SIMD3<Float>(0, 1, 0)
            if simd_dot(simd_cross(positions[b] - positions[a], positions[c] - positions[a]), normal) < 0 {
                faces.swapAt(face * 3 + 1, face * 3 + 2)
            }
            let centroid = (positions[a] + positions[b] + positions[c]) / 3
            faceNormals.append(normal)
            centroids.append(centroid)
            if normal.y > 0.8 { upHeights.append(centroid.y) }
        }
        let floorY: Float
        if upHeights.isEmpty {
            floorY = positions.map(\.y).min() ?? 0
        } else {
            upHeights.sort()
            floorY = upHeights[min(upHeights.count - 1, upHeights.count / 20)]
        }
        var classes = [UInt8](repeating: 0, count: faceCount)
        var floorSeen: Double = 0
        for face in 0..<faceCount {
            let normal = faceNormals[face]
            let height = centroids[face].y
            if abs(normal.y) < 0.3 {
                classes[face] = wallClass
            }
            if normal.y > 0.8, height < floorY + 0.15 {
                classes[face] = floorClass
                let a = positions[Int(faces[face * 3])]
                let b = positions[Int(faces[face * 3 + 1])]
                let c = positions[Int(faces[face * 3 + 2])]
                floorSeen += Double(abs(simd_cross(b - a, c - a).y) / 2)
            }
            if normal.y < -0.3, height > floorY + 1.2 {
                classes[face] = ceilingClass
            }
        }
        let boxes = prepare(roomBoxes)
        var openingFaces = 0
        var objectFaces = 0
        var matched = Set<Int>()
        if !boxes.isEmpty {
            for face in 0..<faceCount {
                let current = classes[face]
                let point = SIMD4<Float>(centroids[face], 1)
                for (boxIndex, box) in boxes.enumerated() {
                    if box.isOpening, current == floorClass || current == ceilingClass { continue }
                    if !box.isOpening, current == floorClass { continue }
                    let local = box.inverse * point
                    if abs(local.x) <= box.half.x, abs(local.y) <= box.half.y, abs(local.z) <= box.half.z {
                        classes[face] = box.label
                        matched.insert(boxIndex)
                        if box.isOpening { openingFaces += 1 } else { objectFaces += 1 }
                        break
                    }
                }
            }
        }
        let outlines: [[SIMD2<Float>]] = roomBoxes.compactMap { box in
            guard box.kind == "floor", let corners = box.corners, corners.count >= 3 else { return nil }
            let points = corners.compactMap { corner -> SIMD2<Float>? in
                guard corner.count == 3, corner.allSatisfy({ $0.isFinite }) else { return nil }
                return SIMD2<Float>(corner[0], corner[2])
            }
            return points.count >= 3 ? points : nil
        }
        var floorSeenInsidePercent: Double?
        if !outlines.isEmpty {
            var floorFaces = 0
            var inside = 0
            for face in 0..<faceCount where classes[face] == floorClass {
                floorFaces += 1
                let point = SIMD2<Float>(centroids[face].x, centroids[face].z)
                if outlines.contains(where: { polygonContains($0, point) }) { inside += 1 }
            }
            if floorFaces > 0 { floorSeenInsidePercent = Double(inside) * 100 / Double(floorFaces) }
        }
        let fill = floorFill(centroids: centroids, classes: classes, floorY: floorY, outlines: outlines)
        for cell in fill.cells {
            let base = UInt32(positions.count)
            let x = cell.x
            let z = cell.y
            positions.append(contentsOf: [
                SIMD3<Float>(x, floorY, z),
                SIMD3<Float>(x + fillCell, floorY, z),
                SIMD3<Float>(x + fillCell, floorY, z + fillCell),
                SIMD3<Float>(x, floorY, z + fillCell)
            ])
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
            faces.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            classes.append(contentsOf: [filledFloorClass, filledFloorClass])
        }
        var vertexFloats: [Float] = []
        vertexFloats.reserveCapacity(positions.count * 3)
        for point in positions { vertexFloats.append(contentsOf: [point.x, point.y, point.z]) }
        var normalFloats: [Float] = []
        normalFloats.reserveCapacity(normals.count * 3)
        for normal in normals { normalFloats.append(contentsOf: [normal.x, normal.y, normal.z]) }
        let cellArea = Double(fillCell * fillCell)
        return Mesh(
            vertices: vertexFloats,
            normals: normalFloats,
            faces: faces,
            classes: classes,
            floorSeenM2: floorSeen,
            floorFilledM2: Double(fill.cells.count) * cellArea,
            footprintM2: Double(fill.footprintCells) * cellArea,
            fillClipped: !outlines.isEmpty,
            floorSeenInsidePercent: floorSeenInsidePercent,
            boxesMatched: matched.count,
            openingFaces: openingFaces,
            objectFaces: objectFaces
        )
    }

    static func polygonContains(_ polygon: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossX = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < crossX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func floorFill(centroids: [SIMD3<Float>], classes: [UInt8], floorY: Float, outlines: [[SIMD2<Float>]]) -> (cells: [SIMD2<Float>], footprintCells: Int) {
        let low = floorY - 0.3
        let high = floorY + 2.5
        var minimum = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for point in centroids where point.y >= low && point.y <= high {
            minimum = simd_min(minimum, SIMD2<Float>(point.x, point.z))
            maximum = simd_max(maximum, SIMD2<Float>(point.x, point.z))
        }
        guard minimum.x <= maximum.x, minimum.y <= maximum.y else { return ([], 0) }
        minimum -= SIMD2<Float>(repeating: fillCell * 4)
        maximum += SIMD2<Float>(repeating: fillCell * 4)
        let width = Int(((maximum.x - minimum.x) / fillCell).rounded(.up)) + 1
        let height = Int(((maximum.y - minimum.y) / fillCell).rounded(.up)) + 1
        guard width > 2, height > 2, width * height <= maxFillCells else { return ([], 0) }
        var footprint = [Bool](repeating: false, count: width * height)
        var floor = [Bool](repeating: false, count: width * height)
        for (face, point) in centroids.enumerated() where point.y >= low && point.y <= high {
            let i = min(max(Int((point.x - minimum.x) / fillCell), 0), width - 1)
            let j = min(max(Int((point.z - minimum.y) / fillCell), 0), height - 1)
            footprint[j * width + i] = true
            if classes[face] == floorClass { floor[j * width + i] = true }
        }
        for _ in 0..<closingSteps { footprint = dilate(footprint, width: width, height: height) }
        for _ in 0..<closingSteps { footprint = erode(footprint, width: width, height: height) }
        footprint = fillHoles(footprint, width: width, height: height)
        floor = dilate(floor, width: width, height: height)
        var cells: [SIMD2<Float>] = []
        var footprintCells = 0
        for j in 0..<height {
            for i in 0..<width where footprint[j * width + i] {
                footprintCells += 1
                if !floor[j * width + i] {
                    let corner = SIMD2<Float>(minimum.x + Float(i) * fillCell, minimum.y + Float(j) * fillCell)
                    let center = corner + SIMD2<Float>(repeating: fillCell / 2)
                    if outlines.isEmpty || outlines.contains(where: { polygonContains($0, center) }) {
                        cells.append(corner)
                    }
                }
            }
        }
        return (cells, footprintCells)
    }

    private static func dilate(_ grid: [Bool], width: Int, height: Int) -> [Bool] {
        var result = grid
        for j in 0..<height {
            for i in 0..<width where !grid[j * width + i] {
                if (i > 0 && grid[j * width + i - 1]) || (i < width - 1 && grid[j * width + i + 1])
                    || (j > 0 && grid[(j - 1) * width + i]) || (j < height - 1 && grid[(j + 1) * width + i]) {
                    result[j * width + i] = true
                }
            }
        }
        return result
    }

    private static func erode(_ grid: [Bool], width: Int, height: Int) -> [Bool] {
        var result = grid
        for j in 0..<height {
            for i in 0..<width where grid[j * width + i] {
                if i == 0 || i == width - 1 || j == 0 || j == height - 1
                    || !grid[j * width + i - 1] || !grid[j * width + i + 1]
                    || !grid[(j - 1) * width + i] || !grid[(j + 1) * width + i] {
                    result[j * width + i] = false
                }
            }
        }
        return result
    }

    private static func fillHoles(_ grid: [Bool], width: Int, height: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for i in 0..<width {
            stack.append(i)
            stack.append((height - 1) * width + i)
        }
        for j in 0..<height {
            stack.append(j * width)
            stack.append(j * width + width - 1)
        }
        while let index = stack.popLast() {
            if outside[index] || grid[index] { continue }
            outside[index] = true
            let i = index % width
            let j = index / width
            if i > 0 { stack.append(index - 1) }
            if i < width - 1 { stack.append(index + 1) }
            if j > 0 { stack.append(index - width) }
            if j < height - 1 { stack.append(index + width) }
        }
        return outside.map { !$0 }
    }

    private static func write(_ mesh: Mesh, report: LidarDepthMeshReport, to captureURL: URL) throws {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: staging.appendingPathComponent(reportName))
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)
    }
}
