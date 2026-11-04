import CoreGraphics
import Foundation
import ImageIO
import simd

enum MeshTexturer {
    struct PartInput {
        let vertices: Data
        let vertexCount: Int
        let transform: simd_float4x4
    }

    struct Output {
        let colors: [Data]
        let framesUsed: Int
        let framesFailed: Int
        let coloredVertices: Int
        let totalVertices: Int
    }

    static let maxFrames = 200
    static let thumbnailSize = 640
    static let minDistance: Float = 0.1
    static let maxDistance: Float = 8
    static let uncolored: Float = 0.6

    private struct Photo {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private struct Depth {
        let values: [UInt16]
        let width: Int
        let height: Int
    }

    static func colorize(parts: [PartInput], frames: [MeshFrame]) -> Result<Output, Error> {
        let world = parts.map(worldVertices)
        let total = world.reduce(0) { $0 + $1.count }
        guard total > 0 else {
            return .failure(PlainError(message: "The mesh has no points to color."))
        }
        guard !frames.isEmpty else {
            return .failure(PlainError(message: "This capture has no frame photos."))
        }
        var best = world.map { [Float](repeating: .greatestFiniteMagnitude, count: $0.count) }
        var colors = world.map { [Float](repeating: uncolored, count: $0.count * 3) }
        let step = max(1, (frames.count + maxFrames - 1) / maxFrames)
        var used = 0
        var failed = 0
        for frameIndex in stride(from: 0, to: frames.count, by: step) {
            if Task.isCancelled { return .failure(CancellationError()) }
            let frame = frames[frameIndex]
            guard let imageURL = frame.imageURL, let photo = loadPhoto(imageURL) else {
                failed += 1
                continue
            }
            used += 1
            let depth = loadDepth(frame)
            let view = frame.cameraTransform.inverse
            let imageWidth = Float(frame.imageWidth)
            let imageHeight = Float(frame.imageHeight)
            let halfWidth = imageWidth / 2
            let halfHeight = imageHeight / 2
            let scaleX = Float(photo.width) / imageWidth
            let scaleY = Float(photo.height) / imageHeight
            for part in world.indices {
                world[part].withUnsafeBufferPointer { points in
                    best[part].withUnsafeMutableBufferPointer { bestScore in
                        colors[part].withUnsafeMutableBufferPointer { color in
                            for i in 0..<points.count {
                                let camera = view * SIMD4<Float>(points[i], 1)
                                let distance = -camera.z
                                if distance < minDistance || distance > maxDistance { continue }
                                let u = frame.fx * camera.x / distance + frame.cx
                                let v = -frame.fy * camera.y / distance + frame.cy
                                if u < 0 || v < 0 || u >= imageWidth || v >= imageHeight { continue }
                                let offCenter = max(abs(u - halfWidth) / halfWidth, abs(v - halfHeight) / halfHeight)
                                let score = distance * (1 + offCenter)
                                if score >= bestScore[i] { continue }
                                if let depth {
                                    let du = min(Int(u * Float(depth.width) / imageWidth), depth.width - 1)
                                    let dv = min(Int(v * Float(depth.height) / imageHeight), depth.height - 1)
                                    let millimeters = depth.values[dv * depth.width + du]
                                    if millimeters > 0 {
                                        let measured = Float(millimeters) / 1000
                                        if abs(measured - distance) > 0.08 + 0.03 * distance { continue }
                                    }
                                }
                                let px = min(Int(u * scaleX), photo.width - 1)
                                let py = min(Int(v * scaleY), photo.height - 1)
                                let offset = (py * photo.width + px) * 4
                                bestScore[i] = score
                                color[i * 3] = Float(photo.pixels[offset]) / 255
                                color[i * 3 + 1] = Float(photo.pixels[offset + 1]) / 255
                                color[i * 3 + 2] = Float(photo.pixels[offset + 2]) / 255
                            }
                        }
                    }
                }
            }
        }
        guard used > 0 else {
            return .failure(PlainError(message: "None of the \(failed) frame photos could be opened."))
        }
        let colored = best.reduce(0) { sum, scores in sum + scores.filter { $0 < .greatestFiniteMagnitude }.count }
        let data = colors.map { values in values.withUnsafeBufferPointer { Data(buffer: $0) } }
        return .success(Output(colors: data, framesUsed: used, framesFailed: failed, coloredVertices: colored, totalVertices: total))
    }

    private static func worldVertices(_ part: PartInput) -> [SIMD3<Float>] {
        guard part.vertexCount > 0, part.vertices.count >= part.vertexCount * 12 else { return [] }
        var floats = [Float](repeating: 0, count: part.vertexCount * 3)
        _ = floats.withUnsafeMutableBytes { part.vertices.copyBytes(to: $0) }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(part.vertexCount)
        for i in 0..<part.vertexCount {
            let world = part.transform * SIMD4<Float>(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2], 1)
            points.append(SIMD3<Float>(world.x, world.y, world.z))
        }
        return points
    }

    private static func loadPhoto(_ url: URL) -> Photo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Photo(pixels: pixels, width: width, height: height) : nil
    }

    private static func loadDepth(_ frame: MeshFrame) -> Depth? {
        guard let url = frame.depthURL, frame.depthWidth > 0, frame.depthHeight > 0 else { return nil }
        let count = frame.depthWidth * frame.depthHeight
        guard let data = FileManager.default.contents(atPath: url.path), data.count >= count * 2 else { return nil }
        var values = [UInt16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return Depth(values: values, width: frame.depthWidth, height: frame.depthHeight)
    }
}
