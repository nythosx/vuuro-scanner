import ARKit
import CoreImage
import Foundation
import ImageIO
import Metal
import UIKit
import os
import RoomPlan

struct LidarRoomBox: Codable, Equatable {
    var kind: String
    var category: String
    var transform: [Float]
    var dimensions: [Float]
    var corners: [[Float]]? = nil
}

struct LidarCaptureStats: Codable, Equatable {
    var frames = 0
    var depthFrames = 0
    var meshAnchors = 0
    var meshVertices = 0
    var meshFaces = 0
    var frameBytes: Int64 = 0
    var meshBytes: Int64 = 0
    var sceneDepthSeen = false
    var meshSeen = false
    var classificationSeen = false
    var worstThermalState = 0
    var lowestFreeMemoryMB = 0
    var writeFailures = 0
    var skippedBusyFrames = 0
    var depthOnlyFrames: Int?
    var depthOnlyBytes: Int64?

    var totalBytes: Int64 { frameBytes + meshBytes + (depthOnlyBytes ?? 0) }

    enum CodingKeys: String, CodingKey {
        case frames
        case depthFrames = "depth_frames"
        case meshAnchors = "mesh_anchors"
        case meshVertices = "mesh_vertices"
        case meshFaces = "mesh_faces"
        case frameBytes = "frame_bytes"
        case meshBytes = "mesh_bytes"
        case sceneDepthSeen = "scene_depth_seen"
        case meshSeen = "mesh_seen"
        case classificationSeen = "classification_seen"
        case worstThermalState = "worst_thermal_state"
        case lowestFreeMemoryMB = "lowest_free_memory_mb"
        case writeFailures = "write_failures"
        case skippedBusyFrames = "skipped_busy_frames"
        case depthOnlyFrames = "depth_only_frames"
        case depthOnlyBytes = "depth_only_bytes"
    }
}

struct LidarSessionConfigReport: Codable, Equatable {
    var sceneDepth: Bool
    var smoothedSceneDepth: Bool
    var sceneReconstruction: String

    enum CodingKeys: String, CodingKey {
        case sceneDepth = "scene_depth"
        case smoothedSceneDepth = "smoothed_scene_depth"
        case sceneReconstruction = "scene_reconstruction"
    }
}

struct LidarCaptureManifest: Codable, Equatable {
    var version = 1
    var createdAt: String
    var updatedAt: String
    var device: String
    var systemVersion: String
    var supportsSceneDepth: Bool
    var supportsMeshClassification: Bool
    var roomPlanConfig: LidarSessionConfigReport?
    var configAugmented = false
    var configAfter: LidarSessionConfigReport?
    var configNotes: [String] = []
    var roomRuns = 0
    var durationS: Double = 0
    var stats = LidarCaptureStats()

    enum CodingKeys: String, CodingKey {
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case device
        case systemVersion = "system_version"
        case supportsSceneDepth = "supports_scene_depth"
        case supportsMeshClassification = "supports_mesh_classification"
        case roomPlanConfig = "roomplan_config"
        case configAugmented = "config_augmented"
        case configAfter = "config_after"
        case configNotes = "config_notes"
        case roomRuns = "room_runs"
        case durationS = "duration_s"
        case stats
    }
}

struct LidarDepthCopy {
    let width: Int
    let height: Int
    let millimeters: Data
    let confidence: Data?
}

struct LidarKeyframe {
    let index: Int
    let image: CIImage
    let imageWidth: Int
    let imageHeight: Int
    let depth: LidarDepthCopy?
    let transform: [Float]
    let intrinsics: [Float]
    let timestamp: TimeInterval
    let tracking: String
}

struct LidarDepthFrame {
    let index: Int
    let imageWidth: Int
    let imageHeight: Int
    let depth: LidarDepthCopy
    let transform: [Float]
    let intrinsics: [Float]
    let timestamp: TimeInterval
}

struct LidarMeshAnchorCopy {
    let identifier: String
    let transform: [Float]
    let vertexCount: Int
    let faceCount: Int
    let vertices: Data
    let normals: Data?
    let faces: Data
    let classification: Data?
}

