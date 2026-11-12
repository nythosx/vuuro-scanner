import SwiftUI

struct LiDARProofView: View {
    let captures: [LidarCaptureMatch]
    @Binding var selectedId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var captureURL: URL?
    @State private var manifest: LidarCaptureManifest?
    @State private var loadError: String?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showMesh = false
    @State private var isFusing = false
    @State private var fusionError: String?
    @State private var fusionProgress: Double = 0
    @State private var fusionTask: Task<Void, Never>?
    @State private var depthReport: LidarDepthMeshReport?
    @State private var photoBuild: MeshPhotoBuildLog.Entry?
    @State private var photoBuildError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if captures.count > 1 {
                    Picker("Capture", selection: $selectedId) {
                        ForEach(captures) { capture in
                            Text(captureLabel(capture)).tag(Optional(capture.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("lidarProof.capturePicker")
                }
                if let selected, selected.matchedByTime {
                    Text("This capture was made before captures were linked to scans, so it is matched to this scan by time.")
                        .font(.system(size: 14))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
                if let manifest {
                    runSummary(manifest)
                    answers(manifest)
                    numbers(manifest)
                    actions
                } else if let loadError {
                    Text(loadError)
                        .font(.system(size: 15))
                        .foregroundStyle(VuuroColor.textPrimary)
                } else {
                    Text("No LiDAR capture for this scan on this phone. Captures stay on the phone that scanned, and the oldest are removed to save space.")
                        .font(.system(size: 15))
                        .foregroundStyle(VuuroColor.textPrimary)
                }
                if let exportError {
                    Text(exportError)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .background(VuuroColor.bgApp)
        .navigationTitle("LiDAR capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            if selectedId == nil || !captures.contains(where: { $0.id == selectedId }) { selectedId = captures.first?.id }
            load()
        }
        .onChange(of: selectedId) { _, _ in
            fusionTask?.cancel()
            fusionTask = nil
            isFusing = false
            load()
        }
        .onDisappear {
            fusionTask?.cancel()
            fusionTask = nil
        }
        .fullScreenCover(isPresented: $showMesh, onDismiss: loadPhotoBuild) {
            if let captureURL {
                NavigationStack {
                    MeshViewer(captureURL: captureURL)
                }
            }
        }
    }

    static let goodFloorPercent = 95.0

    static func runIssues(_ manifest: LidarCaptureManifest) -> [String] {
        let stats = manifest.stats
        var issues: [String] = []
        if !stats.sceneDepthSeen { issues.append("no depth received") }
        if !stats.meshSeen { issues.append("no mesh received") }
        if stats.writeFailures > 0 { issues.append("\(stats.writeFailures) save failures") }
        let longGaps = (manifest.recordingGaps ?? []).filter { $0.durationS >= longGapS }
        if let longest = longGaps.map(\.durationS).max() {
            issues.append(String(format: "%ld %@ over %.0f s, longest %.0f s", longGaps.count, longGaps.count == 1 ? "gap" : "gaps", longGapS, longest))
        }
        let rooms = manifest.liveCoverageRooms ?? manifest.liveCoverage.map { [$0] } ?? []
        let floors = rooms.compactMap(\.floorPercent)
        if let lowest = floors.min(), lowest < goodFloorPercent {
            issues.append(String(format: "floor seen %.0f%%", lowest))
        }
        if let resets = stats.poseResets, resets > 0 { issues.append("\(resets) position resets") }
        if (manifest.skipReasons?[LidarSkipReason.lowStorage.rawValue] ?? 0) > 0 { issues.append("storage ran out") }
        return issues
    }

    private func runSummary(_ manifest: LidarCaptureManifest) -> some View {
        let issues = Self.runIssues(manifest)
        let good = issues.isEmpty
        return Label(good ? "Good run" : "Check: " + issues.joined(separator: ", "), systemImage: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(good ? VuuroColor.goodText : VuuroColor.warningText)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(good ? VuuroColor.goodTint : VuuroColor.warningTint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("lidarProof.summary")
    }

    private func answers(_ manifest: LidarCaptureManifest) -> some View {
        card {
            row("Device", "\(LidarDeviceName.display(manifest.device)), iOS \(manifest.systemVersion)")
            row("Depth turned on by RoomPlan", yesNo(manifest.roomPlanConfig?.sceneDepth))
            row("Mesh turned on by RoomPlan", Self.roomPlanMeshText(manifest.roomPlanConfig?.sceneReconstruction))
            row("Options added by the app", manifest.configAugmented ? "yes" : "no")
            row("Depth received", manifest.stats.sceneDepthSeen ? "yes" : "no")
            row("Mesh received", manifest.stats.meshSeen ? "yes" : "no")
            row("Mesh classification", manifest.stats.classificationSeen ? "yes" : "no")
            row("Mesh built from depth", depthMeshText(manifest))
            if let depthReport, depthReport.roomBoxes > 0 {
                row("RoomPlan items that land on the mesh", "\(depthReport.roomBoxesMatched) of \(depthReport.roomBoxes)")
            }
            if let percent = depthReport?.floorSeenInsideRoomPlanPercent {
                row("Seen floor inside the RoomPlan outline", String(format: "%.0f%%", percent))
            }
            ForEach(manifest.configNotes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(VuuroColor.textSecondary)
            }
        }
    }

    private func numbers(_ manifest: LidarCaptureManifest) -> some View {
        let stats = manifest.stats
        return card {
            row("Rooms recorded", "\(manifest.roomRuns)")
            ForEach(manifest.roomReports ?? [], id: \.room) { report in
                row("Room \(report.room) LiDAR", Self.roomReportText(report))
            }
            row("Duration", String(format: "%.0f s", manifest.durationS))
            row("Keyframes", "\(stats.frames) (\(stats.depthFrames) with depth)")
            row("Extra depth-only frames", "\(stats.depthOnlyFrames ?? 0)")
            let coverageRooms = manifest.liveCoverageRooms ?? manifest.liveCoverage.map { [$0] } ?? []
            ForEach(Array(coverageRooms.enumerated()), id: \.offset) { index, coverage in
                let prefix = coverageRooms.count > 1 ? "Room \(index + 1): " : ""
                row(prefix + "Floor seen during the scan", (coverage.floorPercent.map { String(format: "%.0f%%", $0) } ?? (coverage.floorSeenM2 > 0 ? "not measured" : "no floor yet")) + (coverage.ceilingSeen == false ? ", ceiling not scanned so no gap check" : ""))
                row(prefix + "Floor seen / missing under the ceiling", String(format: "%.1f m² / %.1f m²", coverage.floorSeenM2, coverage.floorMissingM2))
                if let wallPercent = coverage.wallSeenPercent {
                    row(prefix + "RoomPlan walls the mesh reached", String(format: "%.0f%%, %.1f m missing", wallPercent, coverage.wallMissingM ?? 0))
                }
                if let total = coverage.cornersTotal {
                    row(prefix + "Room corners the mesh reached", "\(coverage.cornersSeen ?? 0) of \(total)")
                }
            }
            row("Mesh", "\(stats.meshAnchors) pieces, \(stats.meshVertices) points, \(stats.meshFaces) triangles")
            if let photoBuild {
                row("Last photo texture build", MeshPhotoBuildLog.text(photoBuild))
                if !photoBuild.stages.isEmpty {
                    Text(MeshPhotoBuildLog.stagesText(photoBuild))
                        .font(.system(size: 13))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .accessibilityIdentifier("lidarProof.photoBuildStages")
                }
            } else if let photoBuildError {
                Text(photoBuildError)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
            if let depthMesh = depthReport {
                row("Depth mesh", "\(depthMesh.vertices) points, \(depthMesh.faces) triangles")
                row("Depth mesh frames", "\(depthMesh.framesUsed) used (\(depthMesh.depthOnlyFramesUsed) depth-only), \(depthMesh.framesFailed) unreadable")
                if depthMesh.framesFailed > 0 {
                    Text("\(depthMesh.framesFailed) depth frames could not be read, so the mesh may have holes where only they saw. \(depthMesh.failedFrameNames?.first ?? "")")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
                row("Depth mesh detail", String(format: "%.0f mm cells, built in %.1f s", depthMesh.voxelM * 1000, depthMesh.seconds))
                row("Mesh footprint from above", String(format: "%.1f m²", depthMesh.footprintM2))
                row("Floor seen by the camera", String(format: "%.1f m²", depthMesh.floorSeenM2))
                row("Floor filled where unseen", String(format: "%.1f m²", depthMesh.floorFilledM2) + (depthMesh.fillClippedToRoomPlan ? ", inside the RoomPlan outline" : ", no RoomPlan outline"))
                row("RoomPlan doors, windows, objects", depthMesh.roomBoxesUnreadable ? "file unreadable" : "\(depthMesh.roomBoxes)")
                row("Labelled from RoomPlan", "\(depthMesh.openingFaces) door/window, \(depthMesh.objectFaces) furniture triangles")
            }
            row("Data on phone", ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file) + (stats.depthOnlyBytes == nil && (stats.depthOnlyFrames ?? 0) > 0 ? ", depth-only frames not counted in this older capture, MB per minute not measured" : LidarStorageBudget.mbPerMinute(bytes: stats.totalBytes, durationS: manifest.durationS).map { String(format: ", %.0f MB per minute", $0) } ?? ""))
            if let lowestFree = stats.lowestFreeDiskMB {
                row("Lowest free phone storage", "\(lowestFree) MB")
            }
            row("Hottest", thermalText(stats.worstThermalState))
            row("Lowest free memory", "\(stats.lowestFreeMemoryMB) MB")
            row("Skipped while saving", "\(stats.skippedBusyFrames)")
            row("Save failures", "\(stats.writeFailures)")
            if let poseResets = stats.poseResets {
                row("Position resets accepted", "\(poseResets)")
            }
            if let appEvents = manifest.appEvents, !appEvents.isEmpty {
                row("App events while recording", "\(appEvents.count)")
                ForEach(Array(appEvents.prefix(Self.gapRowsShown).enumerated()), id: \.offset) { _, event in
                    Text(event)
                        .font(.system(size: 13))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
            }
            if let recordingGaps = manifest.recordingGaps {
                row("Recording gaps over 2 s", recordingGaps.isEmpty ? "none" : String(format: "%ld, %.0f s in total", recordingGaps.count, recordingGaps.reduce(0) { $0 + $1.durationS }) + (recordingGaps.count > Self.gapRowsShown ? ", \(Self.gapRowsShown) longest shown, all in the zip" : ""))
                ForEach(Array(recordingGaps.sorted { $0.durationS > $1.durationS }.prefix(Self.gapRowsShown).enumerated()), id: \.offset) { _, gap in
                    Text(Self.gapText(gap, showRoom: manifest.roomRuns > 1))
                        .font(.system(size: 13))
                        .foregroundStyle(gap.durationS >= Self.longGapS ? .orange : VuuroColor.textSecondary)
                }
            }
        }
    }

    static func roomReportText(_ report: LidarRoomRunReport) -> String {
        let mesh = report.configAtEnd?.sceneReconstruction ?? report.configAfter?.sceneReconstruction ?? report.roomPlanConfig?.sceneReconstruction ?? "mesh setting unknown"
        let growth = report.meshGrew ? "\(report.newMeshAnchors) new mesh pieces, \(report.meshFacesAtStart) to \(report.meshFacesMax) triangles" : "no new mesh"
        return "\(mesh), \(growth), depth \(report.depthSeen ? "yes" : "no"), \(report.keyframes) keyframes + \(report.depthOnlyFrames) depth-only"
    }

    static let gapRowsShown = 5
    static let longGapS = 5.0

    static func gapText(_ gap: LidarRecordingGap, showRoom: Bool) -> String {
        let start = Int(gap.startS.rounded())
        var text = (showRoom ? "Room \(gap.room), " : "") + String(format: "at %ld:%02ld, %.0f s", start / 60, start % 60, gap.durationS)
        if let moved = gap.movedM {
            text += String(format: ", moved %.1f m", moved)
            if let height = gap.heightChangeM, abs(height) >= 0.2 {
                text += String(format: ", %@ %.1f m", height > 0 ? "up" : "down", abs(height))
            }
        }
        if gap.atRoomEnd { text += ", until the room ended" }
        let reasons = gap.reasonShares.prefix(3).map { String(format: "%@ %.0f%%", $0.reason.label, $0.percent) }
        return text + ": " + (reasons.isEmpty ? "no reason recorded" : reasons.joined(separator: ", "))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                showMesh = true
            } label: {
                if isFusing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Building the mesh from depth \(Int(fusionProgress * 100))%")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("View 3D mesh")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.vuuroPrimary)
            .disabled(isFusing || !hasMesh)

            if let reason = meshUnavailableReason {
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(fusionError == nil ? VuuroColor.textSecondary : .red)
            }

            Button(action: export) {
                if isExporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Export capture files")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.vuuroSecondary)
            .disabled(isExporting)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(VuuroColor.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VuuroColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var hasMesh: Bool {
        guard let manifest else { return false }
        return manifest.stats.meshSeen || depthReport != nil
    }

    private var meshUnavailableReason: String? {
        if let fusionError { return fusionError }
        guard let manifest, !hasMesh, !isFusing else { return nil }
        if manifest.stats.depthFrames == 0 && (manifest.stats.depthOnlyFrames ?? 0) == 0 {
            return "No mesh: this capture has no depth frames, so a mesh cannot be built."
        }
        return "No mesh yet."
    }

    private func depthMeshText(_ manifest: LidarCaptureManifest) -> String {
        if let depthMesh = depthReport {
            return "yes, \(depthMesh.faces) triangles"
        }
        if isFusing { return "building" }
        if manifest.stats.meshSeen { return "not needed" }
        return manifest.stats.depthFrames > 0 ? "no" : "no depth frames"
    }

    private func buildDepthMeshIfNeeded() {
        guard let captureURL, let manifest, !isFusing else { return }
        let depthFrames = manifest.stats.depthFrames + (manifest.stats.depthOnlyFrames ?? 0)
        guard !manifest.stats.meshSeen, depthReport == nil, depthFrames > 0 else { return }
        isFusing = true
        fusionError = nil
        fusionProgress = 0
        fusionTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                DepthMeshFusion.run(captureURL: captureURL) { value in
                    Task { @MainActor in
                        fusionProgress = value
                    }
                }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard self.captureURL == captureURL, !Task.isCancelled else { return }
            isFusing = false
            fusionTask = nil
            switch result {
            case .success(let report):
                depthReport = report
            case .failure(let error):
                if error is CancellationError { return }
                fusionError = "Could not build the mesh from depth: \(error.localizedDescription)"
                DiagnosticsLog.shared.record("Depth mesh failed: \(error.localizedDescription)", category: .error)
            }
        }
    }

    static func roomPlanMeshText(_ value: String?) -> String {
        switch value {
        case "mesh_with_classification": return "yes, with classes"
        case "mesh": return "yes, without classes"
        case "none": return "no"
        case "other": return "RoomPlan used a different mesh setting"
        case nil: return "unknown"
        default: return value ?? "unknown"
        }
    }

    private func yesNo(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "yes" : "no"
    }

    private func thermalText(_ raw: Int) -> String {
        switch ProcessInfo.ThermalState(rawValue: raw) {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        default: return "unknown"
        }
    }

    private var selected: LidarCaptureMatch? {
        captures.first { $0.id == selectedId } ?? captures.first
    }

    private func captureLabel(_ capture: LidarCaptureMatch) -> String {
        Self.captureLabel(capture, date: capture.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) })
    }

    static func captureLabel(_ capture: LidarCaptureMatch, date: String?) -> String {
        String(format: "%@, %.0f s, %ld frames", date ?? capture.id, capture.manifest.durationS, capture.savedFrames)
    }

    private func load() {
        loadError = nil
        fusionError = nil
        depthReport = nil
        do {
            guard let latest = selected?.url else {
                captureURL = nil
                manifest = nil
                return
            }
            captureURL = latest
            manifest = try LidarCaptureLibrary.manifest(at: latest)
            switch DepthMeshFusion.loadReport(captureURL: latest) {
            case .success(let report):
                depthReport = report
            case .failure(let error):
                depthReport = nil
                fusionError = "The saved depth mesh report could not be read: \(error.localizedDescription)"
            }
            loadPhotoBuild()
            buildDepthMeshIfNeeded()
        } catch {
            manifest = nil
            loadError = "Could not read the LiDAR capture: \(error.localizedDescription)"
        }
    }

    private func loadPhotoBuild() {
        photoBuild = nil
        photoBuildError = nil
        guard let captureURL else { return }
        switch MeshPhotoBuildLog.load(capture: captureURL) {
        case .success(let entry):
            photoBuild = entry
        case .failure(let error):
            photoBuildError = "The last photo texture build time could not be read: \(error.localizedDescription)"
        }
    }

    private func export() {
        guard let captureURL else { return }
        isExporting = true
        exportError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LidarCaptureLibrary.zip(captureURL)
            }.value
            isExporting = false
            switch result {
            case .success(let zipURL):
                if !ShareSheetPresenter.present(items: [zipURL]) {
                    exportError = "Could not open the share sheet."
                }
            case .failure(let error):
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

enum LidarCaptureLibrary {
    static let keepCaptures = 3
    static let manifestName = "capture.json"

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LidarCaptures", isDirectory: true)
    }

    static func manifest(at url: URL) throws -> LidarCaptureManifest {
        let data = try Data(contentsOf: url.appendingPathComponent(manifestName))
        return try JSONDecoder().decode(LidarCaptureManifest.self, from: data)
    }

    static func captures() throws -> [URL] {
        let root = rootDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func zip(_ folder: URL) -> Result<URL, Error> {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("lidar-\(folder.lastPathComponent).zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: zipped, to: target)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { return .failure(coordinatorError) }
        if let copyError { return .failure(copyError) }
        return .success(target)
    }
}
