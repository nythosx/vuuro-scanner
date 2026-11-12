import CoreGraphics
import CoreImage
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
        let images: [CGImage?]
        let photosUnreadable: Int
        let facesInPhoto: Int
        let totalFaces: Int
        let photosUsed: Int
        let gains: [Float]
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

    final class Monitor: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        private var stopped = false
        private var done = 0
        private var stageStartedAt = ProcessInfo.processInfo.systemUptime
        private var finished: [MeshPhotoBuildLog.Stage] = []

        var stages: [MeshPhotoBuildLog.Stage] {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func endStage(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            finished.append(MeshPhotoBuildLog.Stage(name: name, seconds: now - stageStartedAt))
            stageStartedAt = now
            lock.unlock()
        }

        var fraction: Double {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func cancel() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        func report(_ fraction: Double) {
            lock.lock()
            value = max(value, min(max(fraction, 0), 1))
            lock.unlock()
        }

        func beginStage() {
            lock.lock()
            done = 0
            lock.unlock()
        }

        func tick(of total: Int, from start: Double, to end: Double) {
            lock.lock()
            done += 1
            let next = start + (end - start) * Double(done) / Double(max(total, 1))
            value = max(value, min(next, 1))
            lock.unlock()
        }
    }

    static let maxCandidates = 200
    static let maxTextures = 40
    static let textureSize = 1152
    static let gainSampleSize = 160
    static let maxGain: Float = 1.6
    static let chunkFaces = 4096
    static let minDistance: Float = 0.1
    static let maxDistance: Float = 6
    static let minFacing: Float = 0.2
    static let hiddenClasses: Set<UInt8> = [3, 9]
    static let invalidPoint = SIMD3<Float>(repeating: 1e9)

    static func texture(parts: [PartInput], frames: [MeshFrame], monitor: Monitor = Monitor()) -> Result<Output, Error> {
        func stopped() -> Bool { monitor.isCancelled || Task.isCancelled }
        let usable = frames.filter { $0.imageURL != nil }
        guard !usable.isEmpty else {
            return .failure(PlainError(message: "This capture has no frame photos."))
        }
        let step = max(1, (usable.count + maxCandidates - 1) / maxCandidates)
        let candidates = stride(from: 0, to: usable.count, by: step).map { usable[$0] }
        var cameras: [Camera] = []
        cameras.reserveCapacity(candidates.count)
        monitor.beginStage()
        for frame in candidates {
            if stopped() { return .failure(CancellationError()) }
            cameras.append(camera(frame))
            monitor.tick(of: candidates.count, from: 0, to: 0.15)
        }
        monitor.endStage("photo depth")
        let world = parts.map(worldVertices)
        let totalFaces = parts.reduce(0) { $0 + $1.faceCount }
        guard totalFaces > 0 else {
            return .failure(PlainError(message: "The mesh has no triangles to texture."))
        }

        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(totalFaces * 3)
        var partStart: [Int] = []
        for (part, input) in parts.enumerated() {
            partStart.append(corners.count / 3)
            forEachFace(input, world: world[part]) { _, a, b, c in
                corners.append(a)
                corners.append(b)
                corners.append(c)
            }
        }
        let faceTotal = corners.count / 3
        let words = (faceTotal + 63) / 64
        var visible = visibility(corners: corners, faceTotal: faceTotal, words: words, cameras: cameras, monitor: monitor)
        monitor.endStage("visibility")
        if stopped() { return .failure(CancellationError()) }
        let kept = coverCameras(visible: visible, cameras: cameras.count, words: words, limit: maxTextures)
        guard !kept.isEmpty else {
            return .failure(PlainError(message: "No triangle of the mesh is seen clearly in a photo."))
        }

        var outputs: [PartOutput] = []
        var inPhoto = 0
        monitor.beginStage()
        for (part, input) in parts.enumerated() {
            if stopped() { return .failure(CancellationError()) }
            var positionsBy: [Int: [Float]] = [:]
            var uvsBy: [Int: [Float]] = [:]
            let local = localFloats(input)
            let base = partStart[part]
            forEachFace(input, world: world[part]) { face, a, b, c in
                guard a != invalidPoint else { return }
                let global = base + face
                let classId = faceClass(input, face)
                var slot = -1
                var uv: [Float] = [0, 0, 0, 0, 0, 0]
                var bestScore = Float.greatestFiniteMagnitude
                for (mapped, index) in kept.enumerated() where isVisible(visible, camera: index, face: global, words: words) {
                    guard let value = score(a, b, c, cameras[index]), value < bestScore else { continue }
                    let camera = cameras[index]
                    var coords: [Float] = []
                    for point in [a, b, c] {
                        if let pixel = project(point, camera) {
                            coords.append(pixel.x / camera.width)
                            coords.append(pixel.y / camera.height)
                        }
                    }
                    guard coords.count == 6 else { continue }
                    bestScore = value
                    slot = mapped
                    uv = coords
                }
                if slot >= 0 { inPhoto += 1 }
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
            monitor.tick(of: parts.count, from: 0.7, to: 0.85)
        }
        monitor.endStage("picking photos")

        if stopped() { return .failure(CancellationError()) }
        var centroids: [SIMD3<Float>] = []
        centroids.reserveCapacity(faceTotal)
        for face in 0..<faceTotal {
            centroids.append((corners[face * 3] + corners[face * 3 + 1] + corners[face * 3 + 2]) / 3)
        }
        let pairs = gainPairs(kept: kept, visible: visible, words: words, centroids: centroids, cameras: cameras, samples: kept.map { index in candidates[index].imageURL.flatMap(loadLuminance) })
        if stopped() { return .failure(CancellationError()) }
        let gains = levelGains(pairs: pairs, count: kept.count)
        monitor.report(0.9)
        monitor.endStage("brightness")
        corners = []
        centroids = []
        visible = []

        var images: [CGImage?] = []
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        monitor.beginStage()
        for (slot, index) in kept.enumerated() {
            if stopped() { return .failure(CancellationError()) }
            if let url = candidates[index].imageURL, let image = loadImage(url) {
                images.append(applyGain(gains[slot], to: image, context: context))
            } else {
                images.append(nil)
            }
            monitor.tick(of: kept.count, from: 0.9, to: 1)
        }
        monitor.endStage("loading photos")
        let unreadable = images.filter { $0 == nil }.count
        guard unreadable < images.count else {
            return .failure(PlainError(message: "None of the chosen frame photos could be opened for the texture."))
        }
        return .success(Output(parts: outputs, images: images, photosUnreadable: unreadable, facesInPhoto: inPhoto, totalFaces: totalFaces, photosUsed: kept.count, gains: gains))
    }

    static func coverCameras(visible: [UInt64], cameras: Int, words: Int, limit: Int) -> [Int] {
        guard words > 0, visible.count >= cameras * words else { return [] }
        var cover = [UInt64](repeating: 0, count: words)
        var chosen: [Int] = []
        var used = Set<Int>()
        while chosen.count < limit {
            var best = -1
            var bestGain = 0
            for camera in 0..<cameras where !used.contains(camera) {
                let base = camera * words
                var gain = 0
                for word in 0..<words {
                    gain += (visible[base + word] & ~cover[word]).nonzeroBitCount
                }
                if gain > bestGain {
                    bestGain = gain
                    best = camera
                }
            }
            guard best >= 0 else { break }
            chosen.append(best)
            used.insert(best)
            let base = best * words
            for word in 0..<words {
                cover[word] |= visible[base + word]
            }
        }
        return chosen.sorted()
    }

    static func levelGains(pairs: [(Int, Int, Float)], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var logs = [Float](repeating: 0, count: count)
        guard !pairs.isEmpty else { return logs.map { _ in 1 } }
        var linked = [Bool](repeating: false, count: count)
        for (a, b, _) in pairs {
            linked[a] = true
            linked[b] = true
        }
        let linkedCount = Float(linked.filter { $0 }.count)
        for _ in 0..<100 {
            var sum = [Float](repeating: 0, count: count)
            var seen = [Int](repeating: 0, count: count)
            for (a, b, ratio) in pairs {
                sum[a] += logs[b] + ratio
                seen[a] += 1
                sum[b] += logs[a] - ratio
                seen[b] += 1
            }
            var next = logs
            for index in 0..<count where seen[index] > 0 {
                next[index] = (logs[index] + sum[index] / Float(seen[index])) / 2
            }
            let mean = next.indices.reduce(Float(0)) { linked[$1] ? $0 + next[$1] : $0 } / linkedCount
            logs = next.indices.map { linked[$0] ? next[$0] - mean : 0 }
        }
        let limit = log(maxGain)
        return logs.map { exp(min(max($0, -limit), limit)) }
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

    private static func visibility(corners: [SIMD3<Float>], faceTotal: Int, words: Int, cameras: [Camera], monitor: Monitor) -> [UInt64] {
        var visible = [UInt64](repeating: 0, count: cameras.count * words)
        let chunks = (faceTotal + chunkFaces - 1) / chunkFaces
        visible.withUnsafeMutableBufferPointer { bits in
            corners.withUnsafeBufferPointer { points in
                monitor.beginStage()
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    guard !monitor.isCancelled else { return }
                    let start = chunk * chunkFaces
                    let end = min(start + chunkFaces, faceTotal)
                    for face in start..<end {
                        if face % 256 == 0, monitor.isCancelled { return }
                        let a = points[face * 3]
                        let b = points[face * 3 + 1]
                        let c = points[face * 3 + 2]
                        for (index, camera) in cameras.enumerated() where score(a, b, c, camera) != nil {
                            bits[index * words + face / 64] |= UInt64(1) << UInt64(face % 64)
                        }
                    }
                    monitor.tick(of: chunks, from: 0.15, to: 0.7)
                }
            }
        }
        return visible
    }

    private static func isVisible(_ visible: [UInt64], camera: Int, face: Int, words: Int) -> Bool {
        visible[camera * words + face / 64] & (UInt64(1) << UInt64(face % 64)) != 0
    }

    private struct Luminance {
        let width: Int
        let height: Int
        let values: [UInt8]
    }

    private static func gainPairs(kept: [Int], visible: [UInt64], words: Int, centroids: [SIMD3<Float>], cameras: [Camera], samples: [Luminance?]) -> [(Int, Int, Float)] {
        var pairs: [(Int, Int, Float)] = []
        for a in kept.indices {
            guard let first = samples[a] else { continue }
            for b in kept.indices where b > a {
                guard let second = samples[b] else { continue }
                var shared: [Int] = []
                for word in 0..<words {
                    var bits = visible[kept[a] * words + word] & visible[kept[b] * words + word]
                    while bits != 0 {
                        shared.append(word * 64 + bits.trailingZeroBitCount)
                        bits &= bits - 1
                    }
                }
                guard shared.count >= 200 else { continue }
                let step = max(1, shared.count / 400)
                var ratios: [Float] = []
                for position in stride(from: 0, to: shared.count, by: step) {
                    let point = centroids[shared[position]]
                    guard let la = luminance(point, cameras[kept[a]], first), let lb = luminance(point, cameras[kept[b]], second), la > 0.03, lb > 0.03 else { continue }
                    ratios.append(log(lb / la))
                }
                guard ratios.count >= 100 else { continue }
                ratios.sort()
                pairs.append((a, b, ratios[ratios.count / 2]))
            }
        }
        return pairs
    }

    private static func luminance(_ point: SIMD3<Float>, _ camera: Camera, _ sample: Luminance) -> Float? {
        guard let pixel = project(point, camera) else { return nil }
        let x = min(Int(pixel.x * Float(sample.width) / camera.width), sample.width - 1)
        let y = min(Int(pixel.y * Float(sample.height) / camera.height), sample.height - 1)
        return Float(sample.values[y * sample.width + x]) / 255
    }

    private static func loadLuminance(_ url: URL) -> Luminance? {
        guard let image = thumbnail(url, size: gainSampleSize) else { return nil }
        let width = image.width
        let height = image.height
        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Luminance(width: width, height: height, values: values) : nil
    }

    private static func applyGain(_ gain: Float, to image: CGImage, context: CIContext) -> CGImage {
        guard abs(gain - 1) > 0.02 else { return image }
        let value = CGFloat(gain)
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0)
        ])
        return context.createCGImage(output, from: input.extent) ?? image
    }

    private static func forEachFace(_ input: PartInput, world: [SIMD3<Float>], _ body: (Int, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        guard input.faces.count >= input.faceCount * 12 else { return }
        for face in 0..<input.faceCount {
            let i0 = Int(faceIndex(input, face, 0))
            let i1 = Int(faceIndex(input, face, 1))
            let i2 = Int(faceIndex(input, face, 2))
            if i0 < world.count, i1 < world.count, i2 < world.count {
                body(face, world[i0], world[i1], world[i2])
            } else {
                body(face, invalidPoint, invalidPoint, invalidPoint)
            }
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

    private static func thumbnail(_ url: URL, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        thumbnail(url, size: textureSize)
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
