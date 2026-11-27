import Foundation
import simd

struct MeshRawPart {
    var vertices: Data
    var vertexCount: Int
    var normals: Data?
    var faces: Data
    var faceCount: Int
    var classes: Data?
    var transform: simd_float4x4
}

enum MeshLoosePieces {
    static let cellM: Float = 0.1
    static let keepShare: Float = 0.03

    static func worldCentroids(_ part: MeshRawPart) -> [SIMD3<Float>] {
        let vertices = MeshHoleFill.floats(part.vertices)
        let faces = MeshHoleFill.uint32s(part.faces)
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(part.faceCount)
        for face in 0..<part.faceCount {
            var sum = SIMD3<Float>(repeating: 0)
            var valid = true
            for corner in 0..<3 {
                let index = Int(faces[face * 3 + corner])
                guard index < part.vertexCount else {
                    valid = false
                    break
                }
                sum += SIMD3<Float>(vertices[index * 3], vertices[index * 3 + 1], vertices[index * 3 + 2])
            }
            let local = valid ? sum / 3 : SIMD3<Float>(repeating: .infinity)
            let world = part.transform * SIMD4<Float>(local, 1)
            result.append(SIMD3<Float>(world.x, world.y, world.z))
        }
        return result
    }

    static func keptFaces(centroids: [[SIMD3<Float>]], cell size: Float = cellM, share: Float = keepShare) -> (kept: [[Int]], removedPieces: Int) {
        var cellIndex: [SIMD3<Int32>: Int] = [:]
        var faceCells: [[Int]] = []
        var cellFaces: [Int] = []
        for part in centroids {
            var cells: [Int] = []
            cells.reserveCapacity(part.count)
            for point in part {
                guard MeshHoleFill.usable(point) else {
                    cells.append(-1)
                    continue
                }
                let key = MeshHoleFill.cell(point, size: size)
                if let found = cellIndex[key] {
                    cells.append(found)
                    cellFaces[found] += 1
                } else {
                    let added = cellFaces.count
                    cellIndex[key] = added
                    cellFaces.append(1)
                    cells.append(added)
                }
            }
            faceCells.append(cells)
        }
        var parent = Array(0..<cellFaces.count)
        func root(_ v: Int) -> Int {
            var x = v
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for (key, index) in cellIndex {
            for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dz: Int32 in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                        guard let other = cellIndex[key &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        let a = root(index)
                        let b = root(other)
                        if a != b { parent[b] = a }
                    }
                }
            }
        }
        var pieceFaces: [Int: Int] = [:]
        for index in 0..<cellFaces.count {
            pieceFaces[root(index), default: 0] += cellFaces[index]
        }
        let largest = pieceFaces.values.max() ?? 0
        let minimum = max(1, Int((Float(largest) * share).rounded(.up)))
        let removedPieces = pieceFaces.values.filter { $0 < minimum }.count
        let kept = faceCells.map { cells in
            cells.indices.filter { face in
                let cell = cells[face]
                return cell >= 0 && (pieceFaces[root(cell)] ?? 0) >= minimum
            }
        }
        return (kept, removedPieces)
    }

    static func compact(_ part: MeshRawPart, kept: [Int]) -> MeshRawPart {
        if kept.count == part.faceCount { return part }
        let vertices = MeshHoleFill.floats(part.vertices)
        let normals = part.normals.map { MeshHoleFill.floats($0) }
        let faces = MeshHoleFill.uint32s(part.faces)
        let classes = part.classes.map { [UInt8]($0) }
        let piece = MeshHoleFill.piece(vertices: vertices, normals: normals, faces: faces, classes: classes, kept: kept)
        return MeshRawPart(
            vertices: piece.vertices.withUnsafeBufferPointer { Data(buffer: $0) },
            vertexCount: piece.vertexCount,
            normals: piece.normals.isEmpty ? nil : piece.normals.withUnsafeBufferPointer { Data(buffer: $0) },
            faces: piece.faces.withUnsafeBufferPointer { Data(buffer: $0) },
            faceCount: piece.faceCount,
            classes: classes == nil ? nil : Data(piece.classes),
            transform: part.transform
        )
    }
}
