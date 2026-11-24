import SceneKit
import SwiftUI
import UIKit

struct MeshViewer: View {
    let captureURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var built: MeshSceneBuilder.Built?
    @State private var mode: Mode = .clay
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var frames: [MeshFrame] = []
    @State private var skippedFrames = 0
    @State private var poseResets: [LidarPoseReset] = []
    @State private var frameError: String?
    @State private var frameIndex: Int?
    @State private var orbitPose: simd_float4x4?
    @State private var showPhoto = false
    @State private var photo: UIImage?
    @State private var photoError: String?
    @State private var texturing = false
    @State private var textured = false
    @State private var textureNote: String?
    @State private var showFilledFloor = false
    @State private var hasFilledFloor = false
    @State private var photoTextured = false
    @State private var photoNote: String?
    @State private var photoMonitor: MeshPhotoTexturer.Monitor?
    @State private var photoProgress: Double = 0
    @State private var photoStopping = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var photoBuild: MeshPhotoTexturer.Output?
    @State private var sending = false
    @State private var sendProgress: Double = 0
    @State private var sendNote: String?
    @State private var sendError: String?
    @State private var usableCache: PoseResetRealigner.Outcome?
    @State private var sentModelURL: URL?

    enum Mode: String, CaseIterable, Identifiable {
        case clay = "Clay"
        case wireframe = "Mesh"
        case classes = "Classes"
        case texture = "Texture"
        case photo = "Photo"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if let built {
                MeshSceneView(
                    scene: built.scene,
                    cameraNode: built.cameraNode,
                    boundsMin: built.boundsMin,
                    boundsMax: built.boundsMax,
                    background: mode == .wireframe ? .black : UIColor(white: 0.93, alpha: 1),
                    interactive: frameIndex == nil
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                Color(white: 0.93).ignoresSafeArea(edges: .bottom)
            }
            if frameIndex != nil, showPhoto {
                photoLayer
            }
            if isLoading {
                ProgressView("Loading mesh")
            } else if texturing {
                VStack(spacing: 12) {
                    if photoMonitor != nil {
                        ProgressView(value: photoProgress) {
                            Text(photoStopping ? "Stopping the photo texture" : "Building the photo texture from the keyframe photos")
                        } currentValueLabel: {
                            Text("\(Int((photoProgress * 100).rounded()))%")
                                .monospacedDigit()
                        }
                        .frame(width: 260)
                        .accessibilityIdentifier("meshViewer.photoProgress")
                        Button("Cancel") { cancelPhotoTexture() }
                            .disabled(photoStopping)
                            .accessibilityIdentifier("meshViewer.cancelPhoto")
                    } else {
                        ProgressView("Coloring the mesh from the photos")
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if exporting {
                ProgressView("Saving the 3D model")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if sending {
                ProgressView(value: sendProgress) {
                    Text("Sending the Photo model to the web tour")
                } currentValueLabel: {
                    Text("\(Int((sendProgress * 100).rounded()))%")
                        .monospacedDigit()
                }
                .frame(width: 260)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("meshViewer.sendProgress")
            } else if let loadError {
                messageCard(loadError)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isLoading || texturing)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                if hasFilledFloor {
                    Toggle("Show floor filled where the camera did not see", isOn: $showFilledFloor)
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .offset(y: 40)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if built != nil {
                pathControls
            }
        }
        .navigationTitle((built?.triangles ?? 0) > 0 ? "\((built?.triangles ?? 0).formatted()) triangles" : "3D mesh")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    shareModel()
                } label: {
                    Label("Share 3D model", systemImage: "square.and.arrow.up")
                }
                .disabled(built == nil || texturing || exporting)
                .accessibilityIdentifier("meshViewer.share")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sendToWebTour()
                } label: {
                    Label("Send to web tour", systemImage: "globe")
                }
                .disabled(built == nil || texturing || exporting || sending)
                .accessibilityIdentifier("meshViewer.sendToWeb")
            }
        }
        .onChange(of: mode) { _, _ in
            applyMode()
        }
        .onChange(of: showFilledFloor) { _, _ in
            applyMode()
        }
        .onChange(of: frameIndex) { _, _ in
            moveCamera()
        }
        .task(id: mode) {
            if mode == .texture { await colorize() }
            if mode == .photo { await photoTexture() }
        }
        .task(id: photoKey) {
            await loadPhoto()
        }
        .task {
            await load()
        }
    }

    private var photoKey: String {
        guard showPhoto, let frameIndex else { return "" }
        return "\(frameIndex)"
    }

