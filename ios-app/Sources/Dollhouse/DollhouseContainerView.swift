import SwiftUI

struct DollhouseContainerView: View {
    let rooms: [FloorPlan.Room]
    var onShowPlan: (() -> Void)? = nil

    @AppStorage("dollhouseMode") private var modeRaw: String = DollhouseMode.cutaway.rawValue
    @AppStorage("dollhouseShowFurniture") private var showFurniture: Bool = true

    @State private var scene: DollhouseScene?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var buildToken = UUID()

    private var mode: DollhouseMode {
        DollhouseMode(rawValue: modeRaw) ?? .cutaway
    }

    private var isLargePlan: Bool {
        rooms.count > DollhouseConstants.largePlanRoomThreshold
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
            } else if let scene, !scene.isEmpty {
                DollhouseSceneView(scene: scene)
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

    private func rebuild() {
        isLoading = true
        errorMessage = nil
        scene = nil
        let roomsSnapshot = rooms
        let configuration = DollhouseBuildConfiguration(
            mode: mode,
            showFurniture: showFurniture,
            performanceMode: isLargePlan
        )
        do {
            let built = try DollhouseMeshBuilder.build(rooms: roomsSnapshot, configuration: configuration)
            scene = built
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
