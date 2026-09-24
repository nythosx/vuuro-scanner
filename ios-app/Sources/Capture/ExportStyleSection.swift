import SwiftUI

struct ExportStyleSection: View {
    @Binding var style: ExportStyleSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export style")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(VuuroColor.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Plan type", selection: $style.planType) {
                    ForEach(ExportPlanType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .accessibilityIdentifier("exportStyle.planType")
                .pickerStyle(.segmented)
                Text(style.planType.explanation + " Applies to every export from this phone once you save.")
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if style.planType == .fullReport {
                fullReportOptions
            }
        }
    }

    private var fullReportOptions: some View {
        VuuroInputGroup {
            VuuroInputRow(leadingIcon: "shoeprints.fill", label: "Show walk path", showsDivider: true) {
                Toggle("", isOn: $style.showWalkPath)
                    .accessibilityIdentifier("exportStyle.walkPath")
                    .labelsHidden()
                    .tint(VuuroColor.lime)
            }

            VuuroInputRow(leadingIcon: "rectangle.portrait.rotate", label: "Room orientation", showsDivider: true) {
                Picker("", selection: $style.orientation) {
                    Text("As scanned").tag("as_captured")
                    Text("Longest wall horizontal").tag("longest_horizontal")
                }
                .accessibilityIdentifier("exportStyle.orientation")
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(VuuroColor.textPrimary)
            }

            VuuroInputRow(leadingIcon: "paintpalette", label: "Room color", showsDivider: true) {
                Picker("", selection: $style.roomFill) {
                    Text("Tinted").tag("default")
                    Text("White").tag("white")
                }
                .accessibilityIdentifier("exportStyle.roomColor")
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(VuuroColor.textPrimary)
            }

            VuuroInputRow(leadingIcon: "sofa", label: "Show furniture", showsDivider: style.showFurniture) {
                Toggle("", isOn: $style.showFurniture)
                    .accessibilityIdentifier("exportStyle.furniture")
                    .labelsHidden()
                    .tint(VuuroColor.lime)
            }

            if style.showFurniture {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Furniture to show")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VuuroColor.textSecondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(ExportStyleSettings.allFurnitureCategories, id: \.self) { cat in
                            furnitureChip(cat)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func furnitureChip(_ category: String) -> some View {
        let isOn = style.furnitureCategories.contains(category)
        return Button {
            if isOn {
                style.furnitureCategories.remove(category)
            } else {
                style.furnitureCategories.insert(category)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(ExportStyleSettings.furnitureLabel(for: category))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? VuuroColor.textPrimary : VuuroColor.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? VuuroColor.accent.opacity(0.10) : VuuroColor.bgInset)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isOn ? VuuroColor.accent.opacity(0.5) : VuuroColor.borderMed, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityIdentifier("exportStyle.furniture.\(category)")
        .buttonStyle(.plain)
    }
}
