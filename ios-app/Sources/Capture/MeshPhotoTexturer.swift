import CoreGraphics
import Foundation
import ImageIO
import simd

enum MeshPhotoTexturer {
    struct PartInput {
        let vertices: Data
        let vertexCount: Int
        let faces: Data
        let faceCount: Int
        let classes: Data?
        let transform: simd_float4x4
    }

    struct Group: Equatable {
        let slot: Int
        let classId: UInt8
        let start: Int
        let count: Int
    }

    struct PartOutput {
        let positions: Data
        let uvs: Data
        let vertexCount: Int
        let groups: [Group]
    }

    struct Output {
        let parts: [PartOutput]
        let images: [CGImage]
        let facesInPhoto: Int
        let totalFaces: Int
        let photosUsed: Int
    }

    struct Camera {
        let view: simd_float4x4
        let position: SIMD3<Float>
        let width: Float
        let height: Float
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let depth: [UInt16]?
        let depthWidth: Int
        let depthHeight: Int
    }

    static let maxCandidates = 200
    static let maxTextures = 24
    static let textureSize = 1440
    static let minDistance: Float = 0.1
    static let maxDistance: Float = 6
    static let minFacing: Float = 0.2
    static let hiddenClasses: Set<UInt8> = [3, 9]

    static func texture(parts: [PartInput], frames: [MeshFrame]) -> Result<Output, Error> {
        let usable = frames.filter { $0.imageURL != nil }
        guard !usable.isEmpty else {
            return .failure(PlainError(message: "This capture has no frame photos."))
        }
        let step = max(1, (usable.count + maxCandidates - 1) / maxCandidates)
        let candidates = stride(from: 0, to: usable.count, by: step).map { usable[$0] }
        let cameras = candidates.map(camera)
        let world = parts.map(worldVertices)
        let totalFaces = parts.reduce(0) { $0 + $1.faceCount }
        guard totalFaces > 0 else {
            return .failure(PlainError(message: "The mesh has no triangles to texture."))
        }

        var wins = [Int](repeating: 0, count: cameras.count)
        for (part, input) in parts.enumerated() {
            if Task.isCancelled { return .failure(CancellationError()) }
            forEachFace(input, world: world[part]) { _, a, b, c in
                if let best = bestCamera(a, b, c, cameras: cameras, allowed: nil) {
                    wins[best] += 1
                }
            }
        }
        let kept = keptCameras(wins: wins, limit: maxTextures)
        guard !kept.isEmpty else {
            return .failure(PlainError(message: "No triangle of the mesh is seen clearly in a photo."))
        }
        let slotOf = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        let allowed = Set(kept)

        var outputs: [PartOutput] = []
        var inPhoto = 0
        for (part, input) in parts.enumerated() {
            if Task.isCancelled { return .failure(CancellationError()) }
            var positionsBy: [Int: [Float]] = [:]
            var uvsBy: [Int: [Float]] = [:]
            let local = localFloats(input)
            forEachFace(input, world: world[part]) { face, a, b, c in
                let classId = faceClass(input, face)
                var slot = -1
                var uv: [Float] = [0, 0, 0, 0, 0, 0]
                if let best = bestCamera(a, b, c, cameras: cameras, allowed: allowed), let mapped = slotOf[best] {
                    let camera = cameras[best]
                    var coords: [Float] = []
                    for point in [a, b, c] {
                        if let pixel = project(point, camera) {
                            coords.append(pixel.x / camera.width)
                            coords.append(pixel.y / camera.height)
                        }
                    }
                    if coords.count == 6 {
                        slot = mapped
                        uv = coords
                        inPhoto += 1
                    }
                }
                let key = (slot + 1) * 256 + Int(classId)
                for corner in 0..<3 {
                    let index = Int(faceIndex(input, face, corner))
                    positionsBy[key, default: []].append(contentsOf: local[(index * 3)..<(index * 3 + 3)])
                }
                uvsBy[key, default: []].append(contentsOf: uv)
            }
            var positions: [Float] = []
            var uvs: [Float] = []
            var groups: [Group] = []
            for key in positionsBy.keys.sorted() {
                guard let bucketPositions = positionsBy[key], let bucketUVs = uvsBy[key] else { continue }
                let start = positions.count / 3
                positions.append(contentsOf: bucketPositions)
                uvs.append(contentsOf: bucketUVs)
                groups.append(Group(slot: key / 256 - 1, classId: UInt8(key % 256), start: start, count: bucketPositions.count / 3))
            }
            outputs.append(PartOutput(
                positions: positions.withUnsafeBufferPointer { Data(buffer: $0) },
                uvs: uvs.withUnsafeBufferPointer { Data(buffer: $0) },
                vertexCount: positions.count / 3,
                groups: groups
            ))
        }

        var images: [CGImage] = []
        for index in kept {
            if Task.isCancelled { return .failure(CancellationError()) }
            guard let url = candidates[index].imageURL, let image = loadImage(url) else {
                return .failure(PlainError(message: "A frame photo could not be opened for the texture."))
            }
            images.append(image)
        }
        return .success(Output(parts: outputs, images: images, facesInPhoto: inPhoto, totalFaces: totalFaces, photosUsed: kept.count))
    }

