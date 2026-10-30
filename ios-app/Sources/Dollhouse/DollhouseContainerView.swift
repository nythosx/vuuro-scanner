import SceneKit
import SwiftUI

struct DollhouseContainerView: View {
    let rooms: [FloorPlan.Room]
    var photos360: [FloorPlan.Photo360] = []
    var session: ScanSessionResponse? = nil
    var onShowPlan: (() -> Void)? = nil
    var onHotspotTapped: ((String) -> Void)? = nil
    var onOpenFullScreen: (() -> Void)? = nil

    @AppStorage("dollhouseMode") private var modeRaw: String = DollhouseMode.cutaway.rawValue
    @AppStorage("dollhouseShowFurniture") private var showFurniture: Bool = true

    @State private var camera = DollhouseCamera()
    @State private var scene: DollhouseScene?
    @State private var scnScene: SCNScene?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var buildToken = UUID()
    @State private var buildTask: Task<Void, Never>?
    @State private var photoBytesByURL: [String: Data] = [:]

    private let client = ScanServiceClient()

    private var mode: DollhouseMode {
        DollhouseMode(rawValue: modeRaw) ?? .cutaway
    }

    private var isLargePlan: Bool {
        DollhouseMeshBuilder.isLargePlan(rooms)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            viewport
            controls
            if isLargePlan {
                Text("Performance mode is on for this plan: furniture is hidden by default.")
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .padding(.horizontal, 4)
            }
            if let scene, scene.usedEstimatedHeight {
                Text("Height estimated at \(String(format: "%.1f", DollhouseConstants.defaultHeightM)) m for at least one room.")
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .padding(.horizontal, 4)
            }
            if let scene, scene.degenerateRoomCount > 0 {
                Text(verbatim: degenerateMessage(count: scene.degenerateRoomCount))
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .padding(.horizontal, 4)
            }
        }
        .task(id: buildToken) {
            rebuild()
        }
        .onChange(of: modeRaw) { _, _ in rebuild() }
        .onChange(of: showFurniture) { _, _ in rebuild() }
    }

    @ViewBuilder
    private var viewport: some View {
        Group {
            if isLoading {
                DollhousePlaceholderView(kind: .loading)
            } else if let scene, let scnScene, !scene.isEmpty {
                if let onOpenFullScreen {
                    DollhouseSceneView(scene: scene, scnScene: scnScene, theme: .light, camera: camera, interactive: false)
                        .frame(minHeight: 320)
                        .background(VuuroColor.bgInset)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Label("Open 3D", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(12)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onOpenFullScreen)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("3D floor plan"))
                        .accessibilityHint(Text("Opens the 3D view full screen."))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("dollhouse.openFullScreen")
                } else {
                    DollhouseSceneView(scene: scene, scnScene: scnScene, theme: .light, camera: camera, onHotspotTap: onHotspotTapped)
                        .frame(minHeight: 320)
                        .background(VuuroColor.bgInset)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else if let errorMessage {
                DollhousePlaceholderView(kind: .error(errorMessage), onShowPlan: onShowPlan)
            } else {
                DollhousePlaceholderView(kind: .empty, onShowPlan: onShowPlan)
            }
        }
        .padding(.horizontal, 20)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("View", selection: $modeRaw) {
                ForEach(DollhouseMode.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .accessibilityIdentifier("dollhouse.mode")
            .pickerStyle(.segmented)

            HStack(spacing: 16) {
                Toggle("Furniture", isOn: $showFurniture)
                    .accessibilityIdentifier("dollhouse.furniture")
                    .toggleStyle(.switch)
                    .tint(VuuroColor.lime)
            }
            .font(.system(size: 13))
            .foregroundStyle(VuuroColor.textPrimary)

            Text(onOpenFullScreen == nil ? "Drag to rotate · Pinch to zoom · Two-finger drag to pan" : "Tap the model to open it in 3D")
                .font(.system(size: 11))
                .foregroundStyle(VuuroColor.textSecondary)
        }
        .padding(.horizontal, 20)
    }

    private func degenerateMessage(count: Int) -> String {
        let template = count == 1
            ? vuuroLocalized("%d room couldn't be shown in 3D because its geometry was too small or flat.")
            : vuuroLocalized("%d rooms couldn't be shown in 3D because their geometry was too small or flat.")
        return String(format: template, count)
    }

    private func rebuild() {
        buildTask?.cancel()
        isLoading = true
        errorMessage = nil
        scene = nil
        scnScene = nil
        let roomsSnapshot = rooms
        let photos360Snapshot = photos360
        let configuration = DollhouseBuildConfiguration(
            mode: mode,
            showFurniture: showFurniture,
            performanceMode: isLargePlan
        )
        buildTask = Task {
            if let session, !configuration.performanceMode {
                let missing = photos360Snapshot.filter { photoBytesByURL[$0.url] == nil }
                if !missing.isEmpty {
                    PerfTrace.begin(.dollhouseTexturePrefetch)
                    let fetched = await withTaskGroup(of: (String, Data)?.self) { group in
                        for photo in missing {
                            group.addTask {
                                guard let data = try? await client.fetchPhotoData(url: photo.url, accessToken: session.accessToken) else {
                                    return nil
                                }
                                return (photo.url, data)
                            }
                        }
                        var results: [(String, Data)] = []
                        for await result in group {
                            if let result { results.append(result) }
                        }
                        return results
                    }
                    for (url, data) in fetched {
                        photoBytesByURL[url] = data
                    }
                    PerfTrace.end(.dollhouseTexturePrefetch, detail: "\(fetched.count) of \(missing.count) photos")
                }
            }
            let bytesSnapshot = photoBytesByURL
            PerfTrace.begin(.dollhouseBuild)
            do {
                let built = try await Task.detached(priority: .userInitiated) {
                    let dollhouse = try DollhouseMeshBuilder.build(rooms: roomsSnapshot, configuration: configuration, photos360: photos360Snapshot, photoBytesByURL: bytesSnapshot)
                    return BuiltDollhouse(scene: dollhouse, scnScene: DollhouseSceneBuilder.buildScene(from: dollhouse))
                }.value
                guard !Task.isCancelled else { return }
                scene = built.scene
                scnScene = built.scnScene
                PerfTrace.end(.dollhouseBuild, detail: "\(roomsSnapshot.count) rooms, \(configuration.mode.rawValue)")
            } catch {
                guard !Task.isCancelled else { return }
                PerfTrace.cancel(.dollhouseBuild)
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct BuiltDollhouse: @unchecked Sendable {
    let scene: DollhouseScene
    let scnScene: SCNScene
}
