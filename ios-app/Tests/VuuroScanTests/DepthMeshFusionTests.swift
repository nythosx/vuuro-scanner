import XCTest
import simd
@testable import VuuroScan

final class DepthMeshFusionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("frames", isDirectory: true), withIntermediateDirectories: true)
        let manifest = LidarCaptureManifest(
            createdAt: "2026-11-04T00:00:00Z",
            updatedAt: "2026-11-04T00:00:00Z",
            device: "test",
            systemVersion: "17.0",
            supportsSceneDepth: true,
            supportsMeshClassification: true
        )
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(LidarCaptureLibrary.manifestName))
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func writeFrame(index: Int, cameraX: Double, depthMillimeters: UInt16) throws {
        let frames = root.appendingPathComponent("frames", isDirectory: true)
        let stem = String(format: "%06d", index)
        let width = 256
        let height = 192
        let depth = [UInt16](repeating: depthMillimeters, count: width * height)
        try depth.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: frames.appendingPathComponent("\(stem).depth"))
        try Data(repeating: 2, count: width * height).write(to: frames.appendingPathComponent("\(stem).conf"))
        let meta: [String: Any] = [
            "index": index,
            "image": "\(stem).jpg",
            "image_width": 1920,
            "image_height": 1440,
            "camera_transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, cameraX, 1.5, 0, 1],
            "intrinsics_fx_fy_cx_cy": [1373.0, 1373.0, 960.0, 720.0],
            "depth": "\(stem).depth",
            "depth_width": width,
            "depth_height": height,
            "confidence": "\(stem).conf"
        ]
        try JSONSerialization.data(withJSONObject: meta).write(to: frames.appendingPathComponent("\(stem).json"))
    }

    func testFlatWallInFrontOfTheCameraBecomesAWallMesh() throws {
        for index in 0..<3 {
            try writeFrame(index: index + 1, cameraX: Double(index) * 0.2, depthMillimeters: 2000)
        }

        let updated = try DepthMeshFusion.run(captureURL: root).get()
        let report = try XCTUnwrap(updated.depthMesh)
        XCTAssertGreaterThan(report.faces, 1000)
        XCTAssertEqual(report.framesUsed, 3)
        XCTAssertEqual(report.framesFailed, 0)

        let mesh = root.appendingPathComponent("mesh", isDirectory: true)
        let classes = [UInt8](try Data(contentsOf: mesh.appendingPathComponent("anchor_0000.classes")))
        XCTAssertEqual(classes.count, report.faces)
        let walls = classes.filter { $0 == 1 }.count
        XCTAssertGreaterThan(Double(walls) / Double(classes.count), 0.9)

        let vertexData = try Data(contentsOf: mesh.appendingPathComponent("anchor_0000.vertices"))
        var vertices = [Float](repeating: 0, count: vertexData.count / 4)
        _ = vertices.withUnsafeMutableBytes { vertexData.copyBytes(to: $0) }
        let depths = stride(from: 2, to: vertices.count, by: 3).map { vertices[$0] }
        let meanZ = depths.reduce(0, +) / Float(depths.count)
        XCTAssertEqual(meanZ, -2, accuracy: 0.05)

        let normalData = try Data(contentsOf: mesh.appendingPathComponent("anchor_0000.normals"))
        var normals = [Float](repeating: 0, count: normalData.count / 4)
        _ = normals.withUnsafeMutableBytes { normalData.copyBytes(to: $0) }
        let towardCamera = stride(from: 2, to: normals.count, by: 3).filter { normals[$0] > 0.8 }.count
        XCTAssertGreaterThan(Double(towardCamera) / Double(normals.count / 3), 0.9)

        let saved = try LidarCaptureLibrary.manifest(at: root)
        XCTAssertEqual(saved.depthMesh, report)
    }

    func testRoomPlanDoorLabelsTheWallTrianglesInsideIt() throws {
        for index in 0..<3 {
            try writeFrame(index: index + 1, cameraX: Double(index) * 0.2, depthMillimeters: 2000)
        }
        let door = LidarRoomBox(
            kind: "door",
            category: "door",
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.2, 1.5, -2, 1],
            dimensions: [0.8, 1.0, 0]
        )
        let sofa = LidarRoomBox(
            kind: "object",
            category: "sofa",
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -0.9, 1.5, -2, 1],
            dimensions: [0.4, 0.4, 0.4]
        )
        try JSONEncoder().encode([door, sofa]).write(to: root.appendingPathComponent(DepthMeshFusion.roomBoxesName))

        let report = try XCTUnwrap(try DepthMeshFusion.run(captureURL: root).get().depthMesh)
        XCTAssertEqual(report.roomBoxes, 2)
        XCTAssertFalse(report.roomBoxesUnreadable)
        XCTAssertGreaterThan(report.openingFaces, 200)
        XCTAssertGreaterThan(report.objectFaces, 20)

        let classes = [UInt8](try Data(contentsOf: root.appendingPathComponent("mesh/anchor_0000.classes")))
        XCTAssertEqual(classes.filter { $0 == DepthMeshFusion.doorClass }.count, report.openingFaces)
        XCTAssertEqual(classes.filter { $0 == DepthMeshFusion.seatClass }.count, report.objectFaces)
    }

    func testUnreadableRoomPlanBoxesStillBuildTheMesh() throws {
        for index in 0..<3 {
            try writeFrame(index: index + 1, cameraX: Double(index) * 0.2, depthMillimeters: 2000)
        }
        try Data("not json".utf8).write(to: root.appendingPathComponent(DepthMeshFusion.roomBoxesName))

        let report = try XCTUnwrap(try DepthMeshFusion.run(captureURL: root).get().depthMesh)
        XCTAssertTrue(report.roomBoxesUnreadable)
        XCTAssertEqual(report.roomBoxes, 0)
        XCTAssertGreaterThan(report.faces, 1000)
    }

    func testCaptureWithoutDepthFailsWithAMessage() throws {
        let frames = root.appendingPathComponent("frames", isDirectory: true)
        let meta: [String: Any] = [
            "index": 1,
            "image": "000001.jpg",
            "image_width": 1920,
            "image_height": 1440,
            "camera_transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            "intrinsics_fx_fy_cx_cy": [1373.0, 1373.0, 960.0, 720.0]
        ]
        try JSONSerialization.data(withJSONObject: meta).write(to: frames.appendingPathComponent("000001.json"))

        switch DepthMeshFusion.run(captureURL: root) {
        case .success:
            XCTFail("A capture without depth must not produce a mesh")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("No depth frames"))
        }
        XCTAssertNil(try LidarCaptureLibrary.manifest(at: root).depthMesh)
    }
}
