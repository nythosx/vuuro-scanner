import SwiftUI

struct DollhouseFullScreenTopChrome: View {
    let title: String
    let theme: DollhouseTheme
    let onClose: () -> Void
    let onToggleTheme: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme == .light ? Color.black : Color.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityIdentifier("dollhouse.close")
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme == .light ? Color.black : Color.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onToggleTheme) {
                Image(systemName: theme == .light ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme == .light ? Color.black : Color.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityIdentifier("dollhouse.themeToggle")
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

struct DollhouseFullScreenBottomChrome: View {
    let mode: DollhouseMode
    let floorSections: [DollhouseFloorSection]
    @Binding var selectedFloorIndex: Int?
    let onModeChange: (DollhouseMode) -> Void
    let onShowLayers: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if floorSections.count > 1 {
                floorSelector
            }
            HStack(spacing: 12) {
                modeSegment
                Spacer(minLength: 0)
                Button(action: onShowLayers) {
                    Label("Layers", systemImage: "square.stack.3d.up")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityIdentifier("dollhouse.layers")
                .buttonStyle(.plain)
            }
            Text("Drag to rotate · Pinch to zoom · Two-finger drag to pan")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var modeSegment: some View {
        Picker("Mode", selection: Binding(
            get: { mode },
            set: { onModeChange($0) }
        )) {
            ForEach(DollhouseMode.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("dollhouse.mode")
        .frame(maxWidth: 260)
    }

    private var floorSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedFloorIndex = nil
                } label: {
                    Text("All floors")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            selectedFloorIndex == nil
                                ? AnyShapeStyle(Color.accentColor.opacity(0.35))
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                }
                .accessibilityIdentifier("dollhouse.floor.all")
                .buttonStyle(.plain)

                ForEach(Array(floorSections.enumerated()), id: \.element.id) { index, section in
                    Button {
                        selectedFloorIndex = index
                    } label: {
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                selectedFloorIndex == index
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.35))
                                    : AnyShapeStyle(.ultraThinMaterial),
                                in: Capsule()
                            )
                    }
                    .accessibilityIdentifier("dollhouse.floor.\(index)")
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
