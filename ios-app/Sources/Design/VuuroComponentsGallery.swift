import SwiftUI

struct VuuroComponentsGallery: View {
    @State private var showToast = false
    @State private var showSheet = false
    @State private var darkPreview = false
    @State private var textFieldValue = ""
    @State private var toggleValue = true
    @State private var offline = false
    @State private var showToastWithUndo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                section("Typography") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hero title").font(.system(size: 30, weight: .bold)).tracking(-0.9)
                        Text("Section heading").font(.system(size: 20, weight: .bold)).tracking(-0.4)
                        Text("Subsection").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                        Text("Body copy reads at fifteen points.").font(.system(size: 15)).foregroundStyle(VuuroColor.textSecondary)
                        Text("Caption text").font(.system(size: 13)).foregroundStyle(VuuroColor.textSecondary)
                        Text("MICRO LABEL").font(.system(size: 11, weight: .bold)).tracking(0.6).textCase(.uppercase).foregroundStyle(VuuroColor.textSecondary)
                    }
                }

                section("Buttons — Primary") {
                    VStack(spacing: 10) {
                        Button("Primary") { VuuroToast.shared.show("Primary tapped") }.buttonStyle(.vuuroPrimary)
                        Button("Primary Small") { VuuroToast.shared.show("Primary small") }.buttonStyle(.vuuroPrimarySmall)
                        Button("Secondary") { VuuroToast.shared.show("Secondary tapped") }.buttonStyle(.vuuroSecondary)
                        Button("Secondary Small") { VuuroToast.shared.show("Secondary small") }.buttonStyle(.vuuroSecondarySmall)
                    }
                }

                section("Buttons — Utility") {
                    VStack(spacing: 10) {
                        Button("Ghost") { VuuroToast.shared.show("Ghost tapped") }.buttonStyle(.vuuroGhost)
                        Button("Ghost Small") { VuuroToast.shared.show("Ghost small") }.buttonStyle(.vuuroGhostSmall)
                        Button("Outline") { VuuroToast.shared.show("Outline tapped") }.buttonStyle(.vuuroOutline)
                        Button("Outline Small") { VuuroToast.shared.show("Outline small") }.buttonStyle(.vuuroOutlineSmall)
                    }
                }

                section("Buttons — Destructive") {
                    VStack(spacing: 10) {
                        Button("Destructive") { VuuroToast.shared.show("Destructive tapped") }.buttonStyle(.vuuroDestructive)
                        Button("Destructive Small") { VuuroToast.shared.show("Destructive small") }.buttonStyle(.vuuroDestructiveSmall)
                        Button("Destructive Filled") { VuuroToast.shared.show("Destructive filled") }.buttonStyle(.vuuroDestructiveFilled)
                        Button("Destructive Filled Small") { VuuroToast.shared.show("Destructive filled small") }.buttonStyle(.vuuroDestructiveFilledSmall)
                    }
                }

                section("Disabled States") {
                    VStack(spacing: 10) {
                        Button("Primary disabled") {}.buttonStyle(.vuuroPrimary).disabled(true)
                        Button("Secondary disabled") {}.buttonStyle(.vuuroSecondary).disabled(true)
                        Button("Ghost disabled") {}.buttonStyle(.vuuroGhost).disabled(true)
                    }
                }

                section("Icon Button") {
                    HStack(spacing: 10) {
                        Button {
                            VuuroToast.shared.show("Icon tapped")
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(VuuroIconButtonStyle(tint: VuuroColor.danger, background: VuuroColor.dangerTint))

                        Button {
                            VuuroToast.shared.show("Icon tapped")
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(VuuroIconButtonStyle(tint: VuuroColor.textPrimary, background: VuuroColor.surfaceMuted))
                    }
                }

                section("Badges") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            VuuroBadge("Good", systemImage: "checkmark", style: .good)
                            VuuroBadge("Warning", systemImage: "exclamationmark.triangle.fill", style: .warning)
                            VuuroBadge("Info", systemImage: "info.circle", style: .info)
                        }
                        HStack(spacing: 8) {
                            VuuroBadge("Danger", systemImage: "xmark", style: .danger)
                            VuuroBadge("Neutral", style: .neutral)
                        }
                    }
                }

                section("Ribbon") {
                    VuuroRibbon(text: "FUSED")
                }

                section("Input Group") {
                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "house") {
                            TextField("Property ID", text: $textFieldValue)
                                .font(.system(size: 15))
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(VuuroColor.textPrimary)
                        }
                        VuuroInputRow(leadingIcon: "gear", label: "Dark mode") {
                            Toggle("", isOn: $toggleValue)
                                .labelsHidden()
                                .tint(VuuroColor.lime)
                        }
                        VuuroInputRow(leadingIcon: "ruler", label: "Unit", showsDivider: false) {
                            Text("Metric (m²)")
                                .font(.system(size: 13))
                                .foregroundStyle(VuuroColor.textSecondary)
                        }
                    }
                }

                section("Chips") {
                    VuuroChipRow(items: ["prop-oosterpark-14", "prop-vondel-8", "prop-prinsengracht-215"]) { _ in
                        VuuroToast.shared.show("Chip picked")
                    }
                }

                section("Section Label + Hero") {
                    VStack(alignment: .leading, spacing: 0) {
                        VuuroSectionLabel(text: "Recent activity")
                        VuuroHero(
                            greeting: "Ready to scan",
                            title: "Capture a floor plan",
                            subtitle: "Point your iPhone at the room. We'll handle the rest."
                        )
                    }
                    .background(VuuroColor.bgApp)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                section("Scan CTAs") {
                    VStack(spacing: 12) {
                        VuuroScanCTA(
                            style: .primary,
                            badgeIcon: "square",
                            badgeText: "Single room",
                            title: "Scan one room",
                            subtitle: "A quick capture. One room, one plan."
                        ) {
                            VuuroToast.shared.show("Primary CTA")
                        }

                        VuuroScanCTA(
                            style: .secondary,
                            badgeIcon: "square.grid.2x2",
                            badgeText: "Whole unit",
                            title: "Scan a whole unit",
                            subtitle: "Walk through every room. Everything merges into one floor plan."
                        ) {
                            VuuroToast.shared.show("Secondary CTA")
                        }
                    }
                }

                section("Recent Scan Card") {
                    VuuroRecentScanCard(
                        name: "Oosterpark 14, 2B",
                        meta: "Listing · Sep 17, 2026",
                        badge: "Ready"
                    ) {
                        VuuroToast.shared.show("Opened scan")
                    }
                }

                section("Quality Bar") {
                    VStack(spacing: 12) {
                        VuuroQualityBar(score: 92)
                        VuuroQualityBar(score: 79)
                        VuuroQualityBar(score: 45)
                    }
                }

                section("Room Metric Grid") {
                    VuuroRoomMetricGrid(items: [
                        .init(value: "24.6", unit: "m²", label: "Area"),
                        .init(value: "20.1", unit: "m", label: "Perimeter"),
                        .init(value: "2.6", unit: "m", label: "Height"),
                    ])
                }

                section("Info Banner") {
                    VuuroInfoBanner(text: "Terms have changed since your last scan. Review and tap I Agree to continue.")
                }

                section("Offline Banner") {
                    Button(offline ? "Hide banner" : "Show banner") {
                        offline.toggle()
                    }
                    .buttonStyle(.vuuroGhost)

                    if offline {
                        VuuroOfflineBanner(
                            message: "No connection. Changes saved locally.",
                            retryLabel: "Dismiss",
                            onRetry: { offline = false }
                        )
                        .padding(.horizontal, 20)
                    }
                }

                section("Skeleton") {
                    VStack(alignment: .leading, spacing: 8) {
                        VuuroSkeleton(cornerRadius: 6).frame(width: 160, height: 16)
                        VuuroSkeleton(cornerRadius: 6).frame(maxWidth: .infinity).frame(height: 14)
                        VuuroSkeleton(cornerRadius: 6).frame(width: 220, height: 14)
                    }
                }

                section("Card Modifier") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Vuuro card")
                            .font(.system(size: 16, weight: .bold))
                        Text("Two-layer shadow, 16pt radius.")
                            .font(.system(size: 13))
                            .foregroundStyle(VuuroColor.textSecondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vuuroCard()
                }

                section("Center View") {
                    VuuroCenterView {
                        VuuroIconBadge(
                            systemName: "checkmark",
                            tint: VuuroColor.goodText,
                            background: VuuroColor.lime.opacity(0.20)
                        )
                        Text("Room captured")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.4)
                        Text("Scan another room in this unit, or finish and attach photos and notes.")
                            .font(.system(size: 15))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                section("Capture Chrome") {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            VuuroCaptureCircleButton(
                                systemName: "xmark",
                                accessibilityLabel: "Discard"
                            ) {
                                VuuroToast.shared.show("Discard")
                            }
                            VuuroCaptureTogglePill(isOn: true) {
                                VuuroToast.shared.show("Toggle")
                            }
                            VuuroCaptureTogglePill(isOn: false) {
                                VuuroToast.shared.show("Toggle")
                            }
                        }
                        HStack(spacing: 16) {
                            VuuroScanRing(walls: 4)
                            VuuroScanHint(text: "Slowly pan around the walls")
                        }
                        HStack(spacing: 16) {
                            VuuroCaptureGuessPill(
                                typeName: "Living room",
                                onConfirm: { VuuroToast.shared.show("Confirmed") },
                                onReject: { VuuroToast.shared.show("Correction") }
                            )
                        }
                        VuuroLiveStatsRow(stats: CaptureLiveStats(walls: 4, areaM2: 18.4, heightM: 2.6))
                        HStack(spacing: 10) {
                            VuuroFinishRoomButton(label: "Finish room") {
                                VuuroToast.shared.show("Finish")
                            }
                        }
                        HStack(spacing: 10) {
                            VuuroFinishSecondaryButton(label: "Finish") {
                                VuuroToast.shared.show("Finish secondary")
                            }
                            VuuroRoomsButton(count: 3) {
                                VuuroToast.shared.show("Rooms")
                            }
                        }
                    }
                    .padding(20)
                    .background(VuuroCaptureDiskBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                section("Toast") {
                    VStack(spacing: 10) {
                        Button("Show Toast") {
                            VuuroToast.shared.show("Photo added")
                        }
                        .buttonStyle(.vuuroSecondary)

                        Button("Show Toast with Undo") {
                            VuuroToast.shared.show("Scan deleted", undoLabel: "Undo") {
                                VuuroToast.shared.show("Scan restored")
                            }
                        }
                        .buttonStyle(.vuuroPrimary)
                    }
                }

                section("Sheet") {
                    Button("Open Sheet") { showSheet = true }
                        .buttonStyle(.vuuroPrimary)
                }

                section("Error Code Card") {
                    ErrorCodeView(
                        error: AppError(
                            site: .captureUpload,
                            underlying: PlainError(message: "Couldn't reach the Scan Service.")
                        )
                    )
                }

                Spacer().frame(height: 40)
            }
            .padding(20)
        }
        .background(VuuroColor.bgApp)
        .preferredColorScheme(darkPreview ? .dark : .light)
        .vuuroToastHost()
        .vuuroSheet(isPresented: $showSheet, detents: [.medium, .large]) {
            VuuroSheet(
                title: "New scan",
                onClose: { showSheet = false }
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "house", showsDivider: false) {
                            TextField("Property ID", text: .constant(""))
                                .font(.system(size: 15))
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(VuuroColor.textPrimary)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            } footer: {
                Button("Start scanning") { showSheet = false }
                    .buttonStyle(.vuuroPrimary)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(darkPreview ? "Light" : "Dark") {
                darkPreview.toggle()
            }
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(VuuroColor.bgCard, in: Capsule())
            .padding(12)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(VuuroColor.textSecondary)
            content()
        }
    }
}

private extension VuuroBadge {
    func badgeStyleNeutralFallback() -> some View {
        self
    }
}

#Preview("Gallery") {
    VuuroComponentsGallery()
}