import SwiftUI

enum ScanInstructionsSettings {
    private static func key(_ type: ScanStartType) -> String {
        switch type {
        case .single: return "scanInstructions.seen.single"
        case .multi: return "scanInstructions.seen.multi"
        }
    }

    static func hasSeen(_ type: ScanStartType) -> Bool {
        UserDefaults.standard.bool(forKey: key(type))
    }

    static func markSeen(_ type: ScanStartType) {
        UserDefaults.standard.set(true, forKey: key(type))
    }
}

private struct ScanInstructionItem {
    let icon: String
    let title: String
    let detail: String
}

struct ScanInstructionsView: View {
    let type: ScanStartType
    let primaryLabel: String
    let onPrimary: () -> Void
    let onClose: () -> Void

    private var sheetTitle: String {
        type == .multi ? "Whole unit scan" : "Single room scan"
    }

    private var heroTitle: String {
        type == .multi ? "Walk once, capture everything." : "One room at a time."
    }

    private var heroSubtitle: String {
        type == .multi
            ? "Scan room after room in one walk. When you finish, all rooms are merged into one connected plan."
            : "Scan a room on its own. Every room you add shows as its own tile on the plan."
    }

    private var steps: [ScanInstructionItem] {
        switch type {
        case .single:
            return [
                ScanInstructionItem(icon: "", title: "Fill in the property details", detail: "Then tap Start room scan. The camera starts scanning right away."),
                ScanInstructionItem(icon: "", title: "Pan slowly around the walls", detail: "Hold the phone upright at chest height and keep each wall in view for a few seconds. The ring counts the walls found."),
                ScanInstructionItem(icon: "", title: "Cover every corner and doorway", detail: "The plan is drawn from the floor outline, so make sure it closes all the way around."),
                ScanInstructionItem(icon: "", title: "Tap Finish room", detail: "The room uploads. Then choose Scan another room, or Finish unit to add notes and photos."),
            ]
        case .multi:
            return [
                ScanInstructionItem(icon: "", title: "Start in the first room", detail: "Fill in the property details and tap Start unit scan. The camera starts scanning right away."),
                ScanInstructionItem(icon: "", title: "Scan the room slowly", detail: "Pan around all the walls and corners before you leave the room."),
                ScanInstructionItem(icon: "", title: "Tap Save & next", detail: "The room is saved on this phone and the next room starts scanning. Keep the camera up while you walk to the next room."),
                ScanInstructionItem(icon: "", title: "Repeat for every room", detail: "Tap the room counter next to Save & next to see the saved rooms, remove one to rescan it, or delete it."),
                ScanInstructionItem(icon: "", title: "Tap Finish in the last room", detail: "Finish appears once the first room is saved. The room you are scanning is included, then all rooms are merged and uploaded."),
            ]
        }
    }

    private var tips: [ScanInstructionItem] {
        let shared = [
            ScanInstructionItem(icon: "lightbulb", title: "Turn on the lights", detail: "Dim rooms, mirrors and glass walls reduce accuracy."),
            ScanInstructionItem(icon: "tortoise", title: "Move slower than feels natural", detail: "Fast pans lose corners and door frames."),
            ScanInstructionItem(icon: "ruler", title: "Large rooms: walk the walls slowly", detail: "For a big open space, follow the walls and keep the phone pointed at them. If the app says the space is too large, save what you have and scan the rest as a separate room."),
            ScanInstructionItem(icon: "iphone", title: "Keep the app open while scanning", detail: "Switching apps, a call or locking the screen stops the scan. Rooms already captured are kept and can be uploaded."),
        ]
        switch type {
        case .single:
            return shared + [
                ScanInstructionItem(icon: "building.2", title: "Set the floor", detail: "Tap Set floor at the top of the camera to note which floor the room is on."),
                ScanInstructionItem(icon: "square.grid.2x2", title: "Need rooms joined into one layout?", detail: "Rooms scanned here are not placed next to each other. Use Scan a whole unit for one connected plan."),
            ]
        case .multi:
            return shared + [
                ScanInstructionItem(icon: "building.2", title: "Set the floor when you change floors", detail: "Tap Set floor at the top of the camera. It applies to the room you are scanning and the rooms after it, until you change it."),
                ScanInstructionItem(icon: "iphone", title: "Keep the app open while scanning", detail: "Switching apps or locking the phone can interrupt the room you are scanning."),
                ScanInstructionItem(icon: "tray.and.arrow.down", title: "Interrupted? Saved rooms are kept", detail: "Start a whole unit scan again with the same property details, and you can upload the rooms you already saved."),
            ]
        }
    }

