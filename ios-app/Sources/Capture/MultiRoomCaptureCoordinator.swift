import ARKit
import Combine
import Foundation
import RoomPlan
import simd

@MainActor
final class MultiRoomCaptureCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case scanning
        case roomFinished(roomAvailable: Bool)
        case failed(String, partialRoomAvailable: Bool)
        case merging
        case unitFinished
        case mergeFailed(String)
        case mergeTimedOut
        case mergeCancelled
    }

    private struct MergeTimeoutError: Error {}

    static let roomCountWarningThreshold = 8

    @Published private(set) var state: State = .scanning {
        didSet {
            DiagnosticsLog.shared.record("Multi-room capture state -> \(state)", category: .state)
        }
    }

    @Published private(set) var liveStats: CaptureLiveStats = .empty
    @Published private(set) var capturedRooms: [CapturedRoom] = []
    @Published private(set) var roomTypeConfirmations: [RoomTypeConfirmation?] = []

    @Published private(set) var isApproachingSizeLimit = false {
        didSet {
            guard oldValue != isApproachingSizeLimit else { return }
            DiagnosticsLog.shared.record("Room size warning (multi-room) -> \(isApproachingSizeLimit)", category: .state)
        }
    }

    @Published private(set) var liveRoomTypeGuess: RoomTypeClassifier.Guess?
    @Published private(set) var hasAnsweredRoomType: Bool = false
    private(set) var roomTypeConfirmation: String?
    private(set) var roomTypeConfirmedForGuessType: String?
    private(set) var roomCustomName: String?

    var roomTypeConfirmationForExport: RoomTypeConfirmation? {
        roomTypeConfirmation.map { RoomTypeConfirmation(value: $0, answeredForGuessType: roomTypeConfirmedForGuessType, customName: roomCustomName) }
    }

    func nameRoom(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty else { return }
        roomTypeConfirmation = "other"
        roomCustomName = trimmed
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        hasAnsweredRoomType = true
        DiagnosticsLog.shared.record("Room named (multi-room): \(trimmed)", category: .info)
    }

    func confirmRoomTypeGuess() {
        roomCustomName = nil
        roomTypeConfirmation = liveRoomTypeGuess?.type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        hasAnsweredRoomType = true
        DiagnosticsLog.shared.record("Room type confirmed (multi-room): \(liveRoomTypeGuess?.type ?? "nil")", category: .info)
    }

    func rejectRoomTypeGuess(correctedTo type: String?) {
        roomCustomName = nil
        roomTypeConfirmation = type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        liveUpdateThrottle.markRoomTypeAnswered()
        hasAnsweredRoomType = true
        DiagnosticsLog.shared.record("Room type corrected (multi-room): guess=\(liveRoomTypeGuess?.type ?? "nil") -> \(type ?? "nil")", category: .info)
    }

    private(set) var pendingPartialRoom: CapturedRoom?
    private var pendingPartialRoomWalkPath: [[Double]] = []
    private(set) var mergedStructure: CapturedStructure?
    private(set) var roomWalkPaths: [[[Double]]] = []
    private(set) var roomFloors: [String] = []
    var currentFloor: String = ""
    private var currentRoomWalkPath: [[Double]] = []
    nonisolated(unsafe) private var walkPathTask: Task<Void, Never>?
    private static let walkPathSampleIntervalNanoseconds: UInt64 = 500_000_000
    private static let walkPathMaxPoints = 400

    static let mergeTimeoutSeconds: Double = 45
    nonisolated(unsafe) private var mergeTask: Task<Void, Never>?
    nonisolated(unsafe) private var heartbeatTask: Task<Void, Never>?

    deinit {
        walkPathTask?.cancel()
        mergeTask?.cancel()
        heartbeatTask?.cancel()
    }

    let arSession = ARSession()
    private var captureSession: RoomCaptureSession?
    private let liveUpdateThrottle = RoomLiveUpdateThrottle()
    private let viewDelegate = RoomCaptureScreenViewDelegate()
    private var pendingRun = false
    private var isRunning = false
    private var cameraWatchdog: Task<Void, Never>?
    @Published private(set) var cameraFeedMissing = false

    lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = viewDelegate
        view.captureSession.delegate = self
        captureSession = view.captureSession
        return view
    }()

    func captureViewWindowDidChange() {
        runIfReady()
    }

    func tearDownIfDetached() {
        guard captureView.window == nil else { return }
        cameraWatchdog?.cancel()
        pendingRun = false
        stopWalkPathTracking()
        if isRunning {
            isRunning = false
            captureSession?.stop(pauseARSession: false)
        }
        arSession.pause()
        DiagnosticsLog.shared.record("Multi-room capture view left the screen — capture session stopped and AR session paused", category: .state)
    }

    private func runIfReady() {
        guard pendingRun, captureView.window != nil, let captureSession else { return }
        pendingRun = false
        isRunning = true
        logTrackingAndMapping(label: "before captureSession.run")
        DiagnosticsLog.shared.record("Multi-room capture session running (view is on screen)", category: .state)
        captureSession.run(configuration: RoomCaptureSession.Configuration())
        logTrackingAndMapping(label: "after captureSession.run")
        startCameraWatchdog()
    }

    private func logTrackingAndMapping(label: String) {
        let tracking = arSession.currentFrame.map { String(describing: $0.camera.trackingState) } ?? "no current frame"
        let mapping = arSession.currentFrame.map { String(describing: $0.worldMappingStatus) } ?? "no current frame"
        DiagnosticsLog.shared.record("AR state \(label): tracking=\(tracking), mapping=\(mapping)", category: .state)
    }

    func saveWorldMap(sessionId: String, groupId: String) async {
        guard arSession.currentFrame != nil else {
            DiagnosticsLog.shared.record("World map save skipped: no current AR frame", category: .info)
            return
        }
        let status = arSession.currentFrame?.worldMappingStatus
        DiagnosticsLog.shared.record("World mapping status before save: \(String(describing: status))", category: .state)
        guard status == .mapped || status == .extending else {
            DiagnosticsLog.shared.record("World map save skipped: mapping status is \(String(describing: status))", category: .info)
            return
        }
        do {
            let session = arSession
            let map: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
                session.getCurrentWorldMap { map, error in
                    if let map {
                        continuation.resume(returning: map)
                    } else {
                        continuation.resume(throwing: error ?? PlainError(message: "ARKit returned no world map"))
                    }
                }
            }
            _ = WorldMapStore.shared.save(map, sessionId: sessionId, groupId: groupId)
        } catch {
            DiagnosticsLog.shared.record("World map save failed: \(error.localizedDescription)", category: .error)
        }
    }

    private func startCameraWatchdog() {
        cameraWatchdog?.cancel()
        cameraWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.isRunning, self.state == .scanning else { return }
            if self.arSession.currentFrame == nil {
                DiagnosticsLog.shared.record("No camera frame 8s after the multi-room capture session started — surfacing an error", category: .error)
                self.cameraFeedMissing = true
            }
        }
    }

    enum RelocalizationState: Equatable {
        case idle
        case relocalizing
        case recognised
        case timedOut
        case unavailable
        case relocalizedButCaptureFailed
    }

    private var wasRelocalized = false

    @Published private(set) var relocalizationState: RelocalizationState = .idle
    nonisolated(unsafe) private var relocalizationPollTask: Task<Void, Never>?
    private static let relocalizationTimeoutSeconds: Double = 45
    private static let relocalizationPollIntervalNanoseconds: UInt64 = 250_000_000

    func startRelocalizing(with map: ARWorldMap) {
        guard ARWorldTrackingConfiguration.isSupported else {
            relocalizationState = .unavailable
            return
        }
        #if DEBUG
        if FakeLidarMode.isEnabled {
            relocalizationState = .unavailable
            return
        }
        #endif
        relocalizationState = .relocalizing
        wasRelocalized = true
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = map
        arSession.run(configuration, options: [])
        startRelocalizationPolling()
    }

    private func startRelocalizationPolling() {
        relocalizationPollTask?.cancel()
        let start = Date()
        relocalizationPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.relocalizationPollIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= Self.relocalizationTimeoutSeconds {
                    self.relocalizationState = .timedOut
                    return
                }
                guard let frame = self.arSession.currentFrame else { continue }
                switch frame.camera.trackingState {
                case .normal:
                    self.relocalizationState = .recognised
                    return
                case .limited(.relocalizing):
                    continue
                case .limited, .notAvailable:
                    continue
                }
            }
        }
    }

    func cancelRelocalization() {
        relocalizationPollTask?.cancel()
        relocalizationPollTask = nil
        relocalizationState = .idle
    }

    func start(afterRelocalization: Bool = false) {
        _ = captureView
        wasRelocalized = afterRelocalization
        state = .scanning
        liveRoomTypeGuess = nil
        roomTypeConfirmation = nil
        roomTypeConfirmedForGuessType = nil
        roomCustomName = nil
        hasAnsweredRoomType = false
        isApproachingSizeLimit = false
        liveStats = .empty
        liveUpdateThrottle.resetRoomTypeAnswered()
        startWalkPathTracking()
        pendingRun = true
        runIfReady()
    }

    func stopCurrentRoom() {
        cameraWatchdog?.cancel()
        pendingRun = false
        isRunning = false
        stopWalkPathTracking()
        captureSession?.stop(pauseARSession: false)
    }

    @discardableResult
    func keepPendingPartialRoom() -> Bool {
        guard let pendingPartialRoom else { return false }
        guard CapturedRoomExporter.export(pendingPartialRoom).hasUsableFloorOutline else {
            DiagnosticsLog.shared.record("Partial room rejected locally: degenerate floor outline", category: .error)
            self.pendingPartialRoom = nil
            pendingPartialRoomWalkPath = []
            return false
        }
        roomFloors.append(currentFloor)
        capturedRooms.append(pendingPartialRoom)
        roomTypeConfirmations.append(roomTypeConfirmationForExport)
        roomWalkPaths.append(pendingPartialRoomWalkPath)
        self.pendingPartialRoom = nil
        pendingPartialRoomWalkPath = []
        return true
    }

    func discardPendingPartialRoom() {
        pendingPartialRoom = nil
        pendingPartialRoomWalkPath = []
    }

    func removeCapturedRoom(at index: Int) {
        guard capturedRooms.indices.contains(index) else { return }
        capturedRooms.remove(at: index)
        roomTypeConfirmations.remove(at: index)
        if roomWalkPaths.indices.contains(index) {
            roomWalkPaths.remove(at: index)
        }
        if roomFloors.indices.contains(index) {
            roomFloors.remove(at: index)
        }
        DiagnosticsLog.shared.record("Captured room removed at index \(index) (multi-room)", category: .info)
    }

    private func startWalkPathTracking() {
        stopWalkPathTracking()
        currentRoomWalkPath = []
        walkPathTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let transform = self.arSession.currentFrame?.camera.transform,
                   self.currentRoomWalkPath.count < Self.walkPathMaxPoints {
                    let t = transform.columns.3
                    self.currentRoomWalkPath.append([Double(t.x), Double(t.y), Double(t.z)])
                }
                try? await Task.sleep(nanoseconds: Self.walkPathSampleIntervalNanoseconds)
            }
        }
    }

    private func stopWalkPathTracking() {
        walkPathTask?.cancel()
        walkPathTask = nil
        DiagnosticsLog.shared.record("Walk path tracking stopped — \(currentRoomWalkPath.count) point(s) recorded for this room", category: .info)
    }

    func mapMergedRoomsToOriginals(_ structure: CapturedStructure) -> [UUID: [Int]] {
        var wallToMergedRoom: [UUID: UUID] = [:]
        for mergedRoom in structure.rooms {
            for wall in mergedRoom.walls {
                wallToMergedRoom[wall.identifier] = mergedRoom.identifier
            }
        }

        var mapping: [UUID: [Int]] = [:]
        var unmatchedIndices: [Int] = []

        for (index, originalRoom) in capturedRooms.enumerated() {
            let mergedIdCounts = originalRoom.walls
                .compactMap { wallToMergedRoom[$0.identifier] }
                .reduce(into: [UUID: Int]()) { counts, mergedId in counts[mergedId, default: 0] += 1 }

            guard let bestMergedId = mergedIdCounts.max(by: { $0.value < $1.value })?.key else {
                unmatchedIndices.append(index)
                continue
            }
            mapping[bestMergedId, default: []].append(index)
        }

        for index in unmatchedIndices {
            let originalArea = floorArea(of: capturedRooms[index])
            guard let bestMergedRoom = structure.rooms.min(by: {
                abs(floorArea(of: $0) - originalArea) < abs(floorArea(of: $1) - originalArea)
            }) else { continue }
            mapping[bestMergedRoom.identifier, default: []].append(index)
        }

        return mapping
    }

    func replacementsForStructure(_ structure: CapturedStructure, replacements: [Int: String]) -> [UUID: String] {
        guard !replacements.isEmpty else { return [:] }
        var result: [UUID: String] = [:]
        for (mergedId, originalIndices) in mapMergedRoomsToOriginals(structure) {
            if let roomId = originalIndices.sorted().compactMap({ replacements[$0] }).first {
                result[mergedId] = roomId
            }
        }
        return result
    }

    func roomTypeConfirmationsForStructure(_ structure: CapturedStructure) -> [UUID: RoomTypeConfirmation] {
        let mapping = mapMergedRoomsToOriginals(structure)
        var result: [UUID: RoomTypeConfirmation] = [:]
        for (mergedId, originalIndices) in mapping {
            for index in originalIndices {
                if let confirmation = roomTypeConfirmations[index] {
                    result[mergedId] = confirmation
                    break
                }
            }
        }
        return result
    }

    func floor(forRoomAt index: Int) -> String {
        roomFloors.indices.contains(index) ? roomFloors[index] : currentFloor
    }

    func floorsForStructure(_ structure: CapturedStructure) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (mergedId, originalIndices) in mapMergedRoomsToOriginals(structure) {
            let floors = originalIndices.map { floor(forRoomAt: $0) }
            if let named = floors.first(where: { !$0.isEmpty }) ?? floors.first {
                result[mergedId] = named
            }
        }
        return result
    }

    func walkPathsForStructure(_ structure: CapturedStructure) -> [UUID: [[Double]]] {
        let mapping = mapMergedRoomsToOriginals(structure)
        var result: [UUID: [[Double]]] = [:]
        for (mergedId, originalIndices) in mapping {
            let combined = originalIndices.flatMap { index -> [[Double]] in
                guard roomWalkPaths.indices.contains(index) else { return [] }
                return roomWalkPaths[index]
            }
            if !combined.isEmpty {
                result[mergedId] = combined
            }
        }
        return result
    }

    private func floorArea(of room: CapturedRoom) -> Double {
        room.floors.reduce(0.0) { sum, floor in
            sum + polygonArea(corners: floor.polygonCorners, transform: floor.transform)
        }
    }

    private func polygonArea(corners: [simd_float3], transform: simd_float4x4) -> Double {
        let worldCorners = corners.map { corner -> (x: Double, z: Double) in
            let world = transform * simd_float4(corner, 1)
            return (Double(world.x), Double(world.z))
        }
        guard worldCorners.count >= 3 else { return 0 }
        var area = 0.0
        for i in worldCorners.indices {
            let a = worldCorners[i]
            let b = worldCorners[(i + 1) % worldCorners.count]
            area += a.x * b.z - b.x * a.z
        }
        return abs(area) / 2.0
    }

    func finishUnit() {
        cameraWatchdog?.cancel()
        pendingRun = false
        isRunning = false
        stopWalkPathTracking()
        captureSession?.stop(pauseARSession: false)
        arSession.pause()
        guard !capturedRooms.isEmpty else {
            state = .mergeFailed("No rooms were captured in this walkthrough.")
            return
        }
        state = .merging
        startMergeHeartbeat()
        let rooms = capturedRooms
        mergeTask = Task { [weak self] in
            do {
                let structure = try await Self.runMerge(rooms: rooms, timeoutSeconds: Self.mergeTimeoutSeconds)
                guard !Task.isCancelled, let self else { return }
                self.stopMergeHeartbeat()
                self.mergedStructure = structure
                self.state = .unitFinished
            } catch is CancellationError {
                self?.stopMergeHeartbeat()
            } catch is MergeTimeoutError {
                self?.stopMergeHeartbeat()
                DiagnosticsLog.shared.record("Merge timed out after \(Int(Self.mergeTimeoutSeconds))s — falling back to unmerged rooms", category: .error)
                self?.state = .mergeTimedOut
            } catch {
                self?.stopMergeHeartbeat()
                self?.state = .mergeFailed(error.localizedDescription)
            }
        }
    }

    func cancelMerge() {
        mergeTask?.cancel()
        mergeTask = nil
        stopMergeHeartbeat()
        DiagnosticsLog.shared.record("Merge cancelled by user — keeping \(capturedRooms.count) captured room(s)", category: .info)
        state = .mergeCancelled
    }

    private static func runMerge(rooms: [CapturedRoom], timeoutSeconds: Double) async throws -> CapturedStructure {
        try await withThrowingTaskGroup(of: CapturedStructure.self) { group in
            group.addTask {
                try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw MergeTimeoutError()
            }
            guard let result = try await group.next() else {
                throw MergeTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    private func startMergeHeartbeat() {
        let start = Date()
        heartbeatTask = Task {
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                step += 1
                let elapsed = Int(Date().timeIntervalSince(start))
                DiagnosticsLog.shared.record("Merging rooms — step \(step), elapsed \(elapsed)s", category: .state)
            }
        }
    }

    private func stopMergeHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}

extension MultiRoomCaptureCoordinator: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            self.isRunning = false
            let wasReloc = self.wasRelocalized
            self.wasRelocalized = false
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                if let error {
                    if wasReloc, case RoomCaptureSession.CaptureError.exceedSceneSizeLimit = error {
                        DiagnosticsLog.shared.record("exceedSceneSizeLimit after relocalization — routing to manual placement", category: .error)
                        self.relocalizationState = .relocalizedButCaptureFailed
                        self.pendingPartialRoom = nil
                        self.pendingPartialRoomWalkPath = []
                        return
                    }
                    let hasUsableGeometry = !room.walls.isEmpty || !room.floors.isEmpty
                    self.pendingPartialRoom = hasUsableGeometry ? room : nil
                    self.pendingPartialRoomWalkPath = hasUsableGeometry ? self.currentRoomWalkPath : []
                    let message = CaptureErrorText.message(for: error, partialAvailable: hasUsableGeometry, isUnitScan: true)
                    self.state = .failed(message, partialRoomAvailable: hasUsableGeometry)
                } else {
                    if CapturedRoomExporter.export(room).hasUsableFloorOutline {
                        self.roomFloors.append(self.currentFloor)
                        self.capturedRooms.append(room)
                        self.roomTypeConfirmations.append(self.roomTypeConfirmationForExport)
                        self.roomWalkPaths.append(self.currentRoomWalkPath)
                        self.state = .roomFinished(roomAvailable: true)
                    } else {
                        self.state = .roomFinished(roomAvailable: false)
                    }
                }
            } catch {
                self.state = .failed(error.localizedDescription, partialRoomAvailable: false)
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction (multi-room): \(instruction)", category: .instruction)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let decision = liveUpdateThrottle.decideUpdate()
        guard decision.shouldProcess else { return }
        let exceedsSizeLimit = RoomSizeGuard.exceedsPracticalLimit(room)
        let guess = RoomTypeGuessSettings.isEnabled ? RoomTypeClassifier.guess(for: room) : nil
        let stats = CaptureCoordinator.computeStats(room)
        Task { @MainActor in
            if self.isApproachingSizeLimit != exceedsSizeLimit {
                self.isApproachingSizeLimit = exceedsSizeLimit
            }
            if self.liveStats != stats {
                self.liveStats = stats
            }
            if let guess, !self.liveUpdateThrottle.isRoomTypeAnswered(), self.liveRoomTypeGuess?.type != guess.type {
                self.liveRoomTypeGuess = guess
            }
        }
    }
}