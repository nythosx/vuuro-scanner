import SwiftUI

struct LiDARProofView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var captureURL: URL?
    @State private var manifest: LidarCaptureManifest?
    @State private var loadError: String?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showMesh = false
    @State private var isFusing = false
    @State private var fusionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let manifest {
                    answers(manifest)
                    numbers(manifest)
                    actions
                } else if let loadError {
                    Text(loadError)
                        .font(.system(size: 15))
                        .foregroundStyle(VuuroColor.textPrimary)
                } else {
                    Text("No LiDAR capture found yet. Run a scan first.")
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
        .onAppear(perform: load)
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
            row("Mesh", "\(stats.meshAnchors) pieces, \(stats.meshVertices) points, \(stats.meshFaces) triangles")
            if let depthMesh = manifest.depthMesh {
                row("Depth mesh", "\(depthMesh.vertices) points, \(depthMesh.faces) triangles")
                row("Depth mesh frames", "\(depthMesh.framesUsed) used, \(depthMesh.framesFailed) unreadable")
                row("Depth mesh detail", String(format: "%.0f mm cells, built in %.1f s", depthMesh.voxelM * 1000, depthMesh.seconds))
                row("Mesh footprint from above", String(format: "%.1f m2", depthMesh.footprintM2))
                row("Floor seen by the camera", String(format: "%.1f m2", depthMesh.floorSeenM2))
                row("Floor filled where unseen", String(format: "%.1f m2", depthMesh.floorFilledM2))
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
                        Text("Building the mesh from depth")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("View 3D mesh")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.vuuroPrimary)
            .disabled(isFusing || !hasMesh)

            if let fusionError {
                Text(fusionError)
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
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
        return manifest.stats.meshSeen || manifest.depthMesh != nil
    }

    private func depthMeshText(_ manifest: LidarCaptureManifest) -> String {
        if let depthMesh = manifest.depthMesh {
            return "yes, \(depthMesh.faces) triangles"
        }
        if isFusing { return "building" }
        if manifest.stats.meshSeen { return "not needed" }
        return manifest.stats.depthFrames > 0 ? "no" : "no depth frames"
    }

    private func buildDepthMeshIfNeeded() {
        guard let captureURL, let manifest, !isFusing else { return }
        guard !manifest.stats.meshSeen, manifest.depthMesh == nil, manifest.stats.depthFrames > 0 else { return }
        isFusing = true
        fusionError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DepthMeshFusion.run(captureURL: captureURL)
            }.value
            isFusing = false
            switch result {
            case .success(let updated):
                if self.captureURL == captureURL {
                    self.manifest = updated
                }
            case .failure(let error):
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

    private func load() {
        loadError = nil
        do {
            guard let latest = try LidarCaptureLibrary.latestCapture() else {
                captureURL = nil
                manifest = nil
                return
            }
            captureURL = latest
            manifest = try LidarCaptureLibrary.manifest(at: latest)
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

    static func latestCapture() throws -> URL? {
        try captures().first
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

    static func pruneOld() {
        do {
            for url in try captures().dropFirst(keepCaptures) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            DiagnosticsLog.shared.record("Old LiDAR captures could not be removed: \(error.localizedDescription)", category: .error)
        }
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
