import Foundation
import simd

enum MeshHoleFill {
    static let folder = "mesh_fill"
    static let gapM: Float = 0.06
    static let minPieceFaces = 300
    static let version = "2"
    static let versionName = "fill_version.txt"
    static let parallelReachM: Float = 0.15
    static let parallelCellM: Float = 0.05
    static let parallelDot: Float = 0.8
    static let samePlaneM: Float = 0.03
    static let samplesPerCell = 4
    static let filledFloorClass: UInt8 = 9
    static let maxSampleSteps = 200
    static let maxCoordinateM: Float = 10_000

    struct Sample {
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    struct Piece {
        let vertices: [Float]
        let normals: [Float]
        let faces: [UInt32]
        let classes: [UInt8]

        var vertexCount: Int { vertices.count / 3 }
        var faceCount: Int { faces.count / 3 }
    }

    static func needsRun(captureURL: URL, manifest: LidarCaptureManifest) -> Bool {
        guard manifest.stats.meshSeen else { return false }
        guard manifest.stats.depthFrames + (manifest.stats.depthOnlyFrames ?? 0) > 0 else { return false }
        let fillURL = captureURL.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fillURL.appendingPathComponent(DepthMeshFusion.reportName).path) else { return true }
        guard let data = FileManager.default.contents(atPath: fillURL.appendingPathComponent(versionName).path) else { return true }
        return String(decoding: data, as: UTF8.self) != version
    }

    static func markBuilt(captureURL: URL) throws {
        let url = captureURL.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(versionName)
        try Data(version.utf8).write(to: url, options: .atomic)
    }

    static func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float>? {
        let n = simd_cross(b - a, c - a)
        let length = simd_length(n)
        guard length > 1e-9 else { return nil }
        return n / length
    }

    static func orientedSamples(vertices: [SIMD3<Float>], faces: [UInt32], size: Float = parallelCellM) -> [SIMD3<Int32>: [Sample]] {
        var cells: [SIMD3<Int32>: [Sample]] = [:]
        func add(_ point: SIMD3<Float>, _ normal: SIMD3<Float>) {
            let key = cell(point, size: size)
            var list = cells[key] ?? []
            guard list.count < samplesPerCell else { return }
            if list.contains(where: { abs(simd_dot($0.normal, normal)) > 0.95 && abs(simd_dot($0.normal, point - $0.point)) < samePlaneM }) { return }
            list.append(Sample(point: point, normal: normal))
            cells[key] = list
        }
        var f = 0
        while f + 2 < faces.count {
            let ia = Int(faces[f]), ib = Int(faces[f + 1]), ic = Int(faces[f + 2])
            f += 3
            guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { continue }
            let a = vertices[ia], b = vertices[ib], c = vertices[ic]
            guard usable(a), usable(b), usable(c), let normal = faceNormal(a, b, c) else { continue }
            let longest = max(simd_length(b - a), simd_length(c - a), simd_length(c - b))
            let steps = min(Int((longest / size).rounded(.up)), maxSampleSteps)
            if steps <= 1 {
                add((a + b + c) / 3, normal)
                continue
            }
            let n = Float(steps)
            for i in 0...steps {
                for j in 0...(steps - i) {
                    add(a + (b - a) * (Float(i) / n) + (c - a) * (Float(j) / n), normal)
                }
            }
        }
        return cells
    }

