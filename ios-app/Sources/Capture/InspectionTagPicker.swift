import SwiftUI

struct InspectionTagPicker: View {
    @Binding var selected: Set<InspectionTag>
    var compact: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(InspectionTag.allCases) { tag in
                    chip(for: tag)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(for tag: InspectionTag) -> some View {
        let isOn = selected.contains(tag)
        return Button {
            if isOn { selected.remove(tag) } else { selected.insert(tag) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(tag.displayName)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? VuuroColor.accent : VuuroColor.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(isOn ? VuuroColor.accent.opacity(0.12) : VuuroColor.bgInset)
            .overlay(
                Capsule().stroke(isOn ? VuuroColor.accent.opacity(0.4) : VuuroColor.borderMed, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .accessibilityIdentifier("inspectionTag.\(tag.rawValue)")
        .buttonStyle(.plain)
    }
}

struct InspectionTagChips: View {
    let tags: [String]

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { value in
                        Text(label(for: value))
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.2)
                            .foregroundStyle(VuuroColor.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(VuuroColor.accent.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    private func label(for value: String) -> String {
        InspectionTag(rawValue: value)?.displayName ?? value
    }
}
