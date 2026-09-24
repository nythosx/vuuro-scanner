import SwiftUI

struct VuuroSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(VuuroColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }
}

struct VuuroHero: View {
    let greeting: String?
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let greeting {
                Text(greeting)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)
            }
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.9)
                .lineSpacing(2)
                .foregroundStyle(VuuroColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .tracking(-0.2)
                    .lineSpacing(4)
                    .foregroundStyle(VuuroColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }
}

struct VuuroChipRow: View {
    let items: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button(action: { onSelect(item) }) {
                        Text(item)
                            .font(.system(size: 13, weight: .medium))
                            .tracking(-0.1)
                            .foregroundStyle(VuuroColor.textPrimary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(VuuroColor.bgCard, in: Capsule())
                            .overlay(Capsule().stroke(VuuroColor.borderMed, lineWidth: 1.5))
                    }
                    .accessibilityIdentifier("chip.\(item)")
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }
}

struct VuuroRecentScanCard: View {
    let name: String
    let meta: String
    let badge: String
    var badgeStyle: VuuroBadgeStyle = .good
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(VuuroColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(.system(size: 13))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VuuroBadge(badge, style: badgeStyle)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vuuroCard()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

struct VuuroInfoBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(VuuroColor.accent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .tracking(-0.1)
                .lineSpacing(4)
                .foregroundStyle(VuuroColor.warningText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(VuuroColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }
}

struct VuuroCenterView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(VuuroColor.bgApp)
    }
}

struct VuuroIconBadge: View {
    let systemName: String
    let tint: Color
    let background: Color
    var size: CGFloat = 80
    var iconSize: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background, in: Circle())
    }
}