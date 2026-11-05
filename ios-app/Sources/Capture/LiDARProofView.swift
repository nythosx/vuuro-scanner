import SwiftUI

struct LiDARProofView: View {
    let captures: [LidarCaptureMatch]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String?
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
            if selectedId == nil { selectedId = captures.first?.id }
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
        .fullScreenCover(isPresented: $showMesh) {
            if let captureURL {
                NavigationStack {
                    MeshViewer(captureURL: captureURL)
                }
            }
        }
    }

    private func answers(_ manifest: LidarCaptureManifest) -> some View {
        card {
            row("Device", "\(manifest.device), iOS \(manifest.systemVersion)")
            row("RoomPlan depth on its own", yesNo(manifest.roomPlanConfig?.sceneDepth))
            row("RoomPlan mesh on its own", manifest.roomPlanConfig?.sceneReconstruction ?? "unknown")
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
            row("Duration", String(format: "%.0f s", manifest.durationS))
            row("Keyframes", "\(stats.frames) (\(stats.depthFrames) with depth)")
            row("Extra depth-only frames", "\(stats.depthOnlyFrames ?? 0)")
            let coverageRooms = manifest.liveCoverageRooms ?? manifest.liveCoverage.map { [$0] } ?? []
            ForEach(Array(coverageRooms.enumerated()), id: \.offset) { index, coverage in
                let prefix = coverageRooms.count > 1 ? "Room \(index + 1): " : ""
                row(prefix + "Floor seen during the scan", (coverage.floorPercent.map { String(format: "%.0f%%", $0) } ?? (coverage.floorSeenM2 > 0 ? "not measured" : "no floor yet")) + (coverage.ceilingSeen == false ? ", ceiling not scanned so no gap check" : ""))
                row(prefix + "Floor seen / missing under the ceiling", String(format: "%.1f m2 / %.1f m2", coverage.floorSeenM2, coverage.floorMissingM2))
                if let wallPercent = coverage.wallSeenPercent {
                    row(prefix + "RoomPlan walls the mesh reached", String(format: "%.0f%%, %.1f m missing", wallPercent, coverage.wallMissingM ?? 0))
                }
                if let total = coverage.cornersTotal {
                    row(prefix + "Room corners the mesh reached", "\(coverage.cornersSeen ?? 0) of \(total)")
                }
            }
            row("Mesh", "\(stats.meshAnchors) pieces, \(stats.meshVertices) points, \(stats.meshFaces) triangles")
            if let depthMesh = depthReport {
                row("Depth mesh", "\(depthMesh.vertices) points, \(depthMesh.faces) triangles")
                row("Depth mesh frames", "\(depthMesh.framesUsed) used (\(depthMesh.depthOnlyFramesUsed) depth-only), \(depthMesh.framesFailed) unreadable")
                if depthMesh.framesFailed > 0 {
                    Text("\(depthMesh.framesFailed) depth frames could not be read, so the mesh may have holes where only they saw. \(depthMesh.failedFrameNames?.first ?? "")")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
                row("Depth mesh detail", String(format: "%.0f mm cells, built in %.1f s", depthMesh.voxelM * 1000, depthMesh.seconds))
                row("Mesh footprint from above", String(format: "%.1f m2", depthMesh.footprintM2))
                row("Floor seen by the camera", String(format: "%.1f m2", depthMesh.floorSeenM2))
                row("Floor filled where unseen", String(format: "%.1f m2", depthMesh.floorFilledM2) + (depthMesh.fillClippedToRoomPlan ? ", inside the RoomPlan outline" : ", no RoomPlan outline"))
                row("RoomPlan doors, windows, objects", depthMesh.roomBoxesUnreadable ? "file unreadable" : "\(depthMesh.roomBoxes)")
                row("Labelled from RoomPlan", "\(depthMesh.openingFaces) door/window, \(depthMesh.objectFaces) furniture triangles")
            }
            row("Data on phone", ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
            row("Hottest", thermalText(stats.worstThermalState))
            row("Lowest free memory", "\(stats.lowestFreeMemoryMB) MB")
            row("Skipped while saving", "\(stats.skippedBusyFrames)")
            row("Save failures", "\(stats.writeFailures)")
        }
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
        guard let date = capture.createdAt else { return capture.id }
        return date.formatted(date: .abbreviated, time: .shortened)
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
            buildDepthMeshIfNeeded()
        } catch {
            manifest = nil
            loadError = "Could not read the LiDAR capture: \(error.localizedDescription)"
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
