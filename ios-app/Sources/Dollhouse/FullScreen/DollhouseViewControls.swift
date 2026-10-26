import SwiftUI

struct DollhouseCameraButtons: View {
    let theme: DollhouseTheme
    let canEnterRoom: Bool
    let onFit: () -> Void
    let onEnterRoom: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            button("arrow.up.left.and.arrow.down.right", label: "Fit the whole plan", id: "dollhouse.fit", action: onFit)
            if canEnterRoom {
                button("door.left.hand.open", label: "Go to the next room", id: "dollhouse.enterRoom", action: onEnterRoom)
            }
            button("plus.magnifyingglass", label: "Zoom in", id: "dollhouse.zoomIn", action: onZoomIn)
            button("minus.magnifyingglass", label: "Zoom out", id: "dollhouse.zoomOut", action: onZoomOut)
            button("slider.horizontal.3", label: "View settings", id: "dollhouse.viewSettings", action: onShowSettings)
        }
    }

    private func button(_ systemImage: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme == .light ? Color.black : Color.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}

struct DollhouseViewSettingsPanel: View {
    @AppStorage(DollhouseCamera.zoomSpeedKey) private var zoomSpeed: Double = DollhouseCamera.defaultZoomSpeed
    @AppStorage(DollhouseCamera.rotationSpeedKey) private var rotationSpeed: Double = DollhouseCamera.defaultRotationSpeed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    speedRow(title: "Zoom speed", value: $zoomSpeed, range: 0.5...3.0, id: "dollhouse.zoomSpeed")
                    speedRow(title: "Rotation speed", value: $rotationSpeed, range: 0.5...2.0, id: "dollhouse.rotationSpeed")
                }
                Section {
                    Button("Reset to defaults") {
                        zoomSpeed = DollhouseCamera.defaultZoomSpeed
                        rotationSpeed = DollhouseCamera.defaultRotationSpeed
                    }
                    .accessibilityIdentifier("dollhouse.resetSpeeds")
                }
            }
            .navigationTitle("View settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("dollhouse.viewSettingsDone")
                }
            }
        }
    }

    private func speedRow(title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: String(format: "%.1f\u{00D7}", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.1)
                .tint(VuuroColor.lime)
                .accessibilityIdentifier(id)
        }
    }
}