    private var avoid: [ScanInstructionItem] {
        guard type == .multi else { return [] }
        return [
            ScanInstructionItem(icon: "xmark", title: "Don't tap Finish before the last room", detail: "Finish merges and uploads the unit. To add rooms later, open the scan in History and tap Continue this scan."),
            ScanInstructionItem(icon: "xmark", title: "Don't scan the same room twice", detail: "It can create overlapping rooms. To redo a room, remove it first with the retry arrow in the room list."),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(VuuroColor.handle)
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 16)

            HStack {
                Text(LocalizedStringKey(sheetTitle))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(VuuroColor.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(VuuroColor.overlayPill.opacity(0.12), in: Circle())
                }
                .accessibilityIdentifier("scanInstructions.close")
                .accessibilityLabel(Text("Close"))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(heroTitle))
                            .font(.system(size: 24, weight: .bold))
                            .tracking(-0.5)
                            .foregroundStyle(VuuroColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(LocalizedStringKey(heroSubtitle))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(VuuroColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)

                    sectionLabel("How it works")
                    card {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            row(divider: index > 0) {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(VuuroColor.accent, in: Circle())
                            } content: {
                                itemText(step)
                            }
                        }
                    }

                    sectionLabel("Tips")
                    card {
                        ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                            row(divider: index > 0) {
                                Image(systemName: tip.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(VuuroColor.textPrimary)
                                    .frame(width: 30, height: 30)
                                    .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            } content: {
                                itemText(tip)
                            }
                        }
                    }

                    if !avoid.isEmpty {
                        sectionLabel("Avoid")
                        card {
                            ForEach(Array(avoid.enumerated()), id: \.offset) { index, item in
                                row(divider: index > 0) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(VuuroColor.danger)
                                        .frame(width: 26, height: 26)
                                        .background(VuuroColor.dangerTint, in: Circle())
                                } content: {
                                    itemText(item)
                                }
                            }
                        }
                    }

                    Spacer().frame(height: 20)
                }
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                Divider()
                Button(action: onPrimary) {
                    Text(LocalizedStringKey(primaryLabel))
                }
                .accessibilityIdentifier("scanInstructions.primary")
                .buttonStyle(.vuuroPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(VuuroColor.bgApp)
        }
        .background(VuuroColor.bgApp)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(VuuroColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(VuuroColor.bgCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
    }

    private func row<Leading: View, Content: View>(
        divider: Bool,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle()
                    .fill(VuuroColor.borderSoft)
                    .frame(height: 1)
                    .padding(.leading, 58)
                    .padding(.trailing, 16)
            }
            HStack(alignment: .top, spacing: 12) {
                leading()
                    .padding(.top, 1)
                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func itemText(_ item: ScanInstructionItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(item.title))
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(VuuroColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(item.detail))
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(VuuroColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScanHowToChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
                Text("How to scan")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ScanHowToBanner: View {
    let type: ScanStartType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
                    .frame(width: 30, height: 30)
                    .background(VuuroColor.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(type == .multi ? "How to scan a whole unit" : "How to scan a single room")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(VuuroColor.textPrimary)
                    Text(type == .multi ? "Steps, tips and what to avoid" : "Steps and tips")
                        .font(.system(size: 12))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VuuroColor.accent.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
