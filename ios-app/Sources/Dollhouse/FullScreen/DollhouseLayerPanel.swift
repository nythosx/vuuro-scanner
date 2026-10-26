import SwiftUI

struct DollhouseLayerPanel: View {
    @Binding var visibility: DollhouseLayerVisibility
    @Environment(\.dismiss) private var dismiss

    private let rows: [DollhouseLayer] = [
        .wallsAndFloors,
        .doors,
        .windows,
        .openings,
        .furniture,
        .roomLabels,
        .hotspotMarkers,
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { layer in
                    HStack {
                        Image(systemName: iconName(for: layer))
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        Text(layer.label)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { visibility[layer] },
                            set: { visibility[layer] = $0 }
                        ))
                        .labelsHidden()
                        .tint(VuuroColor.lime)
                        .accessibilityIdentifier("dollhouse.layer.\(layer.rawValue)")
                    }
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("dollhouse.layersDone")
                }
            }
        }
    }

    private func iconName(for layer: DollhouseLayer) -> String {
        switch layer {
        case .wallsAndFloors: return "square.split.bottomrightquarter"
        case .doors: return "door.left.hand.closed"
        case .windows: return "window.vertical.closed"
        case .openings: return "rectangle.dashed"
        case .furniture: return "sofa"
        case .ceiling: return "arrow.up.square"
        case .roomLabels: return "text.bubble"
        case .hotspotMarkers: return "photo.circle"
        }
    }
}
