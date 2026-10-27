import ARKit
import CoreImage
import Foundation
import RoomPlan
import UIKit
import simd

@MainActor
final class RoomPhotoCaptureCoordinator: ObservableObject {
    @Published private(set) var photoCount: Int = 0
    @Published private(set) var coveragePercent: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var isTrackingLimited: Bool = false
    @Published private(set) var isHeldSideways: Bool = false
    private var lastTrackedPosition: CGPoint?
    @Published private(set) var isCapturingStand: Bool = false
    @Published private(set) var standSectorCount: Int = 0
    var zoom: CGFloat = 1.0

    let minimumPhotos: Int
    let maximumPhotos: Int
    let roomNumber: Int

    private let arSession: ARSession
    private let roomKey: String
    private let captureGroupId: String
    private let structureOriginM: [Double]?
    private let outlineMinXZ: SIMD2<Double>
    private let outlineLocal: [CGPoint]
    private let initialCameraYawDeg: Double?
    private let initialCompassHeadingDeg: Double?
    private let store: RoomPhotoStore
    private let ciContext = CIContext()
    private var walkSamplingTask: Task<Void, Never>?
    private var walkPaths: [[[Double]]] = []
    private var unsavedWalkSamples = 0
    static let walkSampleSpacingM = 0.25
    static let walkSaveEverySamples = 8

    private var coverageTracker: RoomPhotoCoverageTracker
    private(set) var photos: [RoomPhotoMetadata] = []
    private let walkthroughEnabled: Bool
    private var currentStandId: String? = nil
    private var standYawAtStart: Double = 0
    private var standCapturedSectors: Set<Int> = []
    nonisolated(unsafe) private var standTask: Task<Void, Never>?
    private static let standSectorCount = 12
    private static let standSectorDeg = 30.0

    var session: ARSession { arSession }
    var coverage: RoomPhotoCoverage { coverageTracker.coverage }

    init(
        arSession: ARSession,
        room: CapturedRoom,
        roomNumber: Int,
        roomKey: String,
        captureGroupId: String,
        structureOriginM: [Double]?,
        initialCompassHeadingDeg: Double?,
        initialCameraYawDeg: Double?,
        store: RoomPhotoStore,
        minimumPhotos: Int = 15,
        maximumPhotos: Int = 60,
        walkthroughEnabled: Bool = false,
        initialWorldMap: ARWorldMap? = nil
    ) {
        self.walkthroughEnabled = walkthroughEnabled
        self.arSession = arSession
        self.roomNumber = roomNumber
        self.roomKey = roomKey
        self.captureGroupId = captureGroupId
        self.structureOriginM = structureOriginM
        self.initialCompassHeadingDeg = initialCompassHeadingDeg
        self.initialCameraYawDeg = initialCameraYawDeg
        self.store = store
        self.minimumPhotos = minimumPhotos
        self.maximumPhotos = maximumPhotos

        if let floor = room.floors.first {
            let transform = floor.transform
            let corners = floor.polygonCorners
            if corners.isEmpty {
                self.outlineMinXZ = .zero
                self.outlineLocal = []
            } else {
                let worldCorners = corners.map { transform * simd_float4($0, 1) }
                let minX = worldCorners.map { $0.x }.min() ?? 0
                let minZ = worldCorners.map { $0.z }.min() ?? 0
                self.outlineMinXZ = SIMD2<Double>(Double(minX), Double(minZ))
                self.outlineLocal = worldCorners.map {
                    CGPoint(x: Double($0.x) - Double(minX), y: Double($0.z) - Double(minZ))
                }
            }
        } else {
            self.outlineMinXZ = .zero
            self.outlineLocal = []
        }

        self.coverageTracker = RoomPhotoCoverageTracker(
            outline: self.outlineLocal,
            roomHeadingDeg: Self.coverageReferenceDeg(
                compassHeadingDeg: initialCompassHeadingDeg,
                cameraYawAtStartDeg: initialCameraYawDeg
            )
        )

        loadExistingPhotos()
        loadExistingWalk()
        if walkthroughEnabled {
            enableDepthIfAvailable(initialWorldMap: initialWorldMap)
        }
        startWalkSampling()
    }

