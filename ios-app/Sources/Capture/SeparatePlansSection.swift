import SwiftUI

struct PlanTarget: Hashable {
    let title: String
    let roomId: String?
    let floor: String?
}

struct SeparatePlansSection: View {
    let rooms: [FloorPlan.Room]
    let loadingTarget: PlanTarget?
    let onOpen: (PlanTarget) -> Void

    private var sections: [RoomFloorSection] {
        RoomFloorSection.sections(for: rooms)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Separate plans")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(VuuroColor.textSecondary)
            Text("One plan per floor, and each room on its own.")
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)

            ForEach(sections) { section in
                sectionRows(section, showsFloorRow: sections.count > 1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func sectionRows(_ section: RoomFloorSection, showsFloorRow: Bool) -> some View {
        if showsFloorRow {
            let floorName = section.rooms.first?.floor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = section.title ?? floorName
            planRow(
                PlanTarget(title: title, roomId: nil, floor: floorName),
                subtitle: String(format: vuuroLocalized("Whole floor · %d rooms"), section.rooms.count),
                icon: "square.grid.2x2",
                identifier: "plans.floor.\(floorName)"
            )
        }
        ForEach(section.rooms, id: \.roomId) { room in
            planRow(
                PlanTarget(title: room.label, roomId: room.roomId, floor: nil),
                subtitle: nil,
                icon: "square",
                identifier: "plans.room.\(room.roomId)"
            )
        }
    }

    private func planRow(_ target: PlanTarget, subtitle: String?, icon: String, identifier: String) -> some View {
        Button {
            onOpen(target)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VuuroColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(VuuroColor.textSecondary)
                    }
                }
                Spacer()
                if loadingTarget == target {
                    ProgressView().tint(VuuroColor.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VuuroColor.textTertiary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingTarget != nil)
        .accessibilityIdentifier(identifier)
    }
}
