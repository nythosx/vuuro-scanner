import XCTest
import simd
@testable import VuuroScan

final class MeshHoleFillTests: XCTestCase {
    private func floor(size: Float, step: Float, skip: (SIMD2<Float>) -> Bool = { _ in false }) -> (vertices: [SIMD3<Float>], faces: [UInt32]) {
        let n = Int((size / step).rounded())
        var vertices: [SIMD3<Float>] = []
        for z in 0...n {
            for x in 0...n {
                vertices.append(SIMD3<Float>(Float(x) * step, 0, Float(z) * step))
            }
        }
        var faces: [UInt32] = []
        for z in 0..<n {
            for x in 0..<n {
                let center = SIMD2<Float>((Float(x) + 0.5) * step, (Float(z) + 0.5) * step)
                if skip(center) { continue }
                let a = UInt32(z * (n + 1) + x)
                let b = a + 1
                let c = a + UInt32(n + 1)
                let d = c + 1
                faces.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return (vertices, faces)
    }

    private func centroid(_ mesh: (vertices: [SIMD3<Float>], faces: [UInt32]), _ face: Int) -> SIMD3<Float> {
        (mesh.vertices[Int(mesh.faces[face * 3])] + mesh.vertices[Int(mesh.faces[face * 3 + 1])] + mesh.vertices[Int(mesh.faces[face * 3 + 2])]) / 3
    }

    private func inHole(_ p: SIMD2<Float>) -> Bool {
        p.x > 0.5 && p.x < 1.5 && p.y > 0.5 && p.y < 1.5
    }

    func testOnlyTheDepthMeshInAHoleOfTheMeshIsAdded() {
        let roomPlan = floor(size: 2, step: 0.1, skip: inHole)
        let depth = floor(size: 2, step: 0.04)
        let size = MeshHoleFill.gapM / 2
        let cells = MeshHoleFill.occupiedCells(vertices: roomPlan.vertices, faces: roomPlan.faces, size: size)
        let kept = MeshHoleFill.keptFaces(vertices: depth.vertices, faces: depth.faces, classes: nil, near: cells, size: size)
        XCTAssertGreaterThan(kept.count, MeshHoleFill.minPieceFaces)
        for face in kept {
            let c = centroid(depth, face)
            XCTAssertTrue(inHole(SIMD2<Float>(c.x, c.z)), "kept a face at \(c) outside the hole")
        }
        let middle = kept.contains { simd_distance(centroid(depth, $0), SIMD3<Float>(1, 0, 1)) < 0.05 }
        XCTAssertTrue(middle)
    }

    func testNoHoleMeansNothingIsAdded() {
        let roomPlan = floor(size: 2, step: 0.1)
        let depth = floor(size: 2, step: 0.04)
        let size = MeshHoleFill.gapM / 2
        let cells = MeshHoleFill.occupiedCells(vertices: roomPlan.vertices, faces: roomPlan.faces, size: size)
        XCTAssertTrue(MeshHoleFill.keptFaces(vertices: depth.vertices, faces: depth.faces, classes: nil, near: cells, size: size).isEmpty)
    }

    func testADepthSurfaceBesideTheMeshIsNotAddedAsASecondWall() {
        let roomPlan = floor(size: 2, step: 0.1, skip: inHole)
        let shifted = floor(size: 2, step: 0.04)
        let depth = (vertices: shifted.vertices.map { $0 + SIMD3<Float>(0, 0.1, 0) }, faces: shifted.faces)
        let size = MeshHoleFill.gapM / 2
        let cells = MeshHoleFill.occupiedCells(vertices: roomPlan.vertices, faces: roomPlan.faces, size: size)
        let withoutCheck = MeshHoleFill.keptFaces(vertices: depth.vertices, faces: depth.faces, classes: nil, near: cells, size: size)
        XCTAssertTrue(withoutCheck.contains { !inHole(SIMD2<Float>(centroid(depth, $0).x, centroid(depth, $0).z)) })
        let parallel = MeshHoleFill.orientedSamples(vertices: roomPlan.vertices, faces: roomPlan.faces)
        let kept = MeshHoleFill.keptFaces(vertices: depth.vertices, faces: depth.faces, classes: nil, near: cells, size: size, parallel: parallel)
        for face in kept {
            let c = centroid(depth, face)
            XCTAssertTrue(inHole(SIMD2<Float>(c.x, c.z)), "kept a second floor at \(c) above the mesh")
        }
    }

    func testTheSamePlaneAtTheEdgeOfAHoleIsNotASecondWall() {
        let roomPlan = floor(size: 2, step: 0.1, skip: inHole)
        let parallel = MeshHoleFill.orientedSamples(vertices: roomPlan.vertices, faces: roomPlan.faces)
        XCTAssertFalse(MeshHoleFill.doublesASurface(SIMD3<Float>(0.55, 0.01, 1), normal: SIMD3<Float>(0, 1, 0), samples: parallel))
        XCTAssertTrue(MeshHoleFill.doublesASurface(SIMD3<Float>(0.55, 0.08, 1), normal: SIMD3<Float>(0, 1, 0), samples: parallel))
        XCTAssertFalse(MeshHoleFill.doublesASurface(SIMD3<Float>(0.55, 0.08, 1), normal: SIMD3<Float>(1, 0, 0), samples: parallel))
    }

    func testLargeTrianglesCountAlongTheirWholeSurface() {
        let vertices = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(0, 0, 2)]
        let size = MeshHoleFill.gapM / 2
        let cells = MeshHoleFill.occupiedCells(vertices: vertices, faces: [0, 1, 2], size: size)
        XCTAssertTrue(MeshHoleFill.hasNeighbour(MeshHoleFill.cell(SIMD3<Float>(0.6, 0, 0.6), size: size), in: cells, reach: 2))
    }

    func testSmallLoosePiecesAndFilledFloorAreLeftOut() {
        let depth = floor(size: 0.12, step: 0.04)
        let size = MeshHoleFill.gapM / 2
        XCTAssertTrue(MeshHoleFill.keptFaces(vertices: depth.vertices, faces: depth.faces, classes: nil, near: [], size: size).isEmpty)
        let big = floor(size: 1, step: 0.04)
        let classes = [UInt8](repeating: MeshHoleFill.filledFloorClass, count: big.faces.count / 3)
        XCTAssertTrue(MeshHoleFill.keptFaces(vertices: big.vertices, faces: big.faces, classes: classes, near: [], size: size).isEmpty)
        XCTAssertEqual(MeshHoleFill.keptFaces(vertices: big.vertices, faces: big.faces, classes: nil, near: [], size: size).count, big.faces.count / 3)
    }

    func testThePieceKeepsOnlyTheVerticesItUses() {
        let vertices: [Float] = [0, 0, 0, 1, 0, 0, 0, 0, 1, 5, 5, 5, 1, 0, 1]
        let normals: [Float] = [0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0]
        let piece = MeshHoleFill.piece(vertices: vertices, normals: normals, faces: [0, 1, 2, 1, 4, 2], classes: [2, 3], kept: [1])
        XCTAssertEqual(piece.vertexCount, 3)
        XCTAssertEqual(piece.faces, [0, 1, 2])
        XCTAssertEqual(piece.vertices, [1, 0, 0, 1, 0, 1, 0, 0, 1])
        XCTAssertEqual(piece.normals.count, 9)
        XCTAssertEqual(piece.classes, [3])
    }

    private func writeMesh(_ mesh: (vertices: [SIMD3<Float>], faces: [UInt32]), to folder: URL, source: String?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let flat = mesh.vertices.flatMap { [$0.x, $0.y, $0.z] }
        try flat.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: folder.appendingPathComponent("anchor_0000.vertices"))
        try mesh.faces.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: folder.appendingPathComponent("anchor_0000.faces"))
        var index: [String: Any] = ["anchors": [[
            "file_stem": "anchor_0000",
            "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            "vertex_count": mesh.vertices.count,
            "face_count": mesh.faces.count / 3
        ]]]
        if let source { index["source"] = source }
        try JSONSerialization.data(withJSONObject: index).write(to: folder.appendingPathComponent("anchors.json"))
    }

    func testTheMeshSceneAddsTheDepthMeshOnlyInTheHole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hole-fill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let roomPlan = floor(size: 2, step: 0.1, skip: inHole)
        let depth = floor(size: 2, step: 0.04)
        try writeMesh(roomPlan, to: root.appendingPathComponent("mesh", isDirectory: true), source: nil)
        try writeMesh(depth, to: root.appendingPathComponent(MeshHoleFill.folder, isDirectory: true), source: DepthMeshFusion.identifier)
        let built = try MeshSceneBuilder.build(captureURL: root).get()
        XCTAssertNil(built.holeFillError)
        XCTAssertGreaterThan(built.holeFillFaces, MeshHoleFill.minPieceFaces)
        XCTAssertLessThan(built.holeFillFaces, 2 * 25 * 25)
        XCTAssertEqual(built.looseFacesRemoved, 0)
        XCTAssertEqual(built.parts.count, 2)
        XCTAssertEqual(built.triangles, roomPlan.faces.count / 3 + built.holeFillFaces)

        try writeMesh(roomPlan, to: root.appendingPathComponent("mesh", isDirectory: true), source: DepthMeshFusion.identifier)
        let depthOnly = try MeshSceneBuilder.build(captureURL: root).get()
        XCTAssertEqual(depthOnly.holeFillFaces, 0)
        XCTAssertEqual(depthOnly.parts.count, 1)
    }

    private func raw(_ mesh: (vertices: [SIMD3<Float>], faces: [UInt32]), offset: SIMD3<Float> = .zero) -> MeshRawPart {
        let flat = mesh.vertices.flatMap { [$0.x + offset.x, $0.y + offset.y, $0.z + offset.z] }
        return MeshRawPart(vertices: flat.withUnsafeBufferPointer { Data(buffer: $0) }, vertexCount: mesh.vertices.count, normals: nil, faces: mesh.faces.withUnsafeBufferPointer { Data(buffer: $0) }, faceCount: mesh.faces.count / 3, classes: nil, transform: matrix_identity_float4x4)
    }

    func testASmallPieceAwayFromTheRoomIsLeftOutAndATouchingOneStays() {
        let room = raw(floor(size: 2, step: 0.1))
        let away = raw(floor(size: 0.12, step: 0.04), offset: SIMD3<Float>(4, 1, 4))
        let touching = raw(floor(size: 0.12, step: 0.04), offset: SIMD3<Float>(1, 0.05, 1))
        let parts = [room, away, touching]
        let result = MeshLoosePieces.keptFaces(centroids: parts.map(MeshLoosePieces.worldCentroids))
        XCTAssertEqual(result.kept[0].count, room.faceCount)
        XCTAssertTrue(result.kept[1].isEmpty)
        XCTAssertEqual(result.kept[2].count, touching.faceCount)
        XCTAssertEqual(result.removedPieces, 1)
    }

    func testABigSecondPieceIsKept() {
        let room = raw(floor(size: 2, step: 0.1))
        let other = raw(floor(size: 1, step: 0.1), offset: SIMD3<Float>(5, 0, 0))
        let result = MeshLoosePieces.keptFaces(centroids: [room, other].map(MeshLoosePieces.worldCentroids))
        XCTAssertEqual(result.kept[1].count, other.faceCount)
        XCTAssertEqual(result.removedPieces, 0)
    }

    func testCompactKeepsOnlyTheUsedVertices() {
        let part = raw(floor(size: 0.2, step: 0.1))
        let compacted = MeshLoosePieces.compact(part, kept: [0, 1])
        XCTAssertEqual(compacted.faceCount, 2)
        XCTAssertEqual(compacted.vertexCount, 4)
        XCTAssertNil(compacted.classes)
        XCTAssertEqual(compacted.faces.count, 2 * 12)
    }

    func testTheMeshSceneLeavesOutALoosePiece() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loose-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let room = floor(size: 2, step: 0.1)
        let away = floor(size: 0.12, step: 0.04)
        let merged = (vertices: room.vertices + away.vertices.map { $0 + SIMD3<Float>(4, 1, 4) }, faces: room.faces + away.faces.map { $0 + UInt32(room.vertices.count) })
        try writeMesh(merged, to: root.appendingPathComponent("mesh", isDirectory: true), source: nil)
        let built = try MeshSceneBuilder.build(captureURL: root).get()
        XCTAssertEqual(built.triangles, room.faces.count / 3)
        XCTAssertEqual(built.looseFacesRemoved, away.faces.count / 3)
        XCTAssertEqual(built.loosePiecesRemoved, 1)
        XCTAssertEqual(built.parts.first?.vertexCount, room.vertices.count)
        XCTAssertLessThan(built.boundsMax.x, 2.5)
    }

    func testTheNoteSaysHowManyTrianglesWereFilledOrLeftOutOrWhyNot() {
        XCTAssertNil(MeshViewer.holeFillText(faces: 0, error: nil))
        XCTAssertEqual(MeshViewer.holeFillText(faces: 12_400, error: nil), "12,400 triangles filled in from the LiDAR depth where the mesh had holes.")
        XCTAssertEqual(MeshViewer.holeFillText(faces: 0, error: "bad file"), "Holes in the mesh were not filled from depth: bad file")
        XCTAssertEqual(MeshViewer.holeFillText(faces: 0, error: nil, looseFaces: 1_500, loosePieces: 3), "1,500 triangles in 3 loose pieces away from the room left out.")
        XCTAssertEqual(MeshViewer.holeFillText(faces: 10, error: nil, looseFaces: 18, loosePieces: 1), "10 triangles filled in from the LiDAR depth where the mesh had holes. 18 triangles in 1 loose piece away from the room left out.")
    }
}
