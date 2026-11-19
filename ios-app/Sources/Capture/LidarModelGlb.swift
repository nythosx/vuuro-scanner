import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

enum LidarModelGlb {
    static let skippedClasses: Set<UInt8> = [9]
    static let jpegQuality: CGFloat = 0.8
    static let maxBytes = 120 * 1_048_576

    struct Part {
        let output: MeshPhotoTexturer.PartOutput
        let transform: simd_float4x4
    }

    struct Encoded {
        let data: Data
        let triangles: Int
        let photos: Int
    }

    private struct Builder {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        mutating func view(_ bytes: Data, vertexData: Bool) -> Int {
            pad()
            var view: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": bytes.count]
            if vertexData { view["target"] = 34962 }
            bin.append(bytes)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        mutating func accessor(_ bytes: Data, componentType: Int, count: Int, type: String, normalized: Bool = false, min: [Double]? = nil, max: [Double]? = nil) -> Int {
            var accessor: [String: Any] = ["bufferView": view(bytes, vertexData: true), "componentType": componentType, "count": count, "type": type]
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

    static func encode(parts: [Part], images: [CGImage?]) -> Result<Encoded, Error> {
        var builder = Builder()
        var materials: [[String: Any]] = []
        var materialIndex: [Int: Int] = [:]
        var textureIndex: [Int: Int] = [:]
        var imageEntries: [[String: Any]] = []
        var primitives: [[String: Any]] = []
        var triangles = 0

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
                for vertex in range {
                    let local = SIMD4<Float>(positions[vertex * 3], positions[vertex * 3 + 1], positions[vertex * 3 + 2], 1)
                    let moved = part.transform * local
                    let point = SIMD3<Float>(moved.x, moved.y, moved.z)
                    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                        return .failure(PlainError(message: "The photo model has a point that is not a number."))
                    }
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                    world.append(contentsOf: [point.x, point.y, point.z])
                    let u = uvs[vertex * 2]
                    let v = uvs[vertex * 2 + 1]
                    groupUVs.append(u.isFinite ? u : 0)
                    groupUVs.append(v.isFinite ? v : 0)
                    let shade = shades.isEmpty ? 1 : shades[vertex * 3]
                    let byte = UInt8((min(max(shade.isFinite ? shade : 1, 0), 1) * 255).rounded())
                    colors.append(contentsOf: [byte, byte, byte, 255])
                }
                let position = builder.accessor(bytes(world), componentType: 5126, count: range.count, type: "VEC3", min: [Double(lower.x), Double(lower.y), Double(lower.z)], max: [Double(upper.x), Double(upper.y), Double(upper.z)])
                let texcoord = builder.accessor(bytes(groupUVs), componentType: 5126, count: range.count, type: "VEC2")
                let color = builder.accessor(Data(colors), componentType: 5121, count: range.count, type: "VEC4", normalized: true)

                let key = (group.slot + 1) * 256 + Int(group.classId)
                if materialIndex[key] == nil {
                    var pbr: [String: Any] = ["metallicFactor": 0, "roughnessFactor": 1]
                    if group.slot >= 0, images.indices.contains(group.slot), let image = images[group.slot] {
                        if textureIndex[group.slot] == nil {
                            guard let jpeg = jpeg(image) else {
                                return .failure(PlainError(message: "Photo \(group.slot + 1) of the model could not be saved as JPEG."))
                            }
                            imageEntries.append(["bufferView": builder.view(jpeg, vertexData: false), "mimeType": "image/jpeg"])
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
            "scenes": [["nodes": [0]]],
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

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
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
}