@MainActor
final class LidarCaptureRecorder {
    static let keyframeMinDistanceM: Float = 0.3
    static let keyframeMinTurnDeg: Float = 15
    static let keyframeMinIntervalS: TimeInterval = 0.25
    static let meshSnapshotIntervalS: TimeInterval = 10
    static let healthSampleIntervalS: TimeInterval = 1
    static let pollIntervalNanoseconds: UInt64 = 100_000_000
    static let framesFolder = "frames"
    static let meshFolder = "mesh"
    static let roomBoxesName = "roomplan_boxes.json"
    static let depthFramesFolder = "depth_frames"
    static let depthOnlyMinDistanceM: Float = 0.1
    static let depthOnlyMinTurnDeg: Float = 5
    static let depthOnlyMinIntervalS: TimeInterval = 0.1
    static let appleMeshExperimentKey = "lidarAppleMeshExperiment"

    private(set) var directory: URL?
    private(set) var manifest: LidarCaptureManifest?
    private weak var session: ARSession?
    private var pollTask: Task<Void, Never>?
    private var lastPose: simd_float4x4?
    private var lastKeyframeAt: TimeInterval = -.infinity
    private var lastMeshAt: TimeInterval = -.infinity
    private var lastHealthAt = Date.distantPast
    private var startedAt: Date?
    private var frameWriteInFlight = false
    private var meshWriteInFlight = false
    private var frameIndex = 0
    private var latestMeshAnchors: [ARMeshAnchor] = []
    private var lateConfigChecked = false
    private var roomBoxes: [LidarRoomBox] = []
    private var lastDepthPose: simd_float4x4?
    private var lastDepthAt: TimeInterval = -.infinity
    private var depthWriteInFlight = false
    private var depthIndex = 0
    private let writer = LidarCaptureWriter()