    private var photoLayer: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else if let photoError {
                    messageCard(photoError)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    static let startViewNote = "Send to web tour opens the web 3D scan from the view you see now."
    static let orbitHint = "Drag to turn, pinch to zoom, two fingers to move. Double tap a spot to go closer, or empty space to reset."

    @ViewBuilder
    private var pathControls: some View {
        VStack(spacing: 10) {
            if let textureNote, mode == .texture {
                Text(textureNote)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let photoNote, mode == .photo {
                Text(photoNote)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let exportError {
                Text(exportError)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            if let sendError {
                Text(sendError)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("meshViewer.sendError")
            }
            if photoBuild != nil, frameIndex == nil, !sending {
                Text(Self.startViewNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("meshViewer.startViewNote")
            }
            if let sendNote {
                Text(sendNote)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meshViewer.sendNote")
            }
            if let sentModelURL {
                Link(destination: sentModelURL) {
                    Label("Open the 3D scan in the web tour", systemImage: "safari")
                        .font(.system(size: 15, weight: .semibold))
                }
                .accessibilityIdentifier("meshViewer.openWebModel")
            }
            if let frameError {
                Text(frameError)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if skippedFrames > 0 {
                Text("\(skippedFrames) frames could not be read")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if frameIndex == nil {
                Text(Self.orbitHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("meshViewer.orbitHint")
            }
            if let frameIndex, !frames.isEmpty {
                Text("Frame \(frameIndex + 1) of \(frames.count)")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                HStack(spacing: 12) {
                    Button {
                        leavePath()
                    } label: {
                        Label("Back", systemImage: "arrow.left")
                    }
                    Slider(
                        value: Binding(
                            get: { Double(frameIndex) },
                            set: { self.frameIndex = min(max(Int($0.rounded()), 0), frames.count - 1) }
                        ),
                        in: 0...Double(max(frames.count - 1, 1)),
                        step: 1
                    )
                    .disabled(frames.count < 2)
                    Button {
                        self.frameIndex = max(frameIndex - 1, 0)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(frameIndex == 0)
                    Button {
                        self.frameIndex = min(frameIndex + 1, frames.count - 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(frameIndex >= frames.count - 1)
                }
                Toggle("Show the photo of this frame", isOn: $showPhoto)
                    .font(.system(size: 15))
            } else if !frames.isEmpty {
                Button {
                    enterPath()
                } label: {
                    Label("Walk the capture path (\(frames.count) frames)", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func usableFrames(_ built: MeshSceneBuilder.Built) async -> PoseResetRealigner.Outcome {
        if let usableCache { return usableCache }
        let frameList = frames
        let resets = poseResets
        guard !resets.isEmpty else {
            let plain = LidarPoseReset.usable(frameList, resets: resets)
            return PoseResetRealigner.Outcome(frames: plain.frames, dropped: plain.dropped, realigned: 0)
        }
        let inputs = built.parts.map {
            MeshPhotoTexturer.PartInput(vertices: $0.vertices, vertexCount: $0.vertexCount, faces: $0.faces, faceCount: $0.faceCount, classes: $0.classes, transform: $0.transform)
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            PoseResetRealigner.realign(frames: frameList, resets: resets, meshPoints: PoseResetRealigner.meshPoints(inputs))
        }.value
        if outcome.realigned > 0 {
            DiagnosticsLog.shared.record("Position reset: \(outcome.realigned) frames lined up with the mesh again, \(outcome.dropped) still left out", category: .state)
        }
        usableCache = outcome
        return outcome
    }

    private func messageCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
    }

    private func enterPath() {
        guard let built, !frames.isEmpty else { return }
        orbitPose = built.cameraNode.simdTransform
        frameIndex = 0
        applyMode()
        moveCamera()
    }

    private func leavePath() {
        guard let built else { return }
        frameIndex = nil
        showPhoto = false
        if let orbitPose {
            built.cameraNode.simdTransform = orbitPose
        }
        built.cameraNode.camera?.fieldOfView = MeshSceneBuilder.orbitFieldOfView
        applyMode()
    }

    private func applyMode() {
        guard let built else { return }
        MeshSceneBuilder.apply(mode, showCeiling: frameIndex != nil, showFilledFloor: showFilledFloor, parts: built.parts)
    }

    private func colorize() async {
        guard let built, !textured, !texturing else { return }
        guard !frames.isEmpty else {
            textureNote = "This capture has no frame photos to color the mesh with."
            return
        }
        texturing = true
        let inputs = built.parts.map { MeshTexturer.PartInput(vertices: $0.vertices, vertexCount: $0.vertexCount, transform: $0.transform) }
        let usable = await usableFrames(built)
        let frameList = usable.frames
        let work = Task.detached(priority: .userInitiated) {
            MeshTexturer.colorize(parts: inputs, frames: frameList)
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        texturing = false
        switch result {
        case .success(let output):
            for (part, colors) in zip(built.parts, output.colors) where colors.count == part.vertexCount * 12 {
                part.textured = MeshSceneBuilder.texturedGeometry(plain: part.plain, colors: colors, vertexCount: part.vertexCount)
            }
            textured = true
            let percent = output.totalVertices > 0 ? output.coloredVertices * 100 / output.totalVertices : 0
            var note = "Colored from \(Self.photos(output.framesUsed)), \(percent)% of the mesh seen in a photo"
            if usable.realigned > 0 {
                note += ", \(Self.photos(usable.realigned)) from before a position reset lined up with the mesh again and used"
            }
            if usable.dropped > 0 {
                note += ", \(Self.photos(usable.dropped)) from before a position reset left out"
                if LidarPoseReset.mostlyLeftOut(dropped: usable.dropped, total: frames.count) { note += ". " + LidarPoseReset.mostlyLeftOutText }
                DiagnosticsLog.shared.record("Texture: \(usable.dropped) frames from before a position reset were left out", category: .state)
            }
            if output.framesFailed > 0 {
                note += ", \(Self.photos(output.framesFailed)) could not be opened"
            }
            textureNote = note
            applyMode()
        case .failure(let error):
            if error is CancellationError { return }
            textureNote = "Could not color the mesh: \(error.localizedDescription)"
        }
    }

    private func photoTexture() async {
        guard let built, !photoTextured, !texturing else { return }
        guard !frames.isEmpty else {
            photoNote = "This capture has no frame photos for a photo texture."
            return
        }
        texturing = true
        let monitor = MeshPhotoTexturer.Monitor()
        photoMonitor = monitor
        photoProgress = 0
        photoStopping = false
        let started = Date()
        let inputs = built.parts.map {
            MeshPhotoTexturer.PartInput(vertices: $0.vertices, vertexCount: $0.vertexCount, faces: $0.faces, faceCount: $0.faceCount, classes: $0.classes, transform: $0.transform)
        }
        let usable = await usableFrames(built)
        let frameList = usable.frames
        let work = Task.detached(priority: .userInitiated) {
            MeshPhotoTexturer.texture(parts: inputs, frames: frameList, monitor: monitor)
        }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                photoProgress = monitor.fraction
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            monitor.cancel()
            work.cancel()
        }
        poll.cancel()
        texturing = false
        photoMonitor = nil
        photoStopping = false
        switch result {
        case .success(let output):
            let sceneStarted = Date()
            if usable.dropped > 0 {
                DiagnosticsLog.shared.record("Photo texture: \(usable.dropped) frames from before a position reset were left out", category: .state)
            }
            var cache: [Int: SCNMaterial] = [:]
            for (part, partOutput) in zip(built.parts, output.parts) where partOutput.vertexCount > 0 {
                part.photo = MeshSceneBuilder.photoGeometry(partOutput) { group in
                    let key = (group.slot + 1) * 256 + Int(group.classId)
                    if let cached = cache[key] { return cached }
                    let image: CGImage? = output.images.indices.contains(group.slot) ? output.images[group.slot] : nil
                    let material = MeshSceneBuilder.photoMaterial(classId: group.classId, image: image)
                    cache[key] = material
                    return material
                }
            }
            photoTextured = true
            photoBuild = output
            let seconds = Int(Date().timeIntervalSince(started).rounded())
            photoNote = Self.photoTextureNote(output, seconds: seconds, dropped: usable.dropped, total: frames.count, realigned: usable.realigned)
            applyMode()
            let stages = monitor.stages + [MeshPhotoBuildLog.Stage(name: "3D scene", seconds: Date().timeIntervalSince(sceneStarted))]
            logPhotoBuild(.done, started: started, monitor: monitor, stages: stages, triangles: output.totalFaces, photosUsed: output.photosUsed)
        case .failure(let error):
            if error is CancellationError {
                logPhotoBuild(.cancelled, started: started, monitor: monitor, stages: monitor.stages, triangles: built.triangles, photosUsed: 0)
                return
            }
            photoNote = "Could not build the photo texture: \(error.localizedDescription)"
            logPhotoBuild(.failed, started: started, monitor: monitor, stages: monitor.stages, triangles: built.triangles, photosUsed: 0)
        }
    }

    static func photos(_ count: Int, kind: String = "") -> String {
        "\(count) \(kind.isEmpty ? "" : kind + " ")\(count == 1 ? "photo" : "photos")"
    }

    static func photoTextureNote(_ output: MeshPhotoTexturer.Output, seconds: Int, dropped: Int, total: Int, realigned: Int = 0) -> String {
        let percent = output.totalFaces > 0 ? output.facesInPhoto * 100 / output.totalFaces : 0
        let filledPercent = output.totalFaces > 0 ? output.facesFilled * 100 / output.totalFaces : 0
        var note = "Photo texture from \(photos(output.photosUsed, kind: "keyframe")) at \(MeshPhotoTexturer.textureSize) px with brightness evened out, \(percent)% of the mesh"
        if output.facesFilled > 0 {
            note += ", \(filledPercent < 1 ? "under 1" : String(filledPercent))% more filled in from a nearby photo"
        }
        note += ", built in \(seconds) s."
        if output.facesInPhoto + output.facesFilled < output.totalFaces {
            note += " Grey parts are not in any photo."
        }
        if realigned > 0 {
            note += " \(photos(realigned)) from before a position reset lined up with the mesh again and \(realigned == 1 ? "was" : "were") used."
        }
        if dropped > 0 {
            note += " \(photos(dropped)) from before a position reset \(dropped == 1 ? "was" : "were") left out."
        }
        if LidarPoseReset.mostlyLeftOut(dropped: dropped, total: total) {
            note += " " + LidarPoseReset.mostlyLeftOutText
        }
        if output.photosUnreadable > 0 {
            note += " \(photos(output.photosUnreadable)) could not be opened, so \(output.photosUnreadable == 1 ? "its" : "their") parts are grey too."
        }
        return note
    }

    private func logPhotoBuild(_ outcome: MeshPhotoBuildLog.Outcome, started: Date, monitor: MeshPhotoTexturer.Monitor, stages: [MeshPhotoBuildLog.Stage], triangles: Int, photosUsed: Int) {
        let entry = MeshPhotoBuildLog.Entry(
            finishedAt: Date(),
            seconds: Date().timeIntervalSince(started),
            outcome: outcome,
            percentDone: Int((monitor.fraction * 100).rounded()),
            debugBuild: MeshPhotoBuildLog.isDebugBuild,
            triangles: triangles,
            photosUsed: photosUsed,
            stages: stages
        )
        if case .failure(let error) = MeshPhotoBuildLog.save(entry, capture: captureURL) {
            DiagnosticsLog.shared.record("Photo texture build time not saved: \(error.localizedDescription)", category: .error)
        }
    }

    private func cancelPhotoTexture() {
        photoStopping = true
        photoMonitor?.cancel()
        mode = .clay
    }

    private func shareModel() {
        guard let built, !exporting else { return }
        exporting = true
        exportError = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vuuro-lidar-\(captureURL.lastPathComponent)-\(mode.rawValue.lowercased()).usdz")
        Task { @MainActor in
            await Task.yield()
            defer { exporting = false }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                exportError = "Could not replace the old 3D model file: \(error.localizedDescription)"
                return
            }
            guard built.scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
                exportError = "The 3D model could not be saved as USDZ."
                return
            }
            if !ShareSheetPresenter.present(items: [url]) {
                exportError = "The share sheet could not open."
            }
        }
    }

    static func sentNote(bytes: Int, triangles: Int, photos: Int) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return "Sent to the web tour: \(String(format: "%.1f", megabytes)) MB, \(triangles.formatted()) triangles, \(Self.photos(photos)). Open the tour link and tap 3D scan."
    }

    private func sendToWebTour() {
        guard let built, !sending else { return }
        sendNote = nil
        sendError = nil
        sentModelURL = nil
        guard let output = photoBuild else {
            sendError = "Open Photo first. The web tour gets the Photo model."
            return
        }
        let sessionId: String
        do {
            guard let linked = try LidarCaptureLibrary.manifest(at: captureURL).sessionId else {
                sendError = "This LiDAR capture is not linked to a saved scan, so there is no web tour to send it to."
                return
            }
            sessionId = linked
        } catch {
            sendError = "Could not read this capture: \(error.localizedDescription)"
            return
        }
        guard let token = ScanHistoryStore.shared.all().first(where: { $0.sessionId == sessionId })?.accessToken, !token.isEmpty else {
            sendError = "The access token of this scan is not on this phone, so the 3D model cannot be sent."
            return
        }
        let parts = zip(built.parts, output.parts).map { LidarModelGlb.Part(output: $0.1, transform: $0.0.transform) }
        let images = output.images
        let capture = captureURL.lastPathComponent
        let pose = frameIndex == nil ? built.cameraNode.simdTransform : (orbitPose ?? built.cameraNode.simdTransform)
        let startView = LidarModelGlb.startView(cameraTransform: pose, lookingToward: SIMD3<Float>(Float(built.center.x), Float(built.center.y), Float(built.center.z)))
        let loadedBoxes = DepthMeshFusion.loadBoxes(captureURL: captureURL)
        if loadedBoxes.unreadable {
            DiagnosticsLog.shared.record("Web 3D model: the RoomPlan boxes of this capture could not be read, so it has no room labels", category: .error)
        }
        let rooms = LidarModelGlb.roomMarks(from: loadedBoxes.boxes)
        sending = true
        sendProgress = 0
        Task { @MainActor in
            defer { sending = false }
            let encoded = await Task.detached(priority: .userInitiated) {
                LidarModelGlb.encode(parts: parts, images: images, startView: startView, rooms: rooms)
            }.value
            let model: LidarModelGlb.Encoded
            switch encoded {
            case .success(let value):
                model = value
            case .failure(let error):
                sendError = "Could not build the 3D model for the web: \(error.localizedDescription)"
                DiagnosticsLog.shared.record("Web 3D model not built: \(error.localizedDescription)", category: .error)
                return
            }
            do {
                let client = ScanServiceClient()
                let info = try await client.uploadLidarModel(sessionId: sessionId, accessToken: token, glb: model.data, triangles: model.triangles, photos: model.photos, capture: capture) { fraction in
                    sendProgress = fraction
                }
                sendNote = Self.sentNote(bytes: info.bytes, triangles: model.triangles, photos: model.photos)
                sentModelURL = client.webTourModelURL(sessionId: sessionId, accessToken: token)
                DiagnosticsLog.shared.record("Web 3D model sent for scan \(sessionId): \(info.bytes) bytes, \(model.triangles) triangles", category: .state)
            } catch is CancellationError {
                sendError = "Sending the 3D model was stopped."
            } catch {
                sendError = "Could not send the 3D model: \(error.localizedDescription)"
                DiagnosticsLog.shared.record("Web 3D model not sent: \(error.localizedDescription)", category: .error)
            }
        }
    }

    private func moveCamera() {
        guard let built, let frameIndex, frames.indices.contains(frameIndex) else { return }
        let frame = frames[frameIndex]
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.2
        built.cameraNode.simdTransform = frame.portraitPose
        built.cameraNode.camera?.fieldOfView = frame.verticalFieldOfView
        SCNTransaction.commit()
    }

    private func loadPhoto() async {
        photo = nil
        photoError = nil
        guard showPhoto, let frameIndex, frames.indices.contains(frameIndex) else { return }
        guard let url = frames[frameIndex].imageURL else {
            photoError = "This frame has no photo."
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<UIImage, Error> in
            do {
                let data = try Data(contentsOf: url)
                guard let cgImage = UIImage(data: data)?.cgImage else {
                    return .failure(PlainError(message: "The photo of this frame could not be decoded."))
                }
                return .success(UIImage(cgImage: cgImage, scale: 1, orientation: .right))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let image):
            photo = image
        case .failure(let error):
            photoError = "Could not open the photo of this frame: \(error.localizedDescription)"
        }
    }

    private func load() async {
        let url = captureURL
        let result = await Task.detached(priority: .userInitiated) {
            MeshSceneBuilder.build(captureURL: url)
        }.value
        switch result {
        case .success(let loaded):
            MeshSceneBuilder.apply(mode, showCeiling: false, showFilledFloor: showFilledFloor, parts: loaded.parts)
            hasFilledFloor = loaded.parts.contains { part in
                part.plain.materials.contains { $0.name == String(MeshSceneBuilder.filledFloorClass) }
            }
            built = loaded
        case .failure(let error):
            loadError = "Could not load the mesh: \(error.localizedDescription)"
        }
        let frameResult = await Task.detached(priority: .userInitiated) {
            MeshFrameIndex.load(captureURL: url)
        }.value
        isLoading = false
        do {
            poseResets = try LidarCaptureLibrary.manifest(at: url).stats.poseResetEvents ?? []
        } catch {
            DiagnosticsLog.shared.record("Mesh viewer could not read capture.json for position resets: \(error.localizedDescription)", category: .error)
        }
        switch frameResult {
        case .success(let loaded):
            frames = loaded.frames.filter { $0.imageURL != nil }
            skippedFrames = loaded.skipped + loaded.frames.count - frames.count
        case .failure(let error):
            frameError = "Could not read the capture frames: \(error.localizedDescription)"
        }
    }
}

struct MeshFrame {
    let index: Int
    let cameraTransform: simd_float4x4
    let verticalFieldOfView: CGFloat
    let imageURL: URL?
    let imageWidth: Int
    let imageHeight: Int
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let depthURL: URL?
    let confidenceURL: URL?
    let depthWidth: Int
    let depthHeight: Int
    var motionDegPerS: Float = 0
    var blurPx: Float? = nil
    var timestamp: Double? = nil

    var portraitPose: simd_float4x4 {
        cameraTransform * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
    }
}

enum MeshFrameIndex {
    static let framesFolder = "frames"

    struct Loaded {
        let frames: [MeshFrame]
        let skipped: Int
    }

    private struct Meta: Decodable {
        let index: Int
        let image: String?
        let imageWidth: Int
        let imageHeight: Int
        let cameraTransform: [Float]
        let intrinsics: [Float]
        let depth: String?
        let confidence: String?
        let depthWidth: Int?
        let depthHeight: Int?
        let motionDegPerS: Float?
        let blurPx: Float?
        let exposureS: Double?
        let timestamp: Double?

        enum CodingKeys: String, CodingKey {
            case index
            case image
            case imageWidth = "image_width"
            case imageHeight = "image_height"
            case cameraTransform = "camera_transform"
            case intrinsics = "intrinsics_fx_fy_cx_cy"
            case depth
            case confidence
            case depthWidth = "depth_width"
            case depthHeight = "depth_height"
            case motionDegPerS = "motion_deg_per_s"
            case blurPx = "blur_px_estimate"
            case exposureS = "exposure_s"
            case timestamp
        }
    }

    static func load(captureURL: URL, folder folderName: String = MeshFrameIndex.framesFolder) -> Result<Loaded, Error> {
        let folder = captureURL.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .success(Loaded(frames: [], skipped: 0))
        }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
            var frames: [MeshFrame] = []
            var skipped = 0
            let decoder = JSONDecoder()
            for name in names {
                do {
                    let data = try Data(contentsOf: folder.appendingPathComponent(name))
                    let meta = try decoder.decode(Meta.self, from: data)
                    guard let frame = frame(from: meta, folder: folder) else {
                        skipped += 1
                        continue
                    }
                    frames.append(frame)
                } catch {
                    skipped += 1
                }
            }
            frames.sort { $0.index < $1.index }
            return .success(Loaded(frames: frames, skipped: skipped))
        } catch {
            return .failure(error)
        }
    }

    private static func frame(from meta: Meta, folder: URL) -> MeshFrame? {
        guard meta.cameraTransform.count == 16,
              meta.cameraTransform.allSatisfy({ $0.isFinite }),
              meta.intrinsics.count == 4,
              meta.intrinsics.allSatisfy({ $0.isFinite }),
              meta.intrinsics[0] > 0,
              meta.intrinsics[1] > 0,
              meta.imageWidth > 0,
              meta.imageHeight > 0 else { return nil }
        let values = meta.cameraTransform
        let transform = simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
        let halfWidth = Float(meta.imageWidth) / 2
        let fov = 2 * atan(halfWidth / meta.intrinsics[0]) * 180 / Float.pi
        return MeshFrame(
            index: meta.index,
            cameraTransform: transform,
            verticalFieldOfView: CGFloat(fov),
            imageURL: meta.image.flatMap { $0.isEmpty ? nil : folder.appendingPathComponent($0) },
            imageWidth: meta.imageWidth,
            imageHeight: meta.imageHeight,
            fx: meta.intrinsics[0],
            fy: meta.intrinsics[1],
            cx: meta.intrinsics[2],
            cy: meta.intrinsics[3],
            depthURL: meta.depth.map { folder.appendingPathComponent($0) },
            confidenceURL: meta.confidence.map { folder.appendingPathComponent($0) },
            depthWidth: meta.depthWidth ?? 0,
            depthHeight: meta.depthHeight ?? 0,
            motionDegPerS: meta.motionDegPerS ?? 0,
            blurPx: (meta.exposureS ?? 0) > 0 ? meta.blurPx.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil,
            timestamp: meta.timestamp.flatMap { $0.isFinite ? $0 : nil }
        )
    }
}

struct MeshSceneView: UIViewRepresentable {
    let scene: SCNScene
    let cameraNode: SCNNode
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let background: UIColor
    let interactive: Bool

    final class Coordinator {
        let camera = DollhouseCamera()
        var lastSize: CGSize = .zero
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = background
        var framing = DollhouseScene(meshes: [], boundsMin: boundsMin, boundsMax: boundsMax, roomCount: 1, floorSections: [], usedEstimatedHeight: false)
        framing.defaultYaw = MeshSceneBuilder.orbitYaw
        context.coordinator.camera.followsNodePose = true
        context.coordinator.camera.attach(to: view, cameraNode: cameraNode, framing: framing)
        context.coordinator.camera.setGesturesEnabled(interactive, on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.backgroundColor = background
        if view.pointOfView !== cameraNode {
            view.pointOfView = cameraNode
        }
        context.coordinator.camera.setGesturesEnabled(interactive, on: view)
        let size = view.bounds.size
        if interactive, size != context.coordinator.lastSize {
            context.coordinator.lastSize = size
            context.coordinator.camera.viewportChanged(size)
        }
    }
}

enum MeshSceneBuilder {
    static let classColors: [UInt8: UIColor] = [
        0: UIColor(white: 0.7, alpha: 1),
        1: UIColor(red: 0.62, green: 0.74, blue: 0.86, alpha: 1),
        2: UIColor(red: 0.72, green: 0.56, blue: 0.40, alpha: 1),
        3: UIColor(white: 0.95, alpha: 1),
        4: UIColor(red: 0.95, green: 0.62, blue: 0.25, alpha: 1),
        5: UIColor(red: 0.62, green: 0.45, blue: 0.85, alpha: 1),
        6: UIColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1),
        7: UIColor(red: 0.40, green: 0.80, blue: 0.45, alpha: 1),
        8: UIColor(red: 0.85, green: 0.45, blue: 0.55, alpha: 1),
        9: UIColor(red: 1.0, green: 0.82, blue: 0.55, alpha: 1)
    ]

    static let ceilingClass: UInt8 = 3
    static let filledFloorClass: UInt8 = 9
    static let orbitFieldOfView: CGFloat = 50
    static let orbitYaw: Float = .pi / 2

    final class MeshPart {
        let node: SCNNode
        let plain: SCNGeometry
        let vertices: Data
        let vertexCount: Int
        let faces: Data
        let faceCount: Int
        let classes: Data?
        let transform: simd_float4x4
        var textured: SCNGeometry?
        var photo: SCNGeometry?

        init(node: SCNNode, plain: SCNGeometry, vertices: Data, vertexCount: Int, faces: Data, faceCount: Int, classes: Data?, transform: simd_float4x4) {
            self.node = node
            self.plain = plain
            self.vertices = vertices
            self.vertexCount = vertexCount
            self.faces = faces
            self.faceCount = faceCount
            self.classes = classes
            self.transform = transform
        }
    }

    struct Built {
        let scene: SCNScene
        let triangles: Int
        let cameraNode: SCNNode
        let center: SCNVector3
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>
        let parts: [MeshPart]
    }

    struct AnchorEntry: Decodable {
        let fileStem: String
        let transform: [Float]
        let vertexCount: Int
        let faceCount: Int
        let normalsFormat: String?
        let classesFormat: String?

        enum CodingKeys: String, CodingKey {
            case fileStem = "file_stem"
            case transform
            case vertexCount = "vertex_count"
            case faceCount = "face_count"
            case normalsFormat = "normals_format"
            case classesFormat = "classes_format"
        }
    }

    struct AnchorIndex: Decodable {
        let anchors: [AnchorEntry]
    }

    static func build(captureURL: URL) -> Result<Built, Error> {
        let meshURL = captureURL.appendingPathComponent("mesh", isDirectory: true)
        do {
            let index = try JSONDecoder().decode(AnchorIndex.self, from: Data(contentsOf: meshURL.appendingPathComponent("anchors.json")))
            let scene = SCNScene()
            var triangles = 0
            var parts: [MeshPart] = []
            var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var boxes: [WeightedBox] = []
            for entry in index.anchors {
                guard entry.transform.count == 16, entry.vertexCount > 0, entry.faceCount > 0 else { continue }
                let vertices = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).vertices"))
                let faces = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).faces"))
                guard vertices.count == entry.vertexCount * 12, faces.count == entry.faceCount * 12 else { continue }
                var sources = [SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: entry.vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)]
                if entry.normalsFormat != nil {
                    let normals = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).normals"))
                    if normals.count == vertices.count {
                        sources.append(SCNGeometrySource(data: normals, semantic: .normal, vectorCount: entry.vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
                    }
                }
                var classes: Data?
                if entry.classesFormat != nil {
                    let loaded = try Data(contentsOf: meshURL.appendingPathComponent("\(entry.fileStem).classes"))
                    if loaded.count == entry.faceCount { classes = loaded }
                }
                let (elements, materials) = elementsByClass(faces: faces, faceCount: entry.faceCount, classes: classes)
                let geometry = SCNGeometry(sources: sources, elements: elements)
                geometry.materials = materials
                let node = SCNNode(geometry: geometry)
                node.simdTransform = matrix(entry.transform)
                scene.rootNode.addChildNode(node)
                parts.append(MeshPart(node: node, plain: geometry, vertices: vertices, vertexCount: entry.vertexCount, faces: faces, faceCount: entry.faceCount, classes: classes, transform: node.simdTransform))
                triangles += entry.faceCount
                let (boxMin, boxMax) = node.boundingBox
                var boxLower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var boxUpper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for corner in corners(SIMD3<Float>(boxMin), SIMD3<Float>(boxMax)) {
                    let world = node.simdTransform * SIMD4<Float>(corner, 1)
                    let point = SIMD3<Float>(world.x, world.y, world.z)
                    boxLower = simd_min(boxLower, point)
                    boxUpper = simd_max(boxUpper, point)
                }
                lower = simd_min(lower, boxLower)
                upper = simd_max(upper, boxUpper)
                boxes.append(WeightedBox(lower: boxLower, upper: boxUpper, weight: entry.faceCount))
            }
            guard triangles > 0 else {
                return .failure(PlainError(message: "The capture has no mesh triangles."))
            }
            let fullSize = max(simd_length(upper - lower), 1)
            (lower, upper) = trimmedBounds(boxes) ?? (lower, upper)
            let center = (lower + upper) / 2
            let size = max(simd_length(upper - lower), 1)
            let camera = SCNCamera()
            camera.fieldOfView = orbitFieldOfView
            camera.zNear = 0.02
            camera.zFar = Double(max(size, fullSize) * 10)
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.simdPosition = center + SIMD3<Float>(0, size * 0.8, size * 0.7)
            cameraNode.simdLook(at: center, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
            scene.rootNode.addChildNode(cameraNode)
            return .success(Built(scene: scene, triangles: triangles, cameraNode: cameraNode, center: SCNVector3(center), boundsMin: lower, boundsMax: upper, parts: parts))
        } catch {
            return .failure(error)
        }
    }

    static func apply(_ mode: MeshViewer.Mode, showCeiling: Bool, showFilledFloor: Bool, parts: [MeshPart]) {
        for part in parts {
            let geometry: SCNGeometry
            switch mode {
            case .texture: geometry = part.textured ?? part.plain
            case .photo: geometry = part.photo ?? part.plain
            default: geometry = part.plain
            }
            if part.node.geometry !== geometry {
                part.node.geometry = geometry
            }
            let colored = mode == .texture && part.textured != nil
            for material in part.plain.materials {
                let classId = UInt8(material.name ?? "") ?? 0
                let hidden = (!showCeiling && classId == ceilingClass && mode != .wireframe) || (!showFilledFloor && classId == filledFloorClass)
                material.colorBufferWriteMask = hidden ? [] : .all
                material.writesToDepthBuffer = !hidden
                material.lightingModel = colored ? .constant : .lambert
                switch mode {
                case .clay:
                    material.fillMode = .fill
                    material.diffuse.contents = UIColor(white: 0.82, alpha: 1)
                case .wireframe:
                    material.fillMode = .lines
                    material.diffuse.contents = UIColor(red: 0.45, green: 0.45, blue: 1, alpha: 1)
                case .classes:
                    material.fillMode = .fill
                    material.diffuse.contents = classColors[classId] ?? UIColor.gray
                case .texture:
                    material.fillMode = .fill
                    material.diffuse.contents = colored ? UIColor.white : UIColor(white: 0.82, alpha: 1)
                case .photo:
                    material.fillMode = .fill
                    material.diffuse.contents = UIColor(white: 0.82, alpha: 1)
                }
            }
            for material in part.photo?.materials ?? [] {
                let classId = UInt8(material.name ?? "") ?? 0
                let hidden = (!showCeiling && classId == ceilingClass) || (!showFilledFloor && classId == filledFloorClass)
                material.colorBufferWriteMask = hidden ? [] : .all
                material.writesToDepthBuffer = !hidden
            }
        }
    }

    static func photoGeometry(_ output: MeshPhotoTexturer.PartOutput, material: (MeshPhotoTexturer.Group) -> SCNMaterial) -> SCNGeometry {
        let vertex = SCNGeometrySource(data: output.positions, semantic: .vertex, vectorCount: output.vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let uv = SCNGeometrySource(data: output.uvs, semantic: .texcoord, vectorCount: output.vertexCount, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for group in output.groups where group.count >= 3 {
            let indices = (group.start..<(group.start + group.count)).map { UInt32($0) }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: group.count / 3, bytesPerIndex: 4))
            materials.append(material(group))
        }
        var sources = [vertex, uv]
        if output.colors.count == output.vertexCount * 12 {
            sources.append(SCNGeometrySource(data: output.colors, semantic: .color, vectorCount: output.vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
        }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = materials
        return geometry
    }

    static func photoMaterial(classId: UInt8, image: CGImage?) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = String(classId)
        material.isDoubleSided = true
        material.lightingModel = .constant
        material.diffuse.contents = image.map { UIImage(cgImage: $0) } ?? UIColor(white: 0.6, alpha: 1)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .linear
        return material
    }

    static func texturedGeometry(plain: SCNGeometry, colors: Data, vertexCount: Int) -> SCNGeometry {
        let colorSource = SCNGeometrySource(data: colors, semantic: .color, vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geometry = SCNGeometry(sources: plain.sources + [colorSource], elements: plain.elements)
        geometry.materials = plain.materials
        return geometry
    }

    private static func elementsByClass(faces: Data, faceCount: Int, classes: Data?) -> ([SCNGeometryElement], [SCNMaterial]) {
        guard let classes else {
            return ([SCNGeometryElement(data: faces, primitiveType: .triangles, primitiveCount: faceCount, bytesPerIndex: 4)], [material(classId: 0)])
        }
        var buckets: [UInt8: Data] = [:]
        faces.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for face in 0..<faceCount {
                let classId = classes[classes.startIndex + face]
                let slice = UnsafeRawBufferPointer(rebasing: raw[(face * 12)..<(face * 12 + 12)])
                buckets[classId, default: Data()].append(contentsOf: slice)
            }
        }
        let ordered = buckets.keys.sorted()
        let elements = ordered.map { key -> SCNGeometryElement in
            let data = buckets[key] ?? Data()
            return SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: data.count / 12, bytesPerIndex: 4)
        }
        return (elements, ordered.map(material(classId:)))
    }

    private static func material(classId: UInt8) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = String(classId)
        material.isDoubleSided = true
        material.lightingModel = .lambert
        return material
    }

    struct WeightedBox {
        let lower: SIMD3<Float>
        let upper: SIMD3<Float>
        let weight: Int
    }

    static let keepShare: Float = 0.9
    static let keepMarginM: Float = 2

    static func trimmedBounds(_ boxes: [WeightedBox]) -> (SIMD3<Float>, SIMD3<Float>)? {
        let usable = boxes.filter { $0.weight > 0 }
        let total = Float(usable.reduce(0) { $0 + $1.weight })
        guard total > 0 else { return nil }
        let centers = usable.map { ($0.lower + $0.upper) / 2 }
        var middle = SIMD3<Float>.zero
        for axis in 0..<3 {
            middle[axis] = weightedValue(zip(centers, usable).map { ($0.0[axis], $0.1.weight) }, share: 0.5, total: total)
        }
        let distances = centers.map { simd_distance($0, middle) }
        let reach = weightedValue(zip(distances, usable).map { ($0.0, $0.1.weight) }, share: keepShare, total: total)
        let limit = max(reach * 2, reach + keepMarginM)
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for (box, distance) in zip(usable, distances) where distance <= limit {
            lower = simd_min(lower, box.lower)
            upper = simd_max(upper, box.upper)
        }
        guard (0..<3).allSatisfy({ upper[$0] >= lower[$0] }) else { return nil }
        return (lower, upper)
    }

    private static func weightedValue(_ entries: [(Float, Int)], share: Float, total: Float) -> Float {
        var passed: Float = 0
        let ordered = entries.sorted { $0.0 < $1.0 }
        for (value, weight) in ordered {
            passed += Float(weight)
            if passed >= total * share { return value }
        }
        return ordered.last?.0 ?? 0
    }

    private static func corners(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3(low.x, low.y, low.z), SIMD3(high.x, low.y, low.z),
            SIMD3(low.x, high.y, low.z), SIMD3(high.x, high.y, low.z),
            SIMD3(low.x, low.y, high.z), SIMD3(high.x, low.y, high.z),
            SIMD3(low.x, high.y, high.z), SIMD3(high.x, high.y, high.z)
        ]
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }
}
