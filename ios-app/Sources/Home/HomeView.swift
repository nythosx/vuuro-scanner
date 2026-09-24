import SwiftUI

struct HomeView: View {
    let onStartSingle: () -> Void
    let onStartMulti: () -> Void
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onOpenTerms: () -> Void

    @State private var recentScan: ScanHistoryEntry?

    private static func metaDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = AppLanguageSettings.effectiveLocale
        return formatter
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Vuuro Scan",
                leading: { VuuroNavSpacer() },
                trailing: {
                    VuuroNavButton("Settings", action: onOpenSettings)
                        .accessibilityIdentifier("home.settings")
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroHero(
                        greeting: "Ready to scan",
                        title: "Capture a floor plan",
                        subtitle: "Point your iPhone at the room. We'll handle the rest."
                    )

                    VStack(spacing: 12) {
                        VuuroScanCTA(
                            style: .primary,
                            badgeIcon: "square",
                            badgeText: "Single room",
                            title: "Scan one room",
                            subtitle: "A quick capture. One room, one plan.",
                            action: onStartSingle
                        )
                        .accessibilityIdentifier("home.scanSingleRoom")
                        VuuroScanCTA(
                            style: .secondary,
                            badgeIcon: "square.grid.2x2",
                            badgeText: "Whole unit",
                            title: "Scan a whole unit",
                            subtitle: "Walk through every room. Everything merges into one floor plan.",
                            action: onStartMulti
                        )
                        .accessibilityIdentifier("home.scanWholeUnit")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    VuuroSectionLabel(text: "Recent activity")

                    if let recentScan {
                        VuuroRecentScanCard(
                            name: displayName(for: recentScan),
                            meta: metaLine(for: recentScan),
                            badge: "Local",
                            badgeStyle: .neutral,
                            onTap: onOpenHistory
                        )
                        .accessibilityIdentifier("home.recentScan")
                    } else {
                        Text("No scans yet on this device.")
                            .font(.system(size: 13))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .padding(.horizontal, 20)
                    }

                    Button(action: onOpenTerms) {
                        (Text("By scanning, you agree to our ").foregroundColor(VuuroColor.textSecondary)
                         + Text("Terms & Privacy Policy").foregroundColor(VuuroColor.accent)
                         + Text(".").foregroundColor(VuuroColor.textSecondary))
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                    .accessibilityIdentifier("home.terms")
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(20)

                    Spacer().frame(height: 24)
                }
            }
        }
        .background(VuuroColor.bgApp)
        .task {
            let all = await Task.detached(priority: .userInitiated) {
                ScanHistoryStore.shared.all()
            }.value
            recentScan = all.first
        }
    }

    private func displayName(for entry: ScanHistoryEntry) -> String {
        if let nickname = entry.nickname, !nickname.isEmpty {
            return nickname
        }
        return "\(entry.propertyId) — \(entry.unitId)"
    }

    private func metaLine(for entry: ScanHistoryEntry) -> String {
        "\(entry.purpose.displayName) · \(Self.metaDateFormatter().string(from: entry.createdAt))"
    }
}