    func prepareSession(_ session: ARSession) {
        ensureDirectory()
        let current = session.configuration as? ARWorldTrackingConfiguration
        var notes: [String] = []
        if let current {
            manifest?.roomPlanConfig = Self.report(current)
        } else {
            notes.append("RoomPlan session has no ARWorldTrackingConfiguration: \(String(describing: session.configuration.map { type(of: $0) }))")
        }
        guard let current, let updated = current.copy() as? ARWorldTrackingConfiguration else {
            if UserDefaults.standard.bool(forKey: Self.appleMeshExperimentKey) {
                let experiment = ARWorldTrackingConfiguration()
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                    experiment.sceneReconstruction = .meshWithClassification
                }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    experiment.frameSemantics.insert(.sceneDepth)
                }
                session.run(experiment)
                manifest?.configAugmented = true
                manifest?.configAfter = Self.report(experiment)
                notes.append("Experiment on: ran a world tracking configuration with mesh and depth on the RoomPlan session")
            }
            manifest?.configNotes.append(contentsOf: notes)
            DiagnosticsLog.shared.record("LiDAR recorder: \(notes.joined(separator: "; "))", category: .state)
            persistManifest()
            return
        }
        var changed = false
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth), !updated.frameSemantics.contains(.sceneDepth) {
            updated.frameSemantics.insert(.sceneDepth)
            changed = true
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth), !updated.frameSemantics.contains(.smoothedSceneDepth) {
            updated.frameSemantics.insert(.smoothedSceneDepth)
            changed = true
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification), updated.sceneReconstruction != .meshWithClassification {
            updated.sceneReconstruction = .meshWithClassification
            changed = true
        }
        if changed {
            session.run(updated)
            manifest?.configAugmented = true
            notes.append("Added the missing depth or mesh options to RoomPlan's own configuration without resetting tracking")
        } else {
            notes.append("RoomPlan's configuration already had depth and mesh, nothing changed")
        }
        manifest?.configAfter = (session.configuration as? ARWorldTrackingConfiguration).map(Self.report)
        manifest?.configNotes.append(contentsOf: notes)
        DiagnosticsLog.shared.record("LiDAR recorder: \(notes.joined(separator: "; "))", category: .state)
        persistManifest()
    }

    func start(session: ARSession) {
        stopPolling()
        self.session = session
        ensureDirectory()
        lastPose = nil
        if startedAt == nil { startedAt = Date() }
        manifest?.roomRuns += 1
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let recorder = self else { return }
                recorder.sample()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func recordRoom(_ room: CapturedRoom) {
        guard let directory else { return }
        roomBoxes.append(contentsOf: Self.boxes(from: room))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(roomBoxes).write(to: directory.appendingPathComponent(Self.roomBoxesName), options: .atomic)
        } catch {
            manifest?.stats.writeFailures += 1
            DiagnosticsLog.shared.record("LiDAR recorder could not save the RoomPlan boxes: \(error.localizedDescription)", category: .error)
        }
    }

    static func boxes(from room: CapturedRoom) -> [LidarRoomBox] {
        var boxes: [LidarRoomBox] = []
        for door in room.doors {
            boxes.append(LidarRoomBox(kind: "door", category: "door", transform: flatten(door.transform), dimensions: [door.dimensions.x, door.dimensions.y, door.dimensions.z]))
        }
        for window in room.windows {
            boxes.append(LidarRoomBox(kind: "window", category: "window", transform: flatten(window.transform), dimensions: [window.dimensions.x, window.dimensions.y, window.dimensions.z]))
        }
        for floor in room.floors {
            let corners = CapturedRoomExporter.worldCorners(transform: floor.transform, dimensions: floor.dimensions, polygonCorners: floor.polygonCorners)
            boxes.append(LidarRoomBox(kind: "floor", category: "floor", transform: flatten(floor.transform), dimensions: [floor.dimensions.x, floor.dimensions.y, floor.dimensions.z], corners: corners.map { $0.map(Float.init) }))
        }
        for object in room.objects {
            boxes.append(LidarRoomBox(kind: "object", category: String(describing: object.category), transform: flatten(object.transform), dimensions: [object.dimensions.x, object.dimensions.y, object.dimensions.z]))
        }
        return boxes
    }

    func stop() {
        guard pollTask != nil else { return }
        stopPolling()
        if !latestMeshAnchors.isEmpty {
            snapshotMesh(latestMeshAnchors, at: Date().timeIntervalSince1970)
        }
        persistManifest()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func ensureDirectory() {
        guard directory == nil else { return }
        LidarCaptureLibrary.pruneOld()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let url = LidarCaptureLibrary.rootDirectory.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(Self.framesFolder, isDirectory: true), withIntermediateDirectories: true)
            directory = url
            let now = ISO8601DateFormatter().string(from: Date())
            manifest = LidarCaptureManifest(
                createdAt: now,
                updatedAt: now,
                device: Self.deviceModel(),
                systemVersion: UIDevice.current.systemVersion,
                supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
                supportsMeshClassification: ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            )
            manifest?.stats.lowestFreeMemoryMB = Int(os_proc_available_memory() / 1_048_576)
        } catch {
            DiagnosticsLog.shared.record("LiDAR recorder could not create its folder: \(error.localizedDescription)", category: .error)
        }
    }

    private func sample() {
        guard let session, let frame = session.currentFrame, let directory, manifest != nil else { return }
        sampleHealth()
        if !lateConfigChecked, manifest?.roomPlanConfig == nil, let configuration = session.configuration {
            lateConfigChecked = true
            manifest?.configNotes.append("RoomPlan configuration appeared during the scan: \(type(of: configuration))")
            prepareSession(session)
        }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshAnchors.isEmpty {
            latestMeshAnchors = meshAnchors
            manifest?.stats.meshSeen = true
            if meshAnchors.contains(where: { $0.geometry.classification != nil }) {
                manifest?.stats.classificationSeen = true
            }
        }
        if frame.sceneDepth != nil || frame.smoothedSceneDepth != nil {
            manifest?.stats.sceneDepthSeen = true
        }
        let now = frame.timestamp
        if !meshAnchors.isEmpty, !meshWriteInFlight, now - lastMeshAt >= Self.meshSnapshotIntervalS {
            lastMeshAt = now
            snapshotMesh(meshAnchors, at: now)
        }
        guard case .normal = frame.camera.trackingState else { return }
        sampleDepthOnly(frame, at: now, directory: directory)
        guard now - lastKeyframeAt >= Self.keyframeMinIntervalS else { return }
        let pose = frame.camera.transform
        if let lastPose, !Self.movedEnough(from: lastPose, to: pose) { return }
        guard !frameWriteInFlight else {
            manifest?.stats.skippedBusyFrames += 1
            return
        }
        lastPose = pose
        lastKeyframeAt = now
        frameIndex += 1
        let depth = (frame.sceneDepth ?? frame.smoothedSceneDepth).flatMap(Self.copyDepth)
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let keyframe = LidarKeyframe(
            index: frameIndex,
            image: CIImage(cvPixelBuffer: frame.capturedImage),
            imageWidth: Int(resolution.width),
            imageHeight: Int(resolution.height),
            depth: depth,
            transform: Self.flatten(pose),
            intrinsics: [intrinsics[0][0], intrinsics[1][1], intrinsics[2][0], intrinsics[2][1]],
            timestamp: now,
            tracking: "normal"
        )
        frameWriteInFlight = true
        let writer = self.writer
        Task { [weak self] in
            let result = await writer.writeKeyframe(keyframe, to: directory.appendingPathComponent(Self.framesFolder, isDirectory: true))
            self?.frameWriteFinished(result, hadDepth: depth != nil)
        }
    }

    private func sampleDepthOnly(_ frame: ARFrame, at now: TimeInterval, directory: URL) {
        guard now - lastDepthAt >= Self.depthOnlyMinIntervalS, !depthWriteInFlight else { return }
        let pose = frame.camera.transform
        if let lastDepthPose, !Self.movedEnough(from: lastDepthPose, to: pose, distance: Self.depthOnlyMinDistanceM, turnDeg: Self.depthOnlyMinTurnDeg) { return }
        guard let depth = (frame.sceneDepth ?? frame.smoothedSceneDepth).flatMap(Self.copyDepth) else { return }
        lastDepthPose = pose
        lastDepthAt = now
        depthIndex += 1
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let record = LidarDepthFrame(
            index: depthIndex,
            imageWidth: Int(resolution.width),
            imageHeight: Int(resolution.height),
            depth: depth,
            transform: Self.flatten(pose),
            intrinsics: [intrinsics[0][0], intrinsics[1][1], intrinsics[2][0], intrinsics[2][1]],
            timestamp: now
        )
        depthWriteInFlight = true
        let writer = self.writer
        Task { [weak self] in
            let result = await writer.writeDepthFrame(record, to: directory.appendingPathComponent(Self.depthFramesFolder, isDirectory: true))
            self?.depthWriteFinished(result)
        }
    }

    private func depthWriteFinished(_ result: Result<Int64, Error>) {
        depthWriteInFlight = false
        switch result {
        case .success(let bytes):
            manifest?.stats.depthOnlyFrames = (manifest?.stats.depthOnlyFrames ?? 0) + 1
            manifest?.stats.depthOnlyBytes = (manifest?.stats.depthOnlyBytes ?? 0) + bytes
        case .failure(let error):
            manifest?.stats.writeFailures += 1
            DiagnosticsLog.shared.record("LiDAR depth frame write failed: \(error.localizedDescription)", category: .error)
        }
    }

    private func frameWriteFinished(_ result: Result<Int64, Error>, hadDepth: Bool) {
        frameWriteInFlight = false
        switch result {
        case .success(let bytes):
            manifest?.stats.frames += 1
            if hadDepth { manifest?.stats.depthFrames += 1 }
            manifest?.stats.frameBytes += bytes
            if (manifest?.stats.frames ?? 0) % 25 == 0 { persistManifest() }
        case .failure(let error):
            manifest?.stats.writeFailures += 1
            DiagnosticsLog.shared.record("LiDAR keyframe write failed: \(error.localizedDescription)", category: .error)
        }
    }

    private func snapshotMesh(_ anchors: [ARMeshAnchor], at timestamp: TimeInterval) {
        guard let directory, !meshWriteInFlight else { return }
        let copies = anchors.compactMap(Self.copyMesh)
        guard !copies.isEmpty else { return }
        meshWriteInFlight = true
        let writer = self.writer
        Task { [weak self] in
            let result = await writer.writeMesh(copies, to: directory, folder: Self.meshFolder)
            self?.meshWriteFinished(result, copies: copies)
        }
    }

    private func meshWriteFinished(_ result: Result<Int64, Error>, copies: [LidarMeshAnchorCopy]) {
        meshWriteInFlight = false
        switch result {
        case .success(let bytes):
            manifest?.stats.meshBytes = bytes
            manifest?.stats.meshAnchors = copies.count
            manifest?.stats.meshVertices = copies.reduce(0) { $0 + $1.vertexCount }
            manifest?.stats.meshFaces = copies.reduce(0) { $0 + $1.faceCount }
            persistManifest()
        case .failure(let error):
            manifest?.stats.writeFailures += 1
            DiagnosticsLog.shared.record("LiDAR mesh write failed: \(error.localizedDescription)", category: .error)
        }
    }

    private func sampleHealth() {
        let now = Date()
        guard now.timeIntervalSince(lastHealthAt) >= Self.healthSampleIntervalS else { return }
        lastHealthAt = now
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        if thermal > (manifest?.stats.worstThermalState ?? 0) { manifest?.stats.worstThermalState = thermal }
        let freeMB = Int(os_proc_available_memory() / 1_048_576)
        if let lowest = manifest?.stats.lowestFreeMemoryMB, freeMB > 0, freeMB < lowest || lowest == 0 {
            manifest?.stats.lowestFreeMemoryMB = freeMB
        }
    }

    private func persistManifest() {
        guard let directory, var manifest else { return }
        manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
        if let startedAt { manifest.durationS = Date().timeIntervalSince(startedAt) }
        self.manifest = manifest
        let url = directory.appendingPathComponent(LidarCaptureLibrary.manifestName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            DiagnosticsLog.shared.record("LiDAR manifest write failed: \(error.localizedDescription)", category: .error)
        }
    }

    static func report(_ configuration: ARWorldTrackingConfiguration) -> LidarSessionConfigReport {
        let reconstruction: String
        switch configuration.sceneReconstruction {
        case .meshWithClassification: reconstruction = "mesh_with_classification"
        case .mesh: reconstruction = "mesh"
        default: reconstruction = configuration.sceneReconstruction.isEmpty ? "none" : "other"
        }
        return LidarSessionConfigReport(
            sceneDepth: configuration.frameSemantics.contains(.sceneDepth),
            smoothedSceneDepth: configuration.frameSemantics.contains(.smoothedSceneDepth),
            sceneReconstruction: reconstruction
        )
    }

    static func movedEnough(from last: simd_float4x4, to current: simd_float4x4, distance: Float = keyframeMinDistanceM, turnDeg: Float = keyframeMinTurnDeg) -> Bool {
        let a = SIMD3<Float>(last.columns.3.x, last.columns.3.y, last.columns.3.z)
        let b = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        if simd_distance(a, b) >= distance { return true }
        let fa = simd_normalize(-SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z))
        let fb = simd_normalize(-SIMD3<Float>(current.columns.2.x, current.columns.2.y, current.columns.2.z))
        let cosine = max(-1, min(1, simd_dot(fa, fb)))
        return acos(cosine) * 180 / .pi >= turnDeg
    }

    static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func copyDepth(_ depthData: ARDepthData) -> LidarDepthCopy? {
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(depthMap)
        var millimeters = Data(count: width * height * MemoryLayout<UInt16>.size)
        millimeters.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let output = raw.bindMemory(to: UInt16.self).baseAddress else { return }
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    let meters = row[x]
                    let value: UInt16 = meters.isFinite && meters > 0 && meters < 65.5 ? UInt16(meters * 1000) : 0
                    output[y * width + x] = value.littleEndian
                }
            }
        }
        var confidence: Data?
        if let confidenceMap = depthData.confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidenceMap) == width,
           CVPixelBufferGetHeight(confidenceMap) == height {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            if let confBase = CVPixelBufferGetBaseAddress(confidenceMap) {
                let confStride = CVPixelBufferGetBytesPerRow(confidenceMap)
                var bytes = Data(count: width * height)
                bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    guard let output = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for y in 0..<height {
                        let row = confBase.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<width {
                            output[y * width + x] = row[x]
                        }
                    }
                }
                confidence = bytes
            }
        }
        return LidarDepthCopy(width: width, height: height, millimeters: millimeters, confidence: confidence)
    }

    static func copyMesh(_ anchor: ARMeshAnchor) -> LidarMeshAnchorCopy? {
        let geometry = anchor.geometry
        let vertexSource = geometry.vertices
        let faceElement = geometry.faces
        guard vertexSource.count > 0, faceElement.count > 0, faceElement.indexCountPerPrimitive == 3 else { return nil }
        guard let vertices = copyVectors(vertexSource, components: 3) else { return nil }
        let normals = copyVectors(geometry.normals, components: 3)
        guard let faces = copyFaces(faceElement) else { return nil }
        var classification: Data?
        if let source = geometry.classification, source.count == faceElement.count {
            classification = copyBytes(source)
        }
        return LidarMeshAnchorCopy(
            identifier: anchor.identifier.uuidString,
            transform: flatten(anchor.transform),
            vertexCount: vertexSource.count,
            faceCount: faceElement.count,
            vertices: vertices,
            normals: normals,
            faces: faces,
            classification: classification
        )
    }

    private static func copyVectors(_ source: ARGeometrySource, components: Int) -> Data? {
        guard source.componentsPerVector == components, source.format == .float3 else { return nil }
        let rowBytes = components * MemoryLayout<Float>.size
        let base = source.buffer.contents().advanced(by: source.offset)
        guard source.offset + (source.count - 1) * source.stride + rowBytes <= source.buffer.length else { return nil }
        var data = Data(count: source.count * rowBytes)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let output = raw.baseAddress else { return }
            for i in 0..<source.count {
                output.advanced(by: i * rowBytes).copyMemory(from: base.advanced(by: i * source.stride), byteCount: rowBytes)
            }
        }
        return data
    }

    private static func copyFaces(_ element: ARGeometryElement) -> Data? {
        let indexCount = element.count * element.indexCountPerPrimitive
        guard indexCount * element.bytesPerIndex <= element.buffer.length else { return nil }
        let base = element.buffer.contents()
        var data = Data(count: indexCount * MemoryLayout<UInt32>.size)
        var valid = true
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let output = raw.bindMemory(to: UInt32.self).baseAddress else {
                valid = false
                return
            }
            switch element.bytesPerIndex {
            case 4:
                let input = base.assumingMemoryBound(to: UInt32.self)
                for i in 0..<indexCount { output[i] = input[i].littleEndian }
            case 2:
                let input = base.assumingMemoryBound(to: UInt16.self)
                for i in 0..<indexCount { output[i] = UInt32(input[i]).littleEndian }
            default:
                valid = false
            }
        }
        return valid ? data : nil
    }

    private static func copyBytes(_ source: ARGeometrySource) -> Data? {
        guard source.format == .uchar, source.componentsPerVector == 1 else { return nil }
        guard source.offset + (source.count - 1) * source.stride + 1 <= source.buffer.length else { return nil }
        let base = source.buffer.contents().advanced(by: source.offset).assumingMemoryBound(to: UInt8.self)
        var data = Data(count: source.count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let output = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<source.count { output[i] = base[i * source.stride] }
        }
        return data
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let model = mirror.children.compactMap { $0.value as? Int8 }.prefix { $0 != 0 }.map { Character(UnicodeScalar(UInt8(bitPattern: $0))) }
        return String(model)
    }
}

