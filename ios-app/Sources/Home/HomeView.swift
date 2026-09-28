import SwiftUI

struct HomeView: View {
    let onStartSingle: () -> Void
    let onStartMulti: () -> Void
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onOpenTerms: () -> Void
    let onResumePendingUpload: () -> Void

    @State private var recentScan: ScanHistoryEntry?
    @State private var hasPendingUpload = false

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
                            subtitle: "One room, one plan. For a quick capture by itself.",
                            action: onStartSingle
                        )
                        .accessibilityIdentifier("home.scanSingleRoom")
                        VuuroScanCTA(
                            style: .secondary,
                            badgeIcon: "square.grid.2x2",
                            badgeText: "Whole unit",
                            title: "Scan a whole unit",
                            subtitle: "Walk every room. Everything merges into one plan for the unit.",
                            action: onStartMulti
                        )
                        .accessibilityIdentifier("home.scanWholeUnit")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    if hasPendingUpload {
                        Button(action: onResumePendingUpload) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(VuuroColor.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Unfinished upload")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(VuuroColor.textPrimary)
                                    Text("Tap to resume where you left off")
                                        .font(.system(size: 12))
                                        .foregroundStyle(VuuroColor.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(VuuroColor.textTertiary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(VuuroColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(VuuroColor.accent.opacity(0.30), lineWidth: 1)
                            )
                        }
                        .accessibilityIdentifier("home.pendingUploadBanner")
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }

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
            let (all, pending) = await Task.detached(priority: .userInitiated) {
                (ScanHistoryStore.shared.all(), PendingUploadStore.load())
            }.value
            recentScan = all.first
            hasPendingUpload = pending != nil && pending?.skippedAt != nil
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
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