    static func doublesASurface(_ point: SIMD3<Float>, normal: SIMD3<Float>, samples: [SIMD3<Int32>: [Sample]], size: Float = parallelCellM) -> Bool {
        let home = cell(point, size: size)
        let reach = Int32((parallelReachM / size).rounded(.up))
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach {
                    guard let list = samples[home &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                    for sample in list where abs(simd_dot(sample.normal, normal)) > parallelDot {
                        let offset = point - sample.point
                        if simd_length(offset) < parallelReachM && abs(simd_dot(sample.normal, offset)) > samePlaneM {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    static func usable(_ point: SIMD3<Float>) -> Bool {
        abs(point.x) < maxCoordinateM && abs(point.y) < maxCoordinateM && abs(point.z) < maxCoordinateM
    }

    static func cell(_ point: SIMD3<Float>, size: Float) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((point.x / size).rounded(.down)), Int32((point.y / size).rounded(.down)), Int32((point.z / size).rounded(.down)))
    }

    static func occupiedCells(vertices: [SIMD3<Float>], faces: [UInt32], size: Float) -> Set<SIMD3<Int32>> {
        var cells = Set<SIMD3<Int32>>()
        cells.reserveCapacity(vertices.count * 2)
        var f = 0
        while f + 2 < faces.count {
            let ia = Int(faces[f]), ib = Int(faces[f + 1]), ic = Int(faces[f + 2])
            f += 3
            guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { continue }
            let a = vertices[ia], b = vertices[ib], c = vertices[ic]
            guard usable(a), usable(b), usable(c) else { continue }
            cells.insert(cell(a, size: size))
            cells.insert(cell(b, size: size))
            cells.insert(cell(c, size: size))
            let longest = max(simd_length(b - a), simd_length(c - a), simd_length(c - b))
            let steps = min(Int((longest / size).rounded(.up)), maxSampleSteps)
            if steps <= 1 {
                cells.insert(cell((a + b + c) / 3, size: size))
                continue
            }
            let n = Float(steps)
            for i in 0...steps {
                for j in 0...(steps - i) {
                    let point = a + (b - a) * (Float(i) / n) + (c - a) * (Float(j) / n)
                    cells.insert(cell(point, size: size))
                }
            }
        }
        return cells
    }

    static func keptFaces(vertices: [SIMD3<Float>], faces: [UInt32], classes: [UInt8]?, near: Set<SIMD3<Int32>>, size: Float, reach: Int32 = 2, minPiece: Int = minPieceFaces, parallel: [SIMD3<Int32>: [Sample]]? = nil) -> [Int] {
        let faceCount = faces.count / 3
        var candidates: [Int] = []
        for face in 0..<faceCount {
            if let classes, face < classes.count, classes[face] == filledFloorClass { continue }
            let ia = Int(faces[face * 3]), ib = Int(faces[face * 3 + 1]), ic = Int(faces[face * 3 + 2])
            guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { continue }
            guard usable(vertices[ia]), usable(vertices[ib]), usable(vertices[ic]) else { continue }
            let center = (vertices[ia] + vertices[ib] + vertices[ic]) / 3
            if hasNeighbour(cell(center, size: size), in: near, reach: reach) { continue }
            if let parallel {
                guard let normal = faceNormal(vertices[ia], vertices[ib], vertices[ic]) else { continue }
                if doublesASurface(center, normal: normal, samples: parallel) { continue }
            }
            candidates.append(face)
        }
        guard !candidates.isEmpty else { return [] }
        var parent = Array(0..<vertices.count)
        func root(_ v: Int) -> Int {
            var x = v
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for face in candidates {
            let a = root(Int(faces[face * 3]))
            let b = root(Int(faces[face * 3 + 1]))
            parent[b] = a
            let c = root(Int(faces[face * 3 + 2]))
            let top = root(a)
            parent[c] = top
        }
        var sizes: [Int: Int] = [:]
        for face in candidates {
            sizes[root(Int(faces[face * 3])), default: 0] += 1
        }
        return candidates.filter { sizes[root(Int(faces[$0 * 3])), default: 0] >= minPiece }
    }

    static func hasNeighbour(_ home: SIMD3<Int32>, in cells: Set<SIMD3<Int32>>, reach: Int32) -> Bool {
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach where cells.contains(home &+ SIMD3<Int32>(dx, dy, dz)) {
                    return true
                }
            }
        }
        return false
    }

    static func piece(vertices: [Float], normals: [Float]?, faces: [UInt32], classes: [UInt8]?, kept: [Int]) -> Piece {
        var remap: [UInt32: UInt32] = [:]
        var outVertices: [Float] = []
        var outNormals: [Float] = []
        var outFaces: [UInt32] = []
        var outClasses: [UInt8] = []
        outFaces.reserveCapacity(kept.count * 3)
        for face in kept {
            for corner in 0..<3 {
                let old = faces[face * 3 + corner]
                if let mapped = remap[old] {
                    outFaces.append(mapped)
                    continue
                }
                let mapped = UInt32(outVertices.count / 3)
                remap[old] = mapped
                let base = Int(old) * 3
                outVertices.append(contentsOf: vertices[base..<base + 3])
                if let normals, normals.count == vertices.count {
                    outNormals.append(contentsOf: normals[base..<base + 3])
                }
                outFaces.append(mapped)
            }
            outClasses.append(classes.flatMap { face < $0.count ? $0[face] : nil } ?? 0)
        }
        return Piece(vertices: outVertices, normals: outNormals, faces: outFaces, classes: outClasses)
    }

    static func load(captureURL: URL, existing: [(vertices: Data, vertexCount: Int, faces: Data, faceCount: Int, transform: simd_float4x4)]) throws -> Piece? {
        let fillURL = captureURL.appendingPathComponent(folder, isDirectory: true)
        let indexURL = fillURL.appendingPathComponent("anchors.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let index = try JSONDecoder().decode(MeshSceneBuilder.AnchorIndex.self, from: Data(contentsOf: indexURL))
        guard let entry = index.anchors.first, entry.vertexCount > 0, entry.faceCount > 0 else { return nil }
        let vertexData = try Data(contentsOf: fillURL.appendingPathComponent("\(entry.fileStem).vertices"))
        let faceData = try Data(contentsOf: fillURL.appendingPathComponent("\(entry.fileStem).faces"))
        guard vertexData.count == entry.vertexCount * 12, faceData.count == entry.faceCount * 12 else {
            throw PlainError(message: "The depth mesh for filling holes has the wrong file size.")
        }
        var normals: [Float]?
        if entry.normalsFormat != nil {
            let data = try Data(contentsOf: fillURL.appendingPathComponent("\(entry.fileStem).normals"))
            if data.count == vertexData.count { normals = floats(data) }
        }
        var classes: [UInt8]?
        if entry.classesFormat != nil {
            let data = try Data(contentsOf: fillURL.appendingPathComponent("\(entry.fileStem).classes"))
            if data.count == entry.faceCount { classes = [UInt8](data) }
        }
        var worldPoints: [SIMD3<Float>] = []
        var worldFaces: [UInt32] = []
        for part in existing {
            let base = UInt32(worldPoints.count)
            let local = floats(part.vertices)
            for v in 0..<part.vertexCount {
                let p = part.transform * SIMD4<Float>(local[v * 3], local[v * 3 + 1], local[v * 3 + 2], 1)
                worldPoints.append(SIMD3<Float>(p.x, p.y, p.z))
            }
            for f in uint32s(part.faces) {
                worldFaces.append(base + f)
            }
        }
        let size = gapM / 2
        let near = occupiedCells(vertices: worldPoints, faces: worldFaces, size: size)
        let parallel = orientedSamples(vertices: worldPoints, faces: worldFaces)
        let fillFloats = floats(vertexData)
        var fillPoints: [SIMD3<Float>] = []
        fillPoints.reserveCapacity(entry.vertexCount)
        for v in 0..<entry.vertexCount {
            fillPoints.append(SIMD3<Float>(fillFloats[v * 3], fillFloats[v * 3 + 1], fillFloats[v * 3 + 2]))
        }
        let fillFaces = uint32s(faceData)
        let kept = keptFaces(vertices: fillPoints, faces: fillFaces, classes: classes, near: near, size: size, parallel: parallel)
        guard !kept.isEmpty else { return nil }
        return piece(vertices: fillFloats, normals: normals, faces: fillFaces, classes: classes, kept: kept)
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }

    static func uint32s(_ data: Data) -> [UInt32] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
    }
}
