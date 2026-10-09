import SceneKit
import SwiftUI

struct DollhouseContainerView: View {
    let rooms: [FloorPlan.Room]
    var onShowPlan: (() -> Void)? = nil

    @AppStorage("dollhouseMode") private var modeRaw: String = DollhouseMode.cutaway.rawValue
    @AppStorage("dollhouseShowFurniture") private var showFurniture: Bool = true

    @State private var scene: DollhouseScene?
    @State private var scnScene: SCNScene?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var buildToken = UUID()
    @State private var buildTask: Task<Void, Never>?

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
                DollhouseSceneView(scene: scene, scnScene: scnScene)
                    .frame(minHeight: 320)
                    .background(VuuroColor.bgInset)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        let configuration = DollhouseBuildConfiguration(
            mode: mode,
            showFurniture: showFurniture,
            performanceMode: isLargePlan
        )
        PerfTrace.begin(.dollhouseBuild)
        buildTask = Task {
            do {
                let built = try await Task.detached(priority: .userInitiated) {
                    let dollhouse = try DollhouseMeshBuilder.build(rooms: roomsSnapshot, configuration: configuration)
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