actor LidarCaptureWriter {
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func writeDepthFrame(_ record: LidarDepthFrame, to folder: URL) -> Result<Int64, Error> {
        let stem = String(format: "%06d", record.index)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var bytes = Int64(record.depth.millimeters.count)
            try record.depth.millimeters.write(to: folder.appendingPathComponent("\(stem).depth"), options: .atomic)
            var meta: [String: Any] = [
                "index": record.index,
                "timestamp": record.timestamp,
                "image_width": record.imageWidth,
                "image_height": record.imageHeight,
                "image_orientation": "sensor_landscape",
                "camera_transform": record.transform.map(Double.init),
                "intrinsics_fx_fy_cx_cy": record.intrinsics.map(Double.init),
                "tracking": "normal",
                "depth": "\(stem).depth",
                "depth_format": "uint16_le_millimeters",
                "depth_width": record.depth.width,
                "depth_height": record.depth.height
            ]
            if let confidence = record.depth.confidence {
                try confidence.write(to: folder.appendingPathComponent("\(stem).conf"), options: .atomic)
                bytes += Int64(confidence.count)
                meta["confidence"] = "\(stem).conf"
                meta["confidence_format"] = "uint8_arconfidence_0_low_1_medium_2_high"
            }
            let json = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            try json.write(to: folder.appendingPathComponent("\(stem).json"), options: .atomic)
            return .success(bytes + Int64(json.count))
        } catch {
            return .failure(error)
        }
    }

    func writeKeyframe(_ keyframe: LidarKeyframe, to framesDirectory: URL) -> Result<Int64, Error> {
        let stem = String(format: "%06d", keyframe.index)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: keyframe.image, colorSpace: colorSpace, options: options) else {
            return .failure(PlainError(message: "Could not encode keyframe \(stem) as JPEG"))
        }
        do {
            var bytes = Int64(jpeg.count)
            try jpeg.write(to: framesDirectory.appendingPathComponent("\(stem).jpg"), options: .atomic)
            var meta: [String: Any] = [
                "index": keyframe.index,
                "timestamp": keyframe.timestamp,
                "image": "\(stem).jpg",
                "image_width": keyframe.imageWidth,
                "image_height": keyframe.imageHeight,
                "image_orientation": "sensor_landscape",
                "camera_transform": keyframe.transform.map(Double.init),
                "intrinsics_fx_fy_cx_cy": keyframe.intrinsics.map(Double.init),
                "tracking": keyframe.tracking
            ]
            if let depth = keyframe.depth {
                try depth.millimeters.write(to: framesDirectory.appendingPathComponent("\(stem).depth"), options: .atomic)
                bytes += Int64(depth.millimeters.count)
                meta["depth"] = "\(stem).depth"
                meta["depth_format"] = "uint16_le_millimeters"
                meta["depth_width"] = depth.width
                meta["depth_height"] = depth.height
                if let confidence = depth.confidence {
                    try confidence.write(to: framesDirectory.appendingPathComponent("\(stem).conf"), options: .atomic)
                    bytes += Int64(confidence.count)
                    meta["confidence"] = "\(stem).conf"
                    meta["confidence_format"] = "uint8_arconfidence_0_low_1_medium_2_high"
                }
            }
            let json = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            try json.write(to: framesDirectory.appendingPathComponent("\(stem).json"), options: .atomic)
            bytes += Int64(json.count)
            return .success(bytes)
        } catch {
            return .failure(error)
        }
    }

    func writeMesh(_ anchors: [LidarMeshAnchorCopy], to captureDirectory: URL, folder: String) -> Result<Int64, Error> {
        let fileManager = FileManager.default
        let target = captureDirectory.appendingPathComponent(folder, isDirectory: true)
        let staging = captureDirectory.appendingPathComponent(folder + ".tmp", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            var bytes: Int64 = 0
            var index: [[String: Any]] = []
            for (i, anchor) in anchors.enumerated() {
                let stem = String(format: "anchor_%04d", i)
                try anchor.vertices.write(to: staging.appendingPathComponent("\(stem).vertices"))
                try anchor.faces.write(to: staging.appendingPathComponent("\(stem).faces"))
                bytes += Int64(anchor.vertices.count + anchor.faces.count)
                var entry: [String: Any] = [
                    "identifier": anchor.identifier,
                    "file_stem": stem,
                    "transform": anchor.transform.map(Double.init),
                    "vertex_count": anchor.vertexCount,
                    "face_count": anchor.faceCount,
                    "vertices_format": "float32_le_xyz",
                    "faces_format": "uint32_le_triangles"
                ]
                if let normals = anchor.normals {
                    try normals.write(to: staging.appendingPathComponent("\(stem).normals"))
                    bytes += Int64(normals.count)
                    entry["normals_format"] = "float32_le_xyz"
                }
                if let classification = anchor.classification {
                    try classification.write(to: staging.appendingPathComponent("\(stem).classes"))
                    bytes += Int64(classification.count)
                    entry["classes_format"] = "uint8_per_face_armeshclassification"
                }
                index.append(entry)
            }
            let json = try JSONSerialization.data(withJSONObject: ["anchors": index], options: [.prettyPrinted, .sortedKeys])
            try json.write(to: staging.appendingPathComponent("anchors.json"))
            bytes += Int64(json.count)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: staging, to: target)
            return .success(bytes)
        } catch {
            return .failure(error)
        }
    }
}