    var finishCoverage: RoomPhotoFinishCoverage {
        RoomPhotoFinishCoverage(
            overall: coverageTracker.overallCoverage,
            position: coverageTracker.walkablePositionCoverage,
            walls: coverageTracker.wallCoverage,
            ready: coverageTracker.isReadyToFinish,
            wallsTotal: coverageTracker.totalWallCount,
            wallsCovered: coverageTracker.coveredWallCount,
            cellsTotal: coverageTracker.totalCellCount,
            cellsCovered: coverageTracker.coveredCellCount
        )
    }

    func recordFinishCoverage() {
        do {
            try store.saveFinishCoverage(finishCoverage, captureGroupId: captureGroupId, roomKey: roomKey)
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: could not save coverage at Finish for \(roomKey): \(error.localizedDescription)",
                category: .error
            )
        }
    }

    func stopWalkSampling() {
        walkSamplingTask?.cancel()
        walkSamplingTask = nil
        saveWalkPaths()
    }

    private func startWalkSampling() {
        walkSamplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.sampleWalkPosition()
            }
        }
    }

    private func sampleWalkPosition() {
        guard let camera = arSession.currentFrame?.camera else { return }
        let limited = !Self.isTrackingNormal(camera.trackingState)
        if isTrackingLimited != limited {
            isTrackingLimited = limited
            if limited {
                coverageTracker.endWalkSegment()
                if walkPaths.last?.isEmpty == false {
                    walkPaths.append([])
                }
            }
        }
        let sideways = Self.isHeldSideways(Self.imageOrientation(camera.transform))
        if isHeldSideways != sideways {
            isHeldSideways = sideways
        }
        guard !limited, let position = livePositionLocal() else { return }
        let before = coverageTracker.coveredCellCount
        coverageTracker.recordWalk(positionM: position)
        appendWalkSample(position)
        if coverageTracker.coveredCellCount != before {
            coveragePercent = coverageTracker.overallCoverage
            saveWalkPaths()
        } else if unsavedWalkSamples >= Self.walkSaveEverySamples {
            saveWalkPaths()
        }
    }

    private func appendWalkSample(_ position: CGPoint) {
        let point = [Double(position.x), Double(position.y)]
        guard var segment = walkPaths.last else {
            walkPaths = [[point]]
            unsavedWalkSamples += 1
            return
        }
        if let last = segment.last, hypot(point[0] - last[0], point[1] - last[1]) < Self.walkSampleSpacingM {
            return
        }
        segment.append(point)
        walkPaths[walkPaths.count - 1] = segment
        unsavedWalkSamples += 1
    }

    private func saveWalkPaths() {
        guard unsavedWalkSamples > 0 else { return }
        do {
            try store.saveWalkPaths(walkPaths, captureGroupId: captureGroupId, roomKey: roomKey)
            unsavedWalkSamples = 0
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: could not save the walked area for \(roomKey): \(error.localizedDescription)",
                category: .error
            )
        }
    }

    private func loadExistingWalk() {
        let saved = store.loadWalkPaths(captureGroupId: captureGroupId, roomKey: roomKey)
        for segment in saved {
            for point in segment where point.count >= 2 {
                coverageTracker.recordWalk(positionM: CGPoint(x: point[0], y: point[1]))
            }
            coverageTracker.endWalkSegment()
        }
        walkPaths = saved.filter { !$0.isEmpty } + [[]]
        coveragePercent = coverageTracker.overallCoverage
    }

    var isMinimumReached: Bool { photos.count >= minimumPhotos }
    var isMaximumReached: Bool { photos.count >= maximumPhotos }
    var roomLocalPhotoCount: Int { photos.count }

    func capturePhoto() async {
        guard !isCapturing else { return }
        guard photos.count < maximumPhotos else {
            lastError = "You have taken the maximum number of photos for this room."
            return
        }
        isCapturing = true
        defer { isCapturing = false }

        guard let frame = arSession.currentFrame else {
            lastError = "The camera is not ready yet. Try again in a moment."
            return
        }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            lastError = "Could not read the camera frame."
            return
        }
        let rawImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: Self.imageOrientation(frame.camera.transform))
        let effectiveZoom = max(1.0, min(2.0, Double(zoom)))
        let image = Self.crop(rawImage, toZoom: effectiveZoom)

        let croppedSize = image.size
        guard let encoded = Self.downsampleAndEncode(image) else {
            lastError = "Could not encode the photo."
            return
        }
        let jpegData = encoded.data
        let jpegSize = encoded.size

        let t = frame.camera.transform.columns.3
        let worldX = Double(t.x)
        let worldZ = Double(t.z)
        let localX = worldX - outlineMinXZ.x
        let localZ = worldZ - outlineMinXZ.y

        let currentYaw = Self.yawDeg(frame.camera.transform)
        let headingDeg = Self.headingDeg(
            compassHeadingDeg: initialCompassHeadingDeg,
            cameraYawAtStartDeg: initialCameraYawDeg,
            cameraYawAtShutterDeg: currentYaw
        )

        let pitchDeg = Self.pitchDeg(frame.camera.transform)

        let localId = UUID().uuidString
        let standSnapshot = currentStandId
        let localTransform = Self.localCameraTransform(
            frame.camera.transform,
            offsetX: outlineMinXZ.x,
            offsetZ: outlineMinXZ.y
        )
        let jpegIntrinsics = Self.jpegIntrinsics(
            camera: frame.camera,
            rawWidth: Int(frame.camera.imageResolution.width),
            rawHeight: Int(frame.camera.imageResolution.height),
            cropWidth: Int(croppedSize.width),
            cropHeight: Int(croppedSize.height),
            jpegWidth: Int(jpegSize.width),
            jpegHeight: Int(jpegSize.height)
        )

        var depthFile: String? = nil
        var depthWidth: Int? = nil
        var depthHeight: Int? = nil
        if standSnapshot != nil, let sceneDepth = frame.sceneDepth {
            if let extracted = Self.extractDepthData(sceneDepth) {
                do {
                    try store.saveDepth(extracted.data, localId: localId, captureGroupId: captureGroupId, roomKey: roomKey)
                    depthFile = "\(localId).depth"
                    depthWidth = extracted.width
                    depthHeight = extracted.height
                } catch {
                    DiagnosticsLog.shared.record("stand depth write failed: \(error.localizedDescription)", category: .error)
                }
            } else {
                DiagnosticsLog.shared.record("stand depth extraction failed", category: .error)
            }
        }

        let metadata = RoomPhotoMetadata(
            localId: localId,
            capturedAt: Date(),
            positionM: [localX, localZ],
            headingDeg: headingDeg,
            pitchDeg: pitchDeg,
            zoom: effectiveZoom,
            standId: standSnapshot,
            cameraTransform: standSnapshot != nil ? localTransform : nil,
            intrinsics: standSnapshot != nil ? jpegIntrinsics : nil,
            depthFile: depthFile,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )

        do {
            try store.savePhoto(
                jpegData,
                metadata: metadata,
                captureGroupId: captureGroupId,
                roomKey: roomKey,
                structureOriginM: structureOriginM
            )
            photos.append(metadata)
            coverageTracker.record(
                positionM: CGPoint(x: localX, y: localZ),
                cameraHeadingDeg: headingDeg
            )
            photoCount = photos.count
            coveragePercent = coverageTracker.overallCoverage
            lastError = nil
        } catch {
            lastError = "Could not save the photo: \(error.localizedDescription)"
        }
    }

    func enableDepthIfAvailable(initialWorldMap: ARWorldMap?) {
        guard walkthroughEnabled else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            DiagnosticsLog.shared.record("sceneDepth not supported on this device; stand depth disabled", category: .info)
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        if let map = initialWorldMap {
            configuration.initialWorldMap = map
        }
        arSession.run(configuration, options: [])
    }

    func startStand() {
        guard walkthroughEnabled else { return }
        guard !isCapturingStand else { return }
        currentStandId = UUID().uuidString
        standCapturedSectors = []
        standSectorCount = 0
        isCapturingStand = true
        standYawAtStart = Self.currentNormalizedYaw(arSession)
        standTask = Task { [weak self] in
            guard let self else { return }
            await self.captureStandSectorIfNew()
            while !Task.isCancelled && self.standCapturedSectors.count < Self.standSectorCount {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
                await self.captureStandSectorIfNew()
            }
            if !Task.isCancelled && self.standCapturedSectors.count >= Self.standSectorCount {
                self.stopStand()
            }
        }
    }

    func stopStand() {
        standTask?.cancel()
        standTask = nil
        if isCapturingStand {
            isCapturingStand = false
        }
        currentStandId = nil
    }

    private func captureStandSectorIfNew() async {
        guard isCapturingStand, !isCapturing else { return }
        if photos.count >= maximumPhotos {
            stopStand()
            return
        }
        let yaw = Self.currentNormalizedYaw(arSession)
        var delta = (yaw - standYawAtStart).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        let sector = Int(floor(delta / Self.standSectorDeg)) % Self.standSectorCount
        if standCapturedSectors.contains(sector) { return }
        standCapturedSectors.insert(sector)
        standSectorCount = standCapturedSectors.count
        await capturePhoto()
    }

    private static func currentNormalizedYaw(_ session: ARSession) -> Double {
        guard let transform = session.currentFrame?.camera.transform else { return 0 }
        var deg = yawDeg(transform)
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg
    }

    private static func localCameraTransform(_ transform: simd_float4x4, offsetX: Double, offsetZ: Double) -> [Double] {
        var result: [Double] = []
        for col in 0..<4 {
            for row in 0..<4 {
                var value = Double(transform[col][row])
                if col == 3 && row == 0 { value -= offsetX }
                else if col == 3 && row == 2 { value -= offsetZ }
                result.append(value)
            }
        }
        return result
    }

    private static func jpegIntrinsics(
        camera: ARCamera,
        rawWidth: Int,
        rawHeight: Int,
        cropWidth: Int,
        cropHeight: Int,
        jpegWidth: Int,
        jpegHeight: Int
    ) -> [Double]? {
        guard rawWidth > 0, rawHeight > 0, cropWidth > 0, cropHeight > 0, jpegWidth > 0, jpegHeight > 0 else {
            return nil
        }
        let intrinsics = camera.intrinsics
        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        let cx = Double(intrinsics[2][0])
        let cy = Double(intrinsics[2][1])
        let cropX = (Double(rawWidth) - Double(cropWidth)) / 2.0
        let cropY = (Double(rawHeight) - Double(cropHeight)) / 2.0
        let cxC = cx - cropX
        let cyC = cy - cropY
        let fxD = fy
        let fyD = fx
        let cxD = Double(cropHeight) - cyC
        let cyD = cxC
        let scaleX = Double(jpegWidth) / Double(cropHeight)
        let scaleY = Double(jpegHeight) / Double(cropWidth)
        return [fxD * scaleX, fyD * scaleY, cxD * scaleX, cyD * scaleY]
    }

    private static func extractDepthData(_ sceneDepth: ARDepthData) -> (data: Data, width: Int, height: Int)? {
        guard let confidence = sceneDepth.confidenceMap else { return nil }
        let depthMap = sceneDepth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height else {
            return nil
        }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase = CVPixelBufferGetBaseAddress(confidence) else {
            return nil
        }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confStride = CVPixelBufferGetBytesPerRow(confidence)
        let highLevel = UInt8(ARConfidenceLevel.high.rawValue)
        var data = Data(count: width * height * MemoryLayout<UInt16>.size)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let output = raw.bindMemory(to: UInt16.self).baseAddress else { return }
            for y in 0..<height {
                let depthRow = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
                let confRow = confBase.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let isHigh = confRow[x] == highLevel
                    let meters = depthRow[x]
                    let millimeters: UInt16
                    if isHigh && meters.isFinite && meters > 0 && meters < 65.5 {
                        millimeters = UInt16(meters * 1000)
                    } else {
                        millimeters = 0
                    }
                    output[y * width + x] = millimeters.littleEndian
                }
            }
        }
        return (data, width, height)
    }

    private var thumbnailCache: [String: UIImage] = [:]

    func loadThumbnail(_ metadata: RoomPhotoMetadata) -> UIImage? {
        if let cached = thumbnailCache[metadata.localId] {
            return cached
        }
        guard let data = try? store.loadPhotoData(
            localId: metadata.localId,
            captureGroupId: captureGroupId,
            roomKey: roomKey
        ) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        thumbnailCache[metadata.localId] = image
        return image
    }

    func deletePhoto(_ metadata: RoomPhotoMetadata) {
        do {
            try store.deletePhoto(
                localId: metadata.localId,
                captureGroupId: captureGroupId,
                roomKey: roomKey
            )
            photos.removeAll { $0.localId == metadata.localId }
            thumbnailCache.removeValue(forKey: metadata.localId)
            rebuildCoverage()
            photoCount = photos.count
            coveragePercent = coverageTracker.overallCoverage
            lastError = nil
        } catch {
            lastError = "Could not delete the photo: \(error.localizedDescription)"
        }
    }

    func liveHeadingDeg() -> Double? {
        guard let currentYaw = Self.cameraYawDeg(from: arSession) else { return nil }
        return Self.headingDeg(
            compassHeadingDeg: initialCompassHeadingDeg,
            cameraYawAtStartDeg: initialCameraYawDeg,
            cameraYawAtShutterDeg: currentYaw
        )
    }

    func livePositionLocal() -> CGPoint? {
        guard let camera = arSession.currentFrame?.camera else { return lastTrackedPosition }
        guard Self.isTrackingNormal(camera.trackingState) else { return lastTrackedPosition }
        let t = camera.transform.columns.3
        let position = CGPoint(
            x: Double(t.x) - outlineMinXZ.x,
            y: Double(t.z) - outlineMinXZ.y
        )
        lastTrackedPosition = position
        return position
    }

    static func isTrackingNormal(_ state: ARCamera.TrackingState) -> Bool {
        if case .normal = state { return true }
        return false
    }

    static func isHeldSideways(_ orientation: UIImage.Orientation) -> Bool {
        orientation == .up || orientation == .down
    }

    static func cameraYawDeg(from session: ARSession) -> Double? {
        guard let transform = session.currentFrame?.camera.transform else { return nil }
        return yawDeg(transform)
    }

    static func coverageReferenceDeg(compassHeadingDeg: Double?, cameraYawAtStartDeg: Double?) -> Double {
        guard let compassHeadingDeg else { return 270 }
        var raw = 270 + compassHeadingDeg - (cameraYawAtStartDeg ?? 0)
        raw = raw.truncatingRemainder(dividingBy: 360)
        if raw < 0 { raw += 360 }
        return raw
    }

    static func headingDeg(
        compassHeadingDeg: Double?,
        cameraYawAtStartDeg: Double?,
        cameraYawAtShutterDeg: Double
    ) -> Double {
        if let base = compassHeadingDeg {
            let delta = cameraYawAtStartDeg.map { cameraYawAtShutterDeg - $0 } ?? 0
            var raw = base + delta
            raw = raw.truncatingRemainder(dividingBy: 360)
            if raw < 0 { raw += 360 }
            return raw
        }
        var raw = cameraYawAtShutterDeg.truncatingRemainder(dividingBy: 360)
        if raw < 0 { raw += 360 }
        return raw
    }

    private func loadExistingPhotos() {
        guard let manifest = try? store.loadManifest(captureGroupId: captureGroupId, roomKey: roomKey) else {
            return
        }
        photos = manifest.photos
        photoCount = photos.count
        rebuildCoverage()
        coveragePercent = coverageTracker.overallCoverage
    }

    private func rebuildCoverage() {
        coverageTracker.reset()
        for photo in photos {
            guard photo.positionM.count >= 2 else { continue }
            coverageTracker.record(
                positionM: CGPoint(x: photo.positionM[0], y: photo.positionM[1]),
                cameraHeadingDeg: photo.headingDeg
            )
        }
    }

    static func yawDeg(_ transform: simd_float4x4) -> Double {
        let forward = transform.columns.2
        return atan2(Double(forward.z), Double(forward.x)) * 180.0 / .pi
    }

    static func imageOrientation(_ transform: simd_float4x4) -> UIImage.Orientation {
        let upAlongImageX = Double(transform.columns.0.y)
        let upAlongImageY = Double(transform.columns.1.y)
        if abs(upAlongImageY) > abs(upAlongImageX) {
            return upAlongImageY >= 0 ? .up : .down
        }
        return upAlongImageX <= 0 ? .right : .left
    }

    private static func pitchDeg(_ transform: simd_float4x4) -> Double {
        let forward = transform.columns.2
        let y = max(-1.0, min(1.0, Double(-forward.y)))
        return asin(y) * 180.0 / .pi
    }

    private static func crop(_ image: UIImage, toZoom zoom: Double) -> UIImage {
        guard zoom > 1.001, let cg = image.cgImage else { return image }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let cropWidth = width / CGFloat(zoom)
        let cropHeight = height / CGFloat(zoom)
        let cropRect = CGRect(
            x: (width - cropWidth) / 2,
            y: (height - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        )
        guard let cropped = cg.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static let maxEdge: CGFloat = 4096
    private static let jpegQuality: CGFloat = 0.85

    private static func downsampleAndEncode(_ image: UIImage) -> (data: Data, size: CGSize)? {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let targetSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = rendered.jpegData(compressionQuality: jpegQuality) else { return nil }
        return (data, targetSize)
    }
}
