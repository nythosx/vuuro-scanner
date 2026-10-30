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
    @Published private(set) var capturedStandSectors: Set<Int> = []
    private var standCellByPhotoId: [String: Int] = [:]
    @Published private(set) var standPitchDeg: Double = 0
    @Published private(set) var standMovingTooFast = false
    @Published private(set) var standTrackingLimited = false
    @Published private(set) var captureWarnings: [CaptureWarning] = []
    @Published private(set) var suggestedStandPositionLocal: CGPoint?
    @Published private(set) var standPositionsLocal: [CGPoint] = []
    var zoom: CGFloat = 1.0

    let minimumPhotos: Int
    let maximumPhotos: Int
    let roomNumber: Int

    private let arSession: ARSession
    private let roomKey: String
    let captureGroupId: String
    private let structureOriginM: [Double]?
    private let outlineMinXZ: SIMD2<Double>
    private let outlineLocal: [CGPoint]
    private let floorY: Double?
    private let sendsPose: Bool
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
    private var standTask: Task<Void, Never>?
    enum StandRow: CaseIterable {
        case horizon, up, down, zenith, nadir
    }

    enum StandInstruction: Equatable {
        case waitTracking, slowDown, levelPhone, turnSlowly, tiltUp, tiltDownLittle, turnTiltedUp, tiltDown, tiltUpLittle, turnTiltedDown, pointUp, pointDown, done
    }

    enum CaptureWarning: Equatable {
        case tooHot, gettingHot, tooDark, nearWall
    }

    private var standLastSample: (yawDeg: Double, pitchDeg: Double)?
    private var lightIsDark = false
    static let darkIntensityBelow = 200.0
    static let brightIntensityAbove = 350.0
    static let standWallClearanceM = 0.5
    static let standMinWallDistanceM = 0.8
    static let nextStandSpacingM = 2.5
    static let standGridStepM = 0.5
    static let nextStandArrivedM = 0.6
    static let standHorizonCells = 12
    static let standTiltedCells = 6
    static let standSectorTotal = standHorizonCells + 2 * standTiltedCells + 2
    private static let standSectorDeg = 30.0
    private static let standTiltedSectorDeg = 60.0
    static let standLevelLimitDeg = 15.0
    static let standTiltMinDeg = 30.0
    static let standTiltMaxDeg = 60.0
    static let standPoleDeg = 72.0
    static let standMaxStepDeg = 5.0
    static let maximumStandPhotos = standSectorTotal * 4
    static let outsideRoomToleranceM = 0.3

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
        walkthroughEnabled: Bool = false
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

        self.floorY = room.floors.first.map { Double($0.transform.columns.3.y) }
        self.sendsPose = room.floors.count == 1
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
            logDepthAvailability()
        }
        refreshStandSuggestion()
        startWalkSampling()
    }

    private func updateCaptureWarnings() {
        var warnings: [CaptureWarning] = []
        switch ProcessInfo.processInfo.thermalState {
        case .critical: warnings.append(.tooHot)
        case .serious: warnings.append(.gettingHot)
        default: break
        }
        if let intensity = arSession.currentFrame?.lightEstimate?.ambientIntensity {
            lightIsDark = Self.isDark(ambientIntensity: Double(intensity), wasDark: lightIsDark)
        }
        if lightIsDark { warnings.append(.tooDark) }
        if walkthroughEnabled, currentStandId != nil, let position = livePositionLocal(), outlineLocal.count >= 3,
           Self.distanceToOutline(position, outline: outlineLocal) < Self.standWallClearanceM {
            warnings.append(.nearWall)
        }
        if warnings != captureWarnings { captureWarnings = warnings }
    }

    private func refreshStandSuggestion() {
        guard walkthroughEnabled else { return }
        var sums: [String: (x: Double, z: Double, count: Int)] = [:]
        for photo in photos {
            guard let standId = photo.standId, photo.positionM.count >= 2 else { continue }
            let current = sums[standId] ?? (0, 0, 0)
            sums[standId] = (current.x + photo.positionM[0], current.z + photo.positionM[1], current.count + 1)
        }
        let centers = sums.values.sorted { $0.x < $1.x }.map { CGPoint(x: $0.x / Double($0.count), y: $0.z / Double($0.count)) }
        standPositionsLocal = centers
        suggestedStandPositionLocal = Self.suggestNextStand(outline: outlineLocal, stands: centers)
    }

    func nextStandGuide() -> (distanceM: Double, relativeDeg: Double)? {
        guard let target = suggestedStandPositionLocal,
              let camera = arSession.currentFrame?.camera,
              Self.isTrackingNormal(camera.trackingState) else { return nil }
        let t = camera.transform
        let dx = Double(target.x) - (Double(t.columns.3.x) - outlineMinXZ.x)
        let dz = Double(target.y) - (Double(t.columns.3.z) - outlineMinXZ.y)
        let fx = -Double(t.columns.2.x)
        let fz = -Double(t.columns.2.z)
        let relative = atan2(fx * dz - fz * dx, fx * dx + fz * dz) * 180 / .pi
        return (sqrt(dx * dx + dz * dz), relative)
    }

    static func isDark(ambientIntensity: Double, wasDark: Bool) -> Bool {
        wasDark ? ambientIntensity < brightIntensityAbove : ambientIntensity < darkIntensityBelow
    }

    static func distanceToOutline(_ p: CGPoint, outline: [CGPoint]) -> Double {
        guard outline.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in 0..<outline.count {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            let ex = b.x - a.x
            let ez = b.y - a.y
            let lengthSquared = ex * ex + ez * ez
            var u = lengthSquared > 0 ? ((p.x - a.x) * ex + (p.y - a.y) * ez) / lengthSquared : 0
            u = max(0, min(1, u))
            let cx = a.x + ex * u - p.x
            let cz = a.y + ez * u - p.y
            best = min(best, Double(sqrt(cx * cx + cz * cz)))
        }
        return best
    }

    static func isInside(_ p: CGPoint, outline: [CGPoint]) -> Bool {
        var inside = false
        var j = outline.count - 1
        for i in 0..<outline.count {
            let a = outline[i]
            let b = outline[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func suggestNextStand(outline: [CGPoint], stands: [CGPoint]) -> CGPoint? {
        guard outline.count >= 3 else { return nil }
        let minX = outline.map(\.x).min() ?? 0
        let maxX = outline.map(\.x).max() ?? 0
        let minZ = outline.map(\.y).min() ?? 0
        let maxZ = outline.map(\.y).max() ?? 0
        var best: CGPoint?
        var bestScore = -Double.infinity
        var x = minX + standGridStepM / 2
        while x < maxX {
            var z = minZ + standGridStepM / 2
            while z < maxZ {
                let p = CGPoint(x: x, y: z)
                if isInside(p, outline: outline) {
                    let wallDistance = distanceToOutline(p, outline: outline)
                    if wallDistance >= standMinWallDistanceM {
                        let nearestStand = stands.map { Double(hypot($0.x - p.x, $0.y - p.y)) }.min() ?? 0
                        let score = stands.isEmpty ? wallDistance : nearestStand
                        if score > bestScore {
                            bestScore = score
                            best = p
                        }
                    }
                }
                z += standGridStepM
            }
            x += standGridStepM
        }
        if !stands.isEmpty && bestScore < nextStandSpacingM { return nil }
        return best
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
        stopStand()
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
        updateCaptureWarnings()
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
    var wallPhotoCount: Int { photos.filter { $0.standId == nil }.count }
    var standPhotoCount: Int { photos.count - wallPhotoCount }
    var isMaximumReached: Bool { wallPhotoCount >= maximumPhotos }
    var isStandBudgetReached: Bool { standPhotoCount >= Self.maximumStandPhotos }
    var roomLocalPhotoCount: Int { photos.count }

    @discardableResult
    func capturePhoto() async -> Bool {
        guard !isCapturing else { return false }
        if currentStandId == nil {
            guard !isMaximumReached else {
                lastError = "You have taken the maximum number of photos for this room."
                return false
            }
        } else {
            guard !isStandBudgetReached else {
                lastError = "You have taken the maximum number of stand photos for this room."
                return false
            }
        }
        isCapturing = true
        defer { isCapturing = false }

        guard let frame = arSession.currentFrame else {
            lastError = "The camera is not ready yet. Try again in a moment."
            return false
        }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            lastError = "Could not read the camera frame."
            return false
        }
        let orientation = Self.imageOrientation(frame.camera.transform)
        let rawImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        let effectiveZoom = max(1.0, min(2.0, Double(zoom)))
        let image = Self.crop(rawImage, toZoom: effectiveZoom)

        let cropRawWidth = image.cgImage?.width ?? cgImage.width
        let cropRawHeight = image.cgImage?.height ?? cgImage.height
        guard let encoded = Self.downsampleAndEncode(image) else {
            lastError = "Could not encode the photo."
            return false
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
            offsetY: floorY ?? 0,
            offsetZ: outlineMinXZ.y
        )
        let rawIntrinsics = frame.camera.intrinsics
        let rawWidth = Int(frame.camera.imageResolution.width)
        let rawHeight = Int(frame.camera.imageResolution.height)
        let jpegIntrinsics = Self.jpegIntrinsics(
            fx: Double(rawIntrinsics[0][0]),
            fy: Double(rawIntrinsics[1][1]),
            cx: Double(rawIntrinsics[2][0]),
            cy: Double(rawIntrinsics[2][1]),
            rawWidth: rawWidth,
            rawHeight: rawHeight,
            cropWidth: cropRawWidth,
            cropHeight: cropRawHeight,
            jpegWidth: Int(jpegSize.width),
            jpegHeight: Int(jpegSize.height),
            orientation: orientation
        )

        var depthFile: String? = nil
        var depthWidth: Int? = nil
        var depthHeight: Int? = nil
        var depthIntrinsics: [Double]? = nil
        if standSnapshot != nil, let sceneDepth = frame.sceneDepth {
            if let extracted = Self.extractDepthData(sceneDepth) {
                do {
                    try store.saveDepth(extracted.data, localId: localId, captureGroupId: captureGroupId, roomKey: roomKey)
                    depthFile = "\(localId).depth"
                    depthWidth = extracted.width
                    depthHeight = extracted.height
                    depthIntrinsics = Self.depthIntrinsics(
                        fx: Double(rawIntrinsics[0][0]),
                        fy: Double(rawIntrinsics[1][1]),
                        cx: Double(rawIntrinsics[2][0]),
                        cy: Double(rawIntrinsics[2][1]),
                        rawWidth: rawWidth,
                        rawHeight: rawHeight,
                        depthWidth: extracted.width,
                        depthHeight: extracted.height
                    )
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
            cameraTransform: sendsPose ? localTransform : nil,
            intrinsics: sendsPose ? jpegIntrinsics : nil,
            depthFile: depthFile,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            depthIntrinsics: depthIntrinsics
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
            return true
        } catch {
            lastError = "Could not save the photo: \(error.localizedDescription)"
            return false
        }
    }

    private func logDepthAvailability() {
        let hasDepth = arSession.currentFrame?.sceneDepth != nil
        DiagnosticsLog.shared.record(
            "Photo360: \(roomKey) keeps the scan session; stand depth \(hasDepth ? "available" : "not in these frames")",
            category: .info
        )
    }

    var isOutsideRoom: Bool {
        guard outlineLocal.count >= 3, let position = livePositionLocal() else { return false }
        return !Self.isInside(position, outline: outlineLocal)
            && Self.distanceToOutline(position, outline: outlineLocal) > Self.outsideRoomToleranceM
    }

    func startStand() {
        guard walkthroughEnabled else { return }
        guard !isCapturingStand else { return }
        guard !isStandBudgetReached else {
            lastError = "You have taken the maximum number of stand photos for this room."
            return
        }
        guard !isOutsideRoom else {
            lastError = "Your position is outside this room. Walk into the room and try again. If you are already inside, go back and reopen the photo step."
            return
        }
        currentStandId = UUID().uuidString
        capturedStandSectors = []
        standCellByPhotoId = [:]
        standSectorCount = 0
        standLastSample = nil
        standMovingTooFast = false
        standTrackingLimited = false
        isCapturingStand = true
        standYawAtStart = Self.currentNormalizedYaw(arSession)
        standTask = Task { [weak self] in
            guard let self else { return }
            await self.captureStandSectorIfNew()
            while !Task.isCancelled && self.capturedStandSectors.count < Self.standSectorTotal {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
                await self.captureStandSectorIfNew()
            }
            if !Task.isCancelled && self.capturedStandSectors.count >= Self.standSectorTotal {
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
        refreshStandSuggestion()
    }

    private func captureStandSectorIfNew() async {
        guard isCapturingStand, !isCapturing else { return }
        if isStandBudgetReached {
            stopStand()
            return
        }
        guard let camera = arSession.currentFrame?.camera else { return }
        let trackingOK = Self.isTrackingNormal(camera.trackingState)
        if standTrackingLimited == trackingOK { standTrackingLimited = !trackingOK }
        guard trackingOK else { return }
        let yaw = Self.currentNormalizedYaw(arSession)
        let pitch = Self.pitchDeg(camera.transform)
        if abs(pitch - standPitchDeg) >= 2 { standPitchDeg = pitch }
        let previous = standLastSample
        standLastSample = (yaw, pitch)
        let tooFast = previous.map { Self.standStepTooLarge(from: $0, toYawDeg: yaw, toPitchDeg: pitch) } ?? true
        if standMovingTooFast != (tooFast && previous != nil) { standMovingTooFast = tooFast && previous != nil }
        if tooFast { return }
        guard let cell = Self.standCell(yawDeg: yaw, startYawDeg: standYawAtStart, pitchDeg: pitch) else { return }
        if capturedStandSectors.contains(cell) { return }
        let captured = await capturePhoto()
        guard captured, isCapturingStand else { return }
        capturedStandSectors.insert(cell)
        if let photoId = photos.last?.localId {
            standCellByPhotoId[photoId] = cell
        }
        standSectorCount = capturedStandSectors.count
    }

    var standInstruction: StandInstruction {
        if standTrackingLimited { return .waitTracking }
        if standMovingTooFast { return .slowDown }
        return Self.standInstruction(captured: capturedStandSectors, pitchDeg: standPitchDeg)
    }

    static func standStepTooLarge(from previous: (yawDeg: Double, pitchDeg: Double), toYawDeg: Double, toPitchDeg: Double) -> Bool {
        if abs(toPitchDeg) >= standPoleDeg && abs(previous.pitchDeg) >= standPoleDeg {
            return abs(toPitchDeg - previous.pitchDeg) > standMaxStepDeg
        }
        var turned = abs(toYawDeg - previous.yawDeg).truncatingRemainder(dividingBy: 360)
        if turned > 180 { turned = 360 - turned }
        turned *= cos(toPitchDeg * .pi / 180)
        return turned > standMaxStepDeg || abs(toPitchDeg - previous.pitchDeg) > standMaxStepDeg
    }

    static func standSector(yawDeg: Double, startYawDeg: Double) -> Int {
        var delta = (yawDeg - startYawDeg).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        return Int(floor(delta / standSectorDeg)) % standHorizonCells
    }

    static func standCells(_ row: StandRow) -> Range<Int> {
        switch row {
        case .horizon: return 0..<standHorizonCells
        case .up: return standHorizonCells..<(standHorizonCells + standTiltedCells)
        case .down: return (standHorizonCells + standTiltedCells)..<(standHorizonCells + 2 * standTiltedCells)
        case .zenith: return (standSectorTotal - 2)..<(standSectorTotal - 1)
        case .nadir: return (standSectorTotal - 1)..<standSectorTotal
        }
    }

    static func standCell(yawDeg: Double, startYawDeg: Double, pitchDeg: Double) -> Int? {
        if pitchDeg >= standPoleDeg { return standCells(.zenith).lowerBound }
        if pitchDeg <= -standPoleDeg { return standCells(.nadir).lowerBound }
        var delta = (yawDeg - startYawDeg).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        if abs(pitchDeg) <= standLevelLimitDeg {
            return standSector(yawDeg: yawDeg, startYawDeg: startYawDeg)
        }
        let tilted = Int(floor(delta / standTiltedSectorDeg)) % standTiltedCells
        if pitchDeg >= standTiltMinDeg && pitchDeg <= standTiltMaxDeg {
            return standCells(.up).lowerBound + tilted
        }
        if pitchDeg <= -standTiltMinDeg && pitchDeg >= -standTiltMaxDeg {
            return standCells(.down).lowerBound + tilted
        }
        return nil
    }

    static func standInstruction(captured: Set<Int>, pitchDeg: Double) -> StandInstruction {
        guard let row = StandRow.allCases.first(where: { !standCells($0).allSatisfy(captured.contains) }) else {
            return .done
        }
        switch row {
        case .horizon:
            return abs(pitchDeg) > standLevelLimitDeg ? .levelPhone : .turnSlowly
        case .up:
            if pitchDeg < standTiltMinDeg { return .tiltUp }
            if pitchDeg > standTiltMaxDeg { return .tiltDownLittle }
            return .turnTiltedUp
        case .down:
            if pitchDeg > -standTiltMinDeg { return .tiltDown }
            if pitchDeg < -standTiltMaxDeg { return .tiltUpLittle }
            return .turnTiltedDown
        case .zenith:
            return .pointUp
        case .nadir:
            return .pointDown
        }
    }

    private static func currentNormalizedYaw(_ session: ARSession) -> Double {
        guard let transform = session.currentFrame?.camera.transform else { return 0 }
        var deg = yawDeg(transform)
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg
    }

    static func localCameraTransform(_ transform: simd_float4x4, offsetX: Double, offsetY: Double, offsetZ: Double) -> [Double] {
        var result: [Double] = []
        for col in 0..<4 {
            for row in 0..<4 {
                var value = Double(transform[col][row])
                if col == 3 && row == 0 { value -= offsetX }
                else if col == 3 && row == 1 { value -= offsetY }
                else if col == 3 && row == 2 { value -= offsetZ }
                result.append(value)
            }
        }
        return result
    }

    static func jpegIntrinsics(
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        rawWidth: Int,
        rawHeight: Int,
        cropWidth: Int,
        cropHeight: Int,
        jpegWidth: Int,
        jpegHeight: Int,
        orientation: UIImage.Orientation
    ) -> [Double]? {
        guard rawWidth > 0, rawHeight > 0, cropWidth > 0, cropHeight > 0, jpegWidth > 0, jpegHeight > 0 else {
            return nil
        }
        let cw = Double(cropWidth)
        let ch = Double(cropHeight)
        let cxC = cx - (Double(rawWidth) - cw) / 2.0
        let cyC = cy - (Double(rawHeight) - ch) / 2.0
        let jw = Double(jpegWidth)
        let jh = Double(jpegHeight)
        switch orientation {
        case .up, .upMirrored:
            return [fx * jw / cw, fy * jh / ch, cxC * jw / cw, cyC * jh / ch]
        case .down, .downMirrored:
            return [fx * jw / cw, fy * jh / ch, (cw - cxC) * jw / cw, (ch - cyC) * jh / ch]
        case .right, .rightMirrored:
            return [fy * jw / ch, fx * jh / cw, (ch - cyC) * jw / ch, cxC * jh / cw]
        case .left, .leftMirrored:
            return [fy * jw / ch, fx * jh / cw, cyC * jw / ch, (cw - cxC) * jh / cw]
        @unknown default:
            return nil
        }
    }

    static func depthIntrinsics(
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        rawWidth: Int,
        rawHeight: Int,
        depthWidth: Int,
        depthHeight: Int
    ) -> [Double]? {
        guard rawWidth > 0, rawHeight > 0, depthWidth > 0, depthHeight > 0 else { return nil }
        let sx = Double(depthWidth) / Double(rawWidth)
        let sy = Double(depthHeight) / Double(rawHeight)
        return [fx * sx, fy * sy, cx * sx, cy * sy]
    }

    private static func extractDepthData(_ sceneDepth: ARDepthData) -> (data: Data, width: Int, height: Int)? {
        guard let confidence = sceneDepth.confidenceMap else { return nil }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
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
            if let cell = standCellByPhotoId.removeValue(forKey: metadata.localId) {
                capturedStandSectors.remove(cell)
                standSectorCount = capturedStandSectors.count
            }
            rebuildCoverage()
            photoCount = photos.count
            coveragePercent = coverageTracker.overallCoverage
            if metadata.standId != nil {
                refreshStandSuggestion()
            }
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

    static func pitchDeg(_ transform: simd_float4x4) -> Double {
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
