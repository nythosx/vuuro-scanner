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

    private func writeFrame(index: Int, cameraX: Double, depthMillimeters: UInt16, folder: String = "frames", withImage: Bool = true) throws {
        let frames = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let stem = String(format: "%06d", index)
        let width = 256
        let height = 192
        let depth = [UInt16](repeating: depthMillimeters, count: width * height)
        try depth.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: frames.appendingPathComponent("\(stem).depth"))
        try Data(repeating: 2, count: width * height).write(to: frames.appendingPathComponent("\(stem).conf"))
        var meta: [String: Any] = [
            "index": index,
            "image_width": 1920,
            "image_height": 1440,
            "camera_transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, cameraX, 1.5, 0, 1],
            "intrinsics_fx_fy_cx_cy": [1373.0, 1373.0, 960.0, 720.0],
            "depth": "\(stem).depth",
            "depth_width": width,
            "depth_height": height,
            "confidence": "\(stem).conf"
        ]
        if withImage { meta["image"] = "\(stem).jpg" }
        try JSONSerialization.data(withJSONObject: meta).write(to: frames.appendingPathComponent("\(stem).json"))
    }

    private func writeWall() throws {
        for index in 0..<3 {
            try writeFrame(index: index + 1, cameraX: Double(index) * 0.2, depthMillimeters: 2000)
        }
    }

    private func readFloats(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: root.appendingPathComponent("mesh/\(name)"))
        var values = [Float](repeating: 0, count: data.count / 4)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    private func readClasses() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: root.appendingPathComponent("mesh/anchor_0000.classes")))
    }

    func testFlatWallInFrontOfTheCameraBecomesAWallMesh() throws {
        try writeWall()

        let report = try DepthMeshFusion.run(captureURL: root).get()
        XCTAssertGreaterThan(report.faces, 1000)
        XCTAssertEqual(report.framesUsed, 3)
        XCTAssertEqual(report.depthOnlyFramesUsed, 0)
        XCTAssertEqual(report.framesFailed, 0)
        XCTAssertFalse(report.fillClippedToRoomPlan)

        let classes = try readClasses()
        XCTAssertEqual(classes.count, report.faces)
        let walls = classes.filter { $0 == DepthMeshFusion.wallClass }.count
        XCTAssertGreaterThan(Double(walls) / Double(classes.count), 0.9)

        let vertices = try readFloats("anchor_0000.vertices")
        let depths = stride(from: 2, to: vertices.count, by: 3).map { vertices[$0] }
        XCTAssertEqual(depths.reduce(0, +) / Float(depths.count), -2, accuracy: 0.05)

        let normals = try readFloats("anchor_0000.normals")
        let towardCamera = stride(from: 2, to: normals.count, by: 3).filter { normals[$0] > 0.8 }.count
        XCTAssertGreaterThan(Double(towardCamera) / Double(normals.count / 3), 0.9)

        let faces = try Data(contentsOf: root.appendingPathComponent("mesh/anchor_0000.faces"))
        var indices = [UInt32](repeating: 0, count: faces.count / 4)
        _ = indices.withUnsafeMutableBytes { faces.copyBytes(to: $0) }
        var facingCamera = 0
        for face in 0..<(indices.count / 3) {
            let a = Int(indices[face * 3]) * 3
            let b = Int(indices[face * 3 + 1]) * 3
            let c = Int(indices[face * 3 + 2]) * 3
            let pa = SIMD3<Float>(vertices[a], vertices[a + 1], vertices[a + 2])
            let pb = SIMD3<Float>(vertices[b], vertices[b + 1], vertices[b + 2])
            let pc = SIMD3<Float>(vertices[c], vertices[c + 1], vertices[c + 2])
            if simd_cross(pb - pa, pc - pa).z > 0 { facingCamera += 1 }
        }
        XCTAssertGreaterThan(Double(facingCamera) / Double(walls), 0.95)

        let saved = try XCTUnwrap(try DepthMeshFusion.loadReport(captureURL: root).get())
        XCTAssertEqual(saved, report)
    }

    func testDepthOnlyFramesFeedTheMeshButNotTheFrameWalk() throws {
        try writeFrame(index: 1, cameraX: 0, depthMillimeters: 2000)
        for index in 0..<4 {
            try writeFrame(index: index + 1, cameraX: 0.1 + Double(index) * 0.1, depthMillimeters: 2000, folder: DepthMeshFusion.depthFramesFolder, withImage: false)
        }

        let report = try DepthMeshFusion.run(captureURL: root).get()
        XCTAssertEqual(report.framesUsed, 5)
        XCTAssertEqual(report.depthOnlyFramesUsed, 4)

        let walk = try MeshFrameIndex.load(captureURL: root).get()
        XCTAssertEqual(walk.frames.count, 1)
        XCTAssertNotNil(walk.frames.first?.imageURL)
        let depthOnly = try MeshFrameIndex.load(captureURL: root, folder: DepthMeshFusion.depthFramesFolder).get()
        XCTAssertEqual(depthOnly.frames.count, 4)
        XCTAssertTrue(depthOnly.frames.allSatisfy { $0.imageURL == nil })
    }

    func testRoomPlanDoorAndSofaLabelTheTrianglesInsideThem() throws {
        try writeWall()
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
        let elsewhere = LidarRoomBox(
            kind: "window",
            category: "window",
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 20, 1.5, 20, 1],
            dimensions: [1, 1, 0]
        )
        try JSONEncoder().encode([door, sofa, elsewhere]).write(to: root.appendingPathComponent(DepthMeshFusion.roomBoxesName))

        let report = try DepthMeshFusion.run(captureURL: root).get()
        XCTAssertEqual(report.roomBoxes, 3)
        XCTAssertEqual(report.roomBoxesMatched, 2)
        XCTAssertFalse(report.roomBoxesUnreadable)
        XCTAssertGreaterThan(report.openingFaces, 200)
        XCTAssertGreaterThan(report.objectFaces, 20)

        let classes = try readClasses()
        XCTAssertEqual(classes.filter { $0 == DepthMeshFusion.doorClass }.count, report.openingFaces)
        XCTAssertEqual(classes.filter { $0 == DepthMeshFusion.seatClass }.count, report.objectFaces)
    }

    func testFilledFloorHasItsOwnClassAndStaysInsideTheRoomPlanOutline() throws {
        try writeWall()
        let outline: [[Float]] = [[-0.5, 0, -2.5], [0.5, 0, -2.5], [0.5, 0, -1.5], [-0.5, 0, -1.5]]
        let floor = LidarRoomBox(
            kind: "floor",
            category: "floor",
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -2, 1],
            dimensions: [1, 1, 0],
            corners: outline
        )
        try JSONEncoder().encode([floor]).write(to: root.appendingPathComponent(DepthMeshFusion.roomBoxesName))

        let report = try DepthMeshFusion.run(captureURL: root).get()
        XCTAssertTrue(report.fillClippedToRoomPlan)
        XCTAssertEqual(report.roomBoxes, 0)

        let classes = try readClasses()
        XCTAssertEqual(classes.filter { $0 == DepthMeshFusion.floorClass }.count, 0)
        let vertices = try readFloats("anchor_0000.vertices")
        let faces = try Data(contentsOf: root.appendingPathComponent("mesh/anchor_0000.faces"))
        var indices = [UInt32](repeating: 0, count: faces.count / 4)
        _ = indices.withUnsafeMutableBytes { faces.copyBytes(to: $0) }
        let margin = DepthMeshFusion.fillCell
        var filled = 0
        for face in 0..<classes.count where classes[face] == DepthMeshFusion.filledFloorClass {
            filled += 1
            var centroid = SIMD2<Float>(repeating: 0)
            for corner in 0..<3 {
                let v = Int(indices[face * 3 + corner]) * 3
                centroid += SIMD2<Float>(vertices[v], vertices[v + 2]) / 3
            }
            XCTAssertTrue(centroid.x >= -0.5 - margin && centroid.x <= 0.5 + margin, "filled floor outside the outline at \(centroid)")
            XCTAssertTrue(centroid.y >= -2.5 - margin && centroid.y <= -1.5 + margin, "filled floor outside the outline at \(centroid)")
        }
        XCTAssertGreaterThan(filled, 0)
        XCTAssertGreaterThan(report.floorFilledM2, 0)
    }

    func testUnreadableRoomPlanBoxesStillBuildTheMesh() throws {
        try writeWall()
        try Data("not json".utf8).write(to: root.appendingPathComponent(DepthMeshFusion.roomBoxesName))

        let report = try DepthMeshFusion.run(captureURL: root).get()
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
        XCTAssertNil(try DepthMeshFusion.loadReport(captureURL: root).get())
    }

    func testPortraitPoseTurnsTheSensorLeftEdgeIntoScreenUp() {
        let frame = MeshFrame(
            index: 1,
            cameraTransform: matrix_identity_float4x4,
            verticalFieldOfView: 60,
            imageURL: nil,
            imageWidth: 1920,
            imageHeight: 1440,
            fx: 1373,
            fy: 1373,
            cx: 960,
            cy: 720,
            depthURL: nil,
            confidenceURL: nil,
            depthWidth: 0,
            depthHeight: 0
        )
        let up = frame.portraitPose.columns.1
        XCTAssertEqual(up.x, -1, accuracy: 1e-5)
        XCTAssertEqual(up.y, 0, accuracy: 1e-5)
        let forward = frame.portraitPose.columns.2
        XCTAssertEqual(forward.z, 1, accuracy: 1e-5)
    }
}
