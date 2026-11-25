import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

enum LidarModelGlb {
    static let skippedClasses: Set<UInt8> = [9]
    static let jpegQuality: CGFloat = 0.9
    static let maxBytes = 120 * 1_048_576
    static let webPixelBudget = 52 * 1024 * 768

    struct Part {
        let output: MeshPhotoTexturer.PartOutput
        let transform: simd_float4x4
    }

    struct StartView: Equatable {
        let position: SIMD3<Float>
        let target: SIMD3<Float>
    }

    struct RoomMark: Equatable {
        let center: SIMD3<Float>
        let areaM2: Float
        let widthM: Float
        let lengthM: Float
    }

    static let minimumRoomAreaM2: Float = 0.25
    static let minimumStartDistanceM: Float = 0.5

    struct Encoded {
        let data: Data
        let triangles: Int
        let photos: Int
    }

    private struct VertexKey: Hashable {
        let x: UInt32
        let y: UInt32
        let z: UInt32
        let u: UInt32
        let v: UInt32
        let shade: UInt8
    }

    private struct Builder {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        mutating func view(_ bytes: Data, target: Int?) -> Int {
            pad()
            var view: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": bytes.count]
            if let target { view["target"] = target }
            bin.append(bytes)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        mutating func accessor(_ bytes: Data, componentType: Int, count: Int, type: String, target: Int = 34962, normalized: Bool = false, min: [Double]? = nil, max: [Double]? = nil) -> Int {
            var accessor: [String: Any] = ["bufferView": view(bytes, target: target), "componentType": componentType, "count": count, "type": type]
            if normalized { accessor["normalized"] = true }
            if let min { accessor["min"] = min }
            if let max { accessor["max"] = max }
            accessors.append(accessor)
            return accessors.count - 1
        }

        mutating func pad() {
            while bin.count % 4 != 0 { bin.append(0) }
        }
    }

