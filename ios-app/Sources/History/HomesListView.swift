import SwiftUI

struct HomesListView: View {
    let entries: [ScanHistoryEntry]
    let onOpenHome: (HomeKey) -> Void

    private var homes: [HomeAggregate] {
        HomeAggregator.aggregate(entries)
    }

    var body: some View {
        if homes.isEmpty {
            emptyState
        } else {
            ForEach(homes) { home in
                HomeCard(home: home) { onOpenHome(home.key) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VuuroColor.accent.opacity(0.10), VuuroColor.lime.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "house.lodge")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(VuuroColor.accent)
            }
            .frame(width: 100, height: 100)

            Text("No homes yet")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)

            Text("Scan a room to start building a home overview across floors.")
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct HomeCard: View {
    let home: HomeAggregate
    let onTap: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = AppLanguageSettings.effectiveLocale
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(home.key.displayName)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(VuuroColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text("\(home.floors.count) \(home.floors.count == 1 ? "floor" : "floors") \u{00B7} \(home.totalRooms) \(home.totalRooms == 1 ? "room" : "rooms")")
                            .font(.system(size: 13))
                            .foregroundStyle(VuuroColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if home.totalAreaM2 > 0 {
                        VuuroBadge(String(format: "%.1f m\u{00B2}", home.totalAreaM2), style: .info)
                    }
                }

                Rectangle()
                    .fill(VuuroColor.borderSoft)
                    .frame(height: 1)

                HStack(spacing: 6) {
                    ForEach(home.floors.prefix(4)) { floor in
                        Text(floor.displayName ?? "Unassigned")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VuuroColor.neutralText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if home.floors.count > 4 {
                        Text("+\(home.floors.count - 4)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Text("Last scanned \(Self.dateFormatter.string(from: home.latestDate))")
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        }
        .accessibilityIdentifier("homes.card.\(home.id)")
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}