    static func keptCameras(wins: [Int], limit: Int) -> [Int] {
        wins.indices
            .filter { wins[$0] > 0 }
            .sorted { wins[$0] != wins[$1] ? wins[$0] > wins[$1] : $0 < $1 }
            .prefix(limit)
            .sorted()
    }

    static func project(_ point: SIMD3<Float>, _ camera: Camera) -> SIMD2<Float>? {
        let local = camera.view * SIMD4<Float>(point, 1)
        let distance = -local.z
        guard distance >= minDistance, distance <= maxDistance else { return nil }
        let u = camera.fx * local.x / distance + camera.cx
        let v = -camera.fy * local.y / distance + camera.cy
        guard u >= 0, v >= 0, u < camera.width, v < camera.height else { return nil }
        return SIMD2<Float>(u, v)
    }

    static func score(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ camera: Camera) -> Float? {
        let centroid = (a + b + c) / 3
        guard let center = project(centroid, camera) else { return nil }
        guard project(a, camera) != nil, project(b, camera) != nil, project(c, camera) != nil else { return nil }
        let toCamera = camera.position - centroid
        let distance = simd_length(toCamera)
        guard distance > 0 else { return nil }
        let cross = simd_cross(b - a, c - a)
        let area = simd_length(cross)
        let facing = area > 0 ? abs(simd_dot(cross / area, toCamera / distance)) : 1
        guard facing >= minFacing else { return nil }
        if let depth = camera.depth, camera.depthWidth > 0, camera.depthHeight > 0 {
            let du = min(Int(center.x * Float(camera.depthWidth) / camera.width), camera.depthWidth - 1)
            let dv = min(Int(center.y * Float(camera.depthHeight) / camera.height), camera.depthHeight - 1)
            let millimeters = depth[dv * camera.depthWidth + du]
            if millimeters > 0 {
                let along = -(camera.view * SIMD4<Float>(centroid, 1)).z
                let measured = Float(millimeters) / 1000
                if abs(measured - along) > 0.08 + 0.03 * along { return nil }
            }
        }
        let halfWidth = camera.width / 2
        let halfHeight = camera.height / 2
        let offCenter = max(abs(center.x - halfWidth) / halfWidth, abs(center.y - halfHeight) / halfHeight)
        return distance * (1 + offCenter) / facing
    }

    private static func bestCamera(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, cameras: [Camera], allowed: Set<Int>?) -> Int? {
        var best: Int?
        var bestScore = Float.greatestFiniteMagnitude
        for index in cameras.indices {
            if let allowed, !allowed.contains(index) { continue }
            guard let value = score(a, b, c, cameras[index]), value < bestScore else { continue }
            bestScore = value
            best = index
        }
        return best
    }

    static func camera(_ frame: MeshFrame) -> Camera {
        let depth = loadDepth(frame)
        let transform = frame.cameraTransform
        return Camera(
            view: transform.inverse,
            position: SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
            width: Float(frame.imageWidth),
            height: Float(frame.imageHeight),
            fx: frame.fx,
            fy: frame.fy,
            cx: frame.cx,
            cy: frame.cy,
            depth: depth,
            depthWidth: depth == nil ? 0 : frame.depthWidth,
            depthHeight: depth == nil ? 0 : frame.depthHeight
        )
    }

    private static func forEachFace(_ input: PartInput, world: [SIMD3<Float>], _ body: (Int, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        guard input.faces.count >= input.faceCount * 12 else { return }
        for face in 0..<input.faceCount {
            let i0 = Int(faceIndex(input, face, 0))
            let i1 = Int(faceIndex(input, face, 1))
            let i2 = Int(faceIndex(input, face, 2))
            guard i0 < world.count, i1 < world.count, i2 < world.count else { continue }
            body(face, world[i0], world[i1], world[i2])
        }
    }

    private static func faceIndex(_ input: PartInput, _ face: Int, _ corner: Int) -> UInt32 {
        let offset = (face * 3 + corner) * 4
        return input.faces.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func faceClass(_ input: PartInput, _ face: Int) -> UInt8 {
        guard let classes = input.classes, face < classes.count else { return 0 }
        let value = classes[classes.startIndex + face]
        return hiddenClasses.contains(value) ? value : 0
    }

    private static func localFloats(_ input: PartInput) -> [Float] {
        guard input.vertexCount > 0, input.vertices.count >= input.vertexCount * 12 else { return [] }
        var floats = [Float](repeating: 0, count: input.vertexCount * 3)
        _ = floats.withUnsafeMutableBytes { input.vertices.copyBytes(to: $0) }
        return floats
    }

    private static func worldVertices(_ input: PartInput) -> [SIMD3<Float>] {
        let floats = localFloats(input)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(input.vertexCount)
        for i in 0..<(floats.count / 3) {
            let world = input.transform * SIMD4<Float>(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2], 1)
            points.append(SIMD3<Float>(world.x, world.y, world.z))
        }
        return points
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: textureSize,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func loadDepth(_ frame: MeshFrame) -> [UInt16]? {
        guard let url = frame.depthURL, frame.depthWidth > 0, frame.depthHeight > 0 else { return nil }
        let count = frame.depthWidth * frame.depthHeight
        guard let data = FileManager.default.contents(atPath: url.path), data.count >= count * 2 else { return nil }
        var values = [UInt16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}
