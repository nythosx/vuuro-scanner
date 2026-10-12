import SceneKit
import SwiftUI

struct DollhouseFullScreenView: View {
    let rooms: [FloorPlan.Room]
    let title: String
    let photos360: [FloorPlan.Photo360]
    let onClose: () -> Void
    var onHotspotTapped: ((String) -> Void)? = nil

    @AppStorage("dollhouseFullScreenTheme") private var themeRaw: String = DollhouseTheme.light.rawValue
    @AppStorage("dollhouseFullScreenMode") private var modeRaw: String = DollhouseMode.cutaway.rawValue

    @State private var visibility = DollhouseLayerVisibility()
    @State private var showLayers = false
    @State private var selectedFloorIndex: Int? = nil

    @State private var scene: DollhouseScene?
    @State private var scnScene: SCNScene?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var buildToken = UUID()
    @State private var buildTask: Task<Void, Never>?

    private var theme: DollhouseTheme {
        DollhouseTheme(rawValue: themeRaw) ?? .light
    }

    private var mode: DollhouseMode {
        DollhouseMode(rawValue: modeRaw) ?? .cutaway
    }

    private var floorSections: [DollhouseFloorSection] {
        scene?.floorSections ?? []
    }

    private var visibleRooms: [FloorPlan.Room] {
        guard let index = selectedFloorIndex, floorSections.indices.contains(index) else {
            return rooms
        }
        let section = floorSections[index]
        let allowed = Set(section.roomIds)
        return rooms.filter { allowed.contains($0.roomId) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: theme.backgroundColor).ignoresSafeArea()

            viewport

            VStack(spacing: 8) {
                DollhouseFullScreenTopChrome(
                    title: title,
                    theme: theme,
                    onClose: onClose,
                    onToggleTheme: {
                        themeRaw = theme == .light ? DollhouseTheme.dark.rawValue : DollhouseTheme.light.rawValue
                        rebuild()
                    }
                )
                Spacer(minLength: 0)
            }

            VStack {
                Spacer()
                DollhouseFullScreenBottomChrome(
                    mode: mode,
                    floorSections: floorSections,
                    selectedFloorIndex: $selectedFloorIndex,
                    onModeChange: { newMode in
                        modeRaw = newMode.rawValue
                        rebuild()
                    },
                    onShowLayers: { showLayers = true }
                )
            }
        }
        .task(id: buildToken) {
            rebuild()
        }
        .sheet(isPresented: $showLayers) {
            DollhouseLayerPanel(visibility: $visibility)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: visibility) { _, _ in rebuild() }
        .onChange(of: selectedFloorIndex) { _, _ in rebuild() }
        .statusBarHidden(true)
    }

    @ViewBuilder
    private var viewport: some View {
        if isLoading {
            ProgressView().tint(theme == .light ? .black : .white)
        } else if let scene, let scnScene, !scene.isEmpty {
            DollhouseSceneView(
                scene: scene,
                scnScene: scnScene,
                theme: theme,
                onHotspotTap: onHotspotTapped
            )
            .ignoresSafeArea()
        } else if let errorMessage {
            DollhousePlaceholderView(kind: .error(errorMessage))
                .padding(24)
        } else {
            DollhousePlaceholderView(kind: .empty)
                .padding(24)
        }
    }

    private func rebuild() {
        buildTask?.cancel()
        isLoading = true
        errorMessage = nil
        scene = nil
        scnScene = nil

        let roomsForBuild = visibleRooms
        guard !roomsForBuild.isEmpty else {
            isLoading = false
            return
        }
        let modeForBuild = mode
        let visibilityForBuild = visibility
        let themeForBuild = theme
        let largePlan = DollhouseMeshBuilder.isLargePlan(roomsForBuild)

        buildTask = Task {
            do {
                let built = try await Task.detached(priority: .userInitiated) {
                    let configuration = DollhouseBuildConfiguration(
                        mode: modeForBuild,
                        showFurniture: visibilityForBuild.furniture,
                        performanceMode: largePlan
                    )
                    let dollhouse = try DollhouseMeshBuilder.build(rooms: roomsForBuild, configuration: configuration, photos360: photos360)
                    let scene = DollhouseSceneBuilder.buildScene(
                        from: dollhouse,
                        visibility: visibilityForBuild,
                        theme: themeForBuild
                    )
                    return BuiltDollhouse(scene: dollhouse, scnScene: scene)
                }.value
                guard !Task.isCancelled else { return }
                scene = built.scene
                scnScene = built.scnScene
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

private struct BuiltDollhouse: @unchecked Sendable {
    let scene: DollhouseScene
    let scnScene: SCNScene
}
