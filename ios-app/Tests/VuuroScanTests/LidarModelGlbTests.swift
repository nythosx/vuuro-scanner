import CoreGraphics
import XCTest
import simd
@testable import VuuroScan

final class LidarModelGlbTests: XCTestCase {
    private func data(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func image() -> CGImage? {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context?.makeImage()
    }

    private func part(shift: SIMD3<Float>) -> LidarModelGlb.Part {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0]
        let uvs: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]
        let colors: [Float] = [0.5, 0.5, 0.5, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        let output = MeshPhotoTexturer.PartOutput(
            positions: data(positions),
            uvs: data(uvs),
            colors: data(colors),
            vertexCount: 6,
            groups: [
                MeshPhotoTexturer.Group(slot: 0, classId: 1, start: 0, count: 3),
                MeshPhotoTexturer.Group(slot: 0, classId: 9, start: 3, count: 3)
            ]
        )
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(shift, 1)
        return LidarModelGlb.Part(output: output, transform: transform)
    }

    private func parse(_ glb: Data) throws -> (json: [String: Any], bin: Data) {
        func word(_ at: Int) -> UInt32 {
            glb.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        XCTAssertEqual(word(0), 0x46546C67)
        XCTAssertEqual(word(4), 2)
        XCTAssertEqual(Int(word(8)), glb.count)
        let jsonLength = Int(word(12))
        XCTAssertEqual(word(16), 0x4E4F534A)
        XCTAssertEqual(jsonLength % 4, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + jsonLength))) as? [String: Any])
        let binStart = 20 + jsonLength
        let binLength = Int(word(binStart))
        XCTAssertEqual(word(binStart + 4), 0x004E4942)
        return (json, glb.subdata(in: (binStart + 8)..<(binStart + 8 + binLength)))
    }

    func testWritesAValidGlbWithWorldPositionsAndOnePhoto() throws {
        let result = LidarModelGlb.encode(parts: [part(shift: SIMD3<Float>(10, 0, 0))], images: [image()])
        let encoded = try result.get()
        XCTAssertEqual(encoded.triangles, 1)
        XCTAssertEqual(encoded.photos, 1)
        let (json, bin) = try parse(encoded.data)
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes.first?["primitives"] as? [[String: Any]])
        XCTAssertEqual(primitives.count, 1)
        let attributes = try XCTUnwrap(primitives[0]["attributes"] as? [String: Int])
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let position = accessors[try XCTUnwrap(attributes["POSITION"])]
        XCTAssertEqual(position["min"] as? [Double], [10, 0, 0])
        XCTAssertEqual(position["max"] as? [Double], [11, 1, 0])
        let color = accessors[try XCTUnwrap(attributes["COLOR_0"])]
        XCTAssertEqual(color["componentType"] as? Int, 5121)
        XCTAssertEqual(color["normalized"] as? Bool, true)
        XCTAssertEqual(color["type"] as? String, "VEC4")
        let views = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        for view in views {
            XCTAssertEqual((view["byteOffset"] as? Int ?? 1) % 4, 0)
        }
        let colorView = views[try XCTUnwrap(color["bufferView"] as? Int)]
        let colorOffset = try XCTUnwrap(colorView["byteOffset"] as? Int)
        XCTAssertEqual(Array(bin.subdata(in: colorOffset..<(colorOffset + 12))), [128, 128, 128, 255, 255, 255, 255, 255, 255, 255, 255, 255])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["mimeType"] as? String, "image/jpeg")
        let materials = try XCTUnwrap(json["materials"] as? [[String: Any]])
        XCTAssertEqual((materials.first?["extras"] as? [String: Int])?["class"], 1)
        XCTAssertNotNil((materials.first?["extensions"] as? [String: Any])?["KHR_materials_unlit"])
        XCTAssertEqual(json["extensionsUsed"] as? [String], ["KHR_materials_unlit"])
    }

    func testSharedCornersAreWrittenOnceWithIndices() throws {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]
        let uvs: [Float] = [0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1]
        let output = MeshPhotoTexturer.PartOutput(positions: data(positions), uvs: data(uvs), colors: Data(), vertexCount: 6, groups: [MeshPhotoTexturer.Group(slot: 0, classId: 1, start: 0, count: 6)])
        let encoded = try LidarModelGlb.encode(parts: [LidarModelGlb.Part(output: output, transform: matrix_identity_float4x4)], images: [image()]).get()
        XCTAssertEqual(encoded.triangles, 2)
        let (json, bin) = try parse(encoded.data)
        let primitive = try XCTUnwrap((json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]]).first
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let attributes = try XCTUnwrap(primitive?["attributes"] as? [String: Int])
        XCTAssertEqual(accessors[try XCTUnwrap(attributes["POSITION"])]["count"] as? Int, 4)
        XCTAssertEqual(accessors[try XCTUnwrap(attributes["TEXCOORD_0"])]["count"] as? Int, 4)
        let indices = accessors[try XCTUnwrap(primitive?["indices"] as? Int)]
        XCTAssertEqual(indices["count"] as? Int, 6)
        XCTAssertEqual(indices["componentType"] as? Int, 5123)
        let views = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        let indexView = views[try XCTUnwrap(indices["bufferView"] as? Int)]
        XCTAssertEqual(indexView["target"] as? Int, 34963)
        let offset = try XCTUnwrap(indexView["byteOffset"] as? Int)
        let values = bin.subdata(in: offset..<(offset + 12)).withUnsafeBytes { raw in (0..<6).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self) } }
        XCTAssertEqual(values, [0, 1, 2, 1, 3, 2])
    }

    func testCornersWithDifferentPhotoPositionsStayApart() throws {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]
        let uvs: [Float] = [0, 0, 1, 0, 0, 1, 0.5, 0, 1, 1, 0, 1]
        let output = MeshPhotoTexturer.PartOutput(positions: data(positions), uvs: data(uvs), colors: Data(), vertexCount: 6, groups: [MeshPhotoTexturer.Group(slot: 0, classId: 1, start: 0, count: 6)])
        let encoded = try LidarModelGlb.encode(parts: [LidarModelGlb.Part(output: output, transform: matrix_identity_float4x4)], images: [image()]).get()
        let (json, _) = try parse(encoded.data)
        let primitive = try XCTUnwrap((json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]]).first
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let attributes = try XCTUnwrap(primitive?["attributes"] as? [String: Int])
        XCTAssertEqual(accessors[try XCTUnwrap(attributes["POSITION"])]["count"] as? Int, 5)
    }

    func testStartViewAndRoomsAreWrittenToTheScene() throws {
        let start = LidarModelGlb.StartView(position: SIMD3<Float>(5, 2, 5), target: SIMD3<Float>(1, 0.5, 1))
        let room = LidarModelGlb.RoomMark(center: SIMD3<Float>(1, 0, 1), areaM2: 12, widthM: 4, lengthM: 3)
        let tiny = LidarModelGlb.RoomMark(center: SIMD3<Float>(9, 0, 9), areaM2: 0.1, widthM: 0.3, lengthM: 0.3)
        let encoded = try LidarModelGlb.encode(parts: [part(shift: .zero)], images: [image()], startView: start, rooms: [room, tiny]).get()
        let (json, _) = try parse(encoded.data)
        let scene = try XCTUnwrap((json["scenes"] as? [[String: Any]])?.first)
        let extras = try XCTUnwrap(scene["extras"] as? [String: Any])
        let view = try XCTUnwrap(extras["start_view"] as? [String: [Double]])
        XCTAssertEqual(view["position"], [5, 2, 5])
        XCTAssertEqual(view["target"], [1, 0.5, 1])
        let rooms = try XCTUnwrap(extras["rooms"] as? [[String: Any]])
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(rooms.first?["area_m2"] as? Double, 12)
        XCTAssertEqual(rooms.first?["center"] as? [Double], [1, 0, 1])
    }

    func testWithoutStartViewOrRoomsTheSceneHasNoExtras() throws {
        let encoded = try LidarModelGlb.encode(parts: [part(shift: .zero)], images: [image()]).get()
        let (json, _) = try parse(encoded.data)
        let scene = try XCTUnwrap((json["scenes"] as? [[String: Any]])?.first)
        XCTAssertNil(scene["extras"])
        XCTAssertEqual(scene["nodes"] as? [Int], [0])
    }

    func testStartViewLooksWhereTheCameraLooks() throws {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(0, 1.5, 6, 1)
        let start = try XCTUnwrap(LidarModelGlb.startView(cameraTransform: pose, lookingToward: SIMD3<Float>(0, 0, 0)))
        XCTAssertEqual(start.position, SIMD3<Float>(0, 1.5, 6))
        XCTAssertEqual(start.target.x, 0, accuracy: 1e-5)
        XCTAssertEqual(start.target.y, 1.5, accuracy: 1e-5)
        XCTAssertEqual(start.target.z, 0, accuracy: 1e-5)
        let behind = try XCTUnwrap(LidarModelGlb.startView(cameraTransform: pose, lookingToward: SIMD3<Float>(0, 0, 20)))
        XCTAssertEqual(simd_distance(behind.position, behind.target), LidarModelGlb.minimumStartDistanceM, accuracy: 1e-5)
    }

    func testRoomMarksComeFromFloorCorners() {
        let floor = LidarRoomBox(kind: "floor", category: "floor", transform: Array(repeating: 0, count: 16), dimensions: [4, 0, 3], corners: [[0, 0.1, 0], [4, 0.1, 0], [4, 0.1, 3], [0, 0.1, 3]])
        let wall = LidarRoomBox(kind: "door", category: "door", transform: Array(repeating: 0, count: 16), dimensions: [1, 2, 0])
        let broken = LidarRoomBox(kind: "floor", category: "floor", transform: Array(repeating: 0, count: 16), dimensions: [1, 0, 1], corners: [[0, 0, 0], [1, 0]])
        let marks = LidarModelGlb.roomMarks(from: [floor, wall, broken])
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.areaM2 ?? 0, 12, accuracy: 1e-4)
        XCTAssertEqual(marks.first?.widthM ?? 0, 4, accuracy: 1e-4)
        XCTAssertEqual(marks.first?.lengthM ?? 0, 3, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(marks.first?.center ?? .zero, SIMD3<Float>(2, 0.1, 1.5)), 0, accuracy: 1e-5)
    }

    func testAGroupWithoutAPhotoGetsGreyAndNoImage() throws {
        let encoded = try LidarModelGlb.encode(parts: [part(shift: .zero)], images: [nil]).get()
        XCTAssertEqual(encoded.photos, 0)
        let (json, _) = try parse(encoded.data)
        XCTAssertNil(json["images"])
        let materials = try XCTUnwrap(json["materials"] as? [[String: Any]])
        let pbr = try XCTUnwrap(materials.first?["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["baseColorFactor"] as? [Double], [0.6, 0.6, 0.6, 1])
    }

    func testOnlyFilledFloorIsRefusedAsEmpty() {
        var only = part(shift: .zero)
        only = LidarModelGlb.Part(output: MeshPhotoTexturer.PartOutput(positions: only.output.positions, uvs: only.output.uvs, colors: only.output.colors, vertexCount: 6, groups: [MeshPhotoTexturer.Group(slot: 0, classId: 9, start: 3, count: 3)]), transform: only.transform)
        guard case .failure = LidarModelGlb.encode(parts: [only], images: [image()]) else {
            return XCTFail("A model with only filled floor should not be sent")
        }
    }

    func testAMismatchedPartIsRefused() {
        let broken = LidarModelGlb.Part(output: MeshPhotoTexturer.PartOutput(positions: data([0, 0, 0]), uvs: data([0, 0]), colors: Data(), vertexCount: 6, groups: []), transform: matrix_identity_float4x4)
        guard case .failure = LidarModelGlb.encode(parts: [broken], images: []) else {
            return XCTFail("A part with too few points should be refused")
        }
    }

    func testChunkHelpers() {
        XCTAssertEqual(ScanServiceClient.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ScanServiceClient.receivedBytes(inErrorBody: "{\"error\":\"offset_mismatch\",\"received_bytes\":4194304}"), 4_194_304)
        XCTAssertNil(ScanServiceClient.receivedBytes(inErrorBody: "not json"))
        XCTAssertNil(ScanServiceClient.receivedBytes(inErrorBody: "{\"error\":\"x\"}"))
    }

    func testWebModelPhotosShrinkWhenThereAreMoreThanThePhoneBudget() throws {
        XCTAssertEqual(LidarModelGlb.webScale(totalPixels: LidarModelGlb.webPixelBudget), 1)
        XCTAssertEqual(LidarModelGlb.webScale(totalPixels: 1000), 1)
        XCTAssertEqual(LidarModelGlb.webScale(totalPixels: LidarModelGlb.webPixelBudget * 4), 0.5, accuracy: 0.0001)
        let source = try XCTUnwrap(image())
        let smaller = try XCTUnwrap(LidarModelGlb.resized(source, scale: 0.5))
        XCTAssertEqual(smaller.width, 4)
        XCTAssertEqual(smaller.height, 4)
        XCTAssertNotNil(LidarModelGlb.jpeg(source, scale: 0.5))
    }

    func testSentNoteIsSingularForOnePhoto() {
        XCTAssertEqual(MeshViewer.sentNote(bytes: 1_048_576 * 3, triangles: 1200, photos: 1), "Sent to the web tour: 3.0 MB, \(1200.formatted()) triangles, 1 photo. Open the tour link and tap 3D scan.")
    }
}