    static func encode(parts: [Part], images: [CGImage?], startView: StartView? = nil, rooms: [RoomMark] = []) -> Result<Encoded, Error> {
        var builder = Builder()
        var materials: [[String: Any]] = []
        var materialIndex: [Int: Int] = [:]
        var textureIndex: [Int: Int] = [:]
        var imageEntries: [[String: Any]] = []
        var primitives: [[String: Any]] = []
        var triangles = 0
        let photoSlots = Set(parts.flatMap { part in part.output.groups.filter { !skippedClasses.contains($0.classId) && $0.count >= 3 && $0.slot >= 0 }.map(\.slot) })
        let photoPixels = photoSlots.reduce(0) { total, slot in
            guard images.indices.contains(slot), let image = images[slot] else { return total }
            return total + image.width * image.height
        }
        let scale = webScale(totalPixels: photoPixels)

        for part in parts {
            let positions = floats(part.output.positions)
            let uvs = floats(part.output.uvs)
            let shades = part.output.colors.count == part.output.vertexCount * 12 ? floats(part.output.colors) : []
            guard positions.count == part.output.vertexCount * 3, uvs.count == part.output.vertexCount * 2 else {
                return .failure(PlainError(message: "The photo model has a part with mismatched points and photo positions."))
            }
            for group in part.output.groups where !skippedClasses.contains(group.classId) && group.count >= 3 {
                let range = group.start..<(group.start + group.count - group.count % 3)
                guard range.upperBound <= part.output.vertexCount else {
                    return .failure(PlainError(message: "The photo model has a group that runs past its points."))
                }
                var world: [Float] = []
                world.reserveCapacity(range.count * 3)
                var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                var groupUVs: [Float] = []
                groupUVs.reserveCapacity(range.count * 2)
                var colors: [UInt8] = []
                colors.reserveCapacity(range.count * 4)
                var indices: [UInt32] = []
                indices.reserveCapacity(range.count)
                var lookup: [VertexKey: UInt32] = [:]
                lookup.reserveCapacity(range.count / 2)
                for vertex in range {
                    let local = SIMD4<Float>(positions[vertex * 3], positions[vertex * 3 + 1], positions[vertex * 3 + 2], 1)
                    let moved = part.transform * local
                    let point = SIMD3<Float>(moved.x, moved.y, moved.z)
                    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                        return .failure(PlainError(message: "The photo model has a point that is not a number."))
                    }
                    let rawU = uvs[vertex * 2]
                    let rawV = uvs[vertex * 2 + 1]
                    let u: Float = rawU.isFinite ? rawU : 0
                    let v: Float = rawV.isFinite ? rawV : 0
                    let shade = shades.isEmpty ? 1 : shades[vertex * 3]
                    let byte = UInt8((min(max(shade.isFinite ? shade : 1, 0), 1) * 255).rounded())
                    let key = VertexKey(x: point.x.bitPattern, y: point.y.bitPattern, z: point.z.bitPattern, u: u.bitPattern, v: v.bitPattern, shade: byte)
                    if let existing = lookup[key] {
                        indices.append(existing)
                        continue
                    }
                    let next = UInt32(world.count / 3)
                    lookup[key] = next
                    indices.append(next)
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                    world.append(contentsOf: [point.x, point.y, point.z])
                    groupUVs.append(u)
                    groupUVs.append(v)
                    colors.append(contentsOf: [byte, byte, byte, 255])
                }
                let vertexCount = world.count / 3
                let position = builder.accessor(bytes(world), componentType: 5126, count: vertexCount, type: "VEC3", min: [Double(lower.x), Double(lower.y), Double(lower.z)], max: [Double(upper.x), Double(upper.y), Double(upper.z)])
                let texcoord = builder.accessor(bytes(groupUVs), componentType: 5126, count: vertexCount, type: "VEC2")
                let color = builder.accessor(Data(colors), componentType: 5121, count: vertexCount, type: "VEC4", normalized: true)
                let index = vertexCount <= Int(UInt16.max)
                    ? builder.accessor(indexBytes16(indices), componentType: 5123, count: indices.count, type: "SCALAR", target: 34963)
                    : builder.accessor(indexBytes32(indices), componentType: 5125, count: indices.count, type: "SCALAR", target: 34963)

                let key = (group.slot + 1) * 256 + Int(group.classId)
                if materialIndex[key] == nil {
                    var pbr: [String: Any] = ["metallicFactor": 0, "roughnessFactor": 1]
                    if group.slot >= 0, images.indices.contains(group.slot), let image = images[group.slot] {
                        if textureIndex[group.slot] == nil {
                            guard let jpeg = jpeg(image, scale: scale) else {
                                return .failure(PlainError(message: "Photo \(group.slot + 1) of the model could not be saved as JPEG."))
                            }
                            imageEntries.append(["bufferView": builder.view(jpeg, target: nil), "mimeType": "image/jpeg"])
                            textureIndex[group.slot] = imageEntries.count - 1
                        }
                        pbr["baseColorTexture"] = ["index": textureIndex[group.slot] ?? 0]
                    } else {
                        pbr["baseColorFactor"] = [0.6, 0.6, 0.6, 1]
                    }
                    materials.append([
                        "name": "photo-\(group.slot)-class-\(group.classId)",
                        "pbrMetallicRoughness": pbr,
                        "doubleSided": true,
                        "extensions": ["KHR_materials_unlit": [String: Any]()],
                        "extras": ["class": Int(group.classId), "slot": group.slot]
                    ])
                    materialIndex[key] = materials.count - 1
                }
                primitives.append([
                    "attributes": ["POSITION": position, "TEXCOORD_0": texcoord, "COLOR_0": color],
                    "indices": index,
                    "material": materialIndex[key] ?? 0,
                    "mode": 4
                ])
                triangles += range.count / 3
                if builder.bin.count > maxBytes {
                    return .failure(PlainError(message: "The photo model is larger than \(maxBytes / 1_048_576) MB, too big to send."))
                }
            }
        }
        guard !primitives.isEmpty else {
            return .failure(PlainError(message: "The photo model has no triangles to send."))
        }
        builder.pad()
        var gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Vuuro Scan LiDAR"],
            "extensionsUsed": ["KHR_materials_unlit"],
            "scene": 0,
            "scenes": [sceneEntry(startView: startView, rooms: rooms)],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": primitives]],
            "materials": materials,
            "accessors": builder.accessors,
            "bufferViews": builder.bufferViews,
            "buffers": [["byteLength": builder.bin.count]]
        ]
        if !imageEntries.isEmpty {
            gltf["images"] = imageEntries
            gltf["textures"] = imageEntries.indices.map { ["source": $0, "sampler": 0] }
            gltf["samplers"] = [["magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071]]
        }
        guard JSONSerialization.isValidJSONObject(gltf) else {
            return .failure(PlainError(message: "The photo model description could not be written."))
        }
        let json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys])
        } catch {
            return .failure(error)
        }
        let glb = container(json: json, bin: builder.bin)
        guard glb.count <= maxBytes else {
            return .failure(PlainError(message: "The photo model is larger than \(maxBytes / 1_048_576) MB, too big to send."))
        }
        return .success(Encoded(data: glb, triangles: triangles, photos: imageEntries.count))
    }

    static func sceneEntry(startView: StartView?, rooms: [RoomMark]) -> [String: Any] {
        var extras: [String: Any] = [:]
        if let startView, finite(startView.position), finite(startView.target), simd_distance(startView.position, startView.target) >= minimumStartDistanceM * 0.99 {
            extras["start_view"] = ["position": doubles(startView.position), "target": doubles(startView.target)]
        }
        let marks = rooms.filter { finite($0.center) && $0.areaM2.isFinite && $0.areaM2 >= minimumRoomAreaM2 && $0.widthM.isFinite && $0.lengthM.isFinite }
        if !marks.isEmpty {
            extras["rooms"] = marks.map { mark -> [String: Any] in
                ["center": doubles(mark.center), "area_m2": Double(mark.areaM2), "width_m": Double(mark.widthM), "length_m": Double(mark.lengthM)]
            }
        }
        var entry: [String: Any] = ["nodes": [0]]
        if !extras.isEmpty { entry["extras"] = extras }
        return entry
    }

    static func startView(cameraTransform: simd_float4x4, lookingToward center: SIMD3<Float>) -> StartView? {
        let position = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let back = SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        guard finite(position), finite(center), finite(back), simd_length(back) > 0.0001 else { return nil }
        let forward = -simd_normalize(back)
        let along = simd_dot(center - position, forward)
        let distance = max(along.isFinite ? along : 0, minimumStartDistanceM)
        return StartView(position: position, target: position + forward * distance)
    }

    static func roomMarks(from boxes: [LidarRoomBox]) -> [RoomMark] {
        boxes.compactMap { box -> RoomMark? in
            guard box.kind == "floor", let corners = box.corners, corners.count >= 3 else { return nil }
            let points = corners.compactMap { corner -> SIMD3<Float>? in
                guard corner.count == 3, corner.allSatisfy({ $0.isFinite }) else { return nil }
                return SIMD3<Float>(corner[0], corner[1], corner[2])
            }
            guard points.count == corners.count else { return nil }
            var twiceArea: Float = 0
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                twiceArea += a.x * b.z - b.x * a.z
            }
            let area = abs(twiceArea) / 2
            guard area.isFinite, area >= minimumRoomAreaM2 else { return nil }
            let lower = points.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
            let upper = points.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
            let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
            return RoomMark(center: center, areaM2: area, widthM: upper.x - lower.x, lengthM: upper.z - lower.z)
        }
    }

    private static func finite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func doubles(_ value: SIMD3<Float>) -> [Double] {
        [Double(value.x), Double(value.y), Double(value.z)]
    }

    static func container(json: Data, bin: Data) -> Data {
        var jsonChunk = json
        while jsonChunk.count % 4 != 0 { jsonChunk.append(0x20) }
        var binChunk = bin
        while binChunk.count % 4 != 0 { binChunk.append(0) }
        var out = Data()
        let total = 12 + 8 + jsonChunk.count + 8 + binChunk.count
        append(&out, 0x46546C67)
        append(&out, 2)
        append(&out, UInt32(total))
        append(&out, UInt32(jsonChunk.count))
        append(&out, 0x4E4F534A)
        out.append(jsonChunk)
        append(&out, UInt32(binChunk.count))
        append(&out, 0x004E4942)
        out.append(binChunk)
        return out
    }

    static func webScale(totalPixels: Int) -> CGFloat {
        guard totalPixels > webPixelBudget else { return 1 }
        return CGFloat((Double(webPixelBudget) / Double(totalPixels)).squareRoot())
    }

    static func resized(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage, scale: CGFloat = 1) -> Data? {
        var source = image
        if scale < 1 {
            guard let smaller = resized(image, scale: scale) else { return nil }
            source = smaller
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func append(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func floats(_ data: Data) -> [Float] {
        var values = [Float](repeating: 0, count: data.count / 4)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    private static func bytes(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func indexBytes16(_ indices: [UInt32]) -> Data {
        let narrow = indices.map { UInt16(truncatingIfNeeded: $0).littleEndian }
        return narrow.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func indexBytes32(_ indices: [UInt32]) -> Data {
        let little = indices.map { $0.littleEndian }
        return little.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
