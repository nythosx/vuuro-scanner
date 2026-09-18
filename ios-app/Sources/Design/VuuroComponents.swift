import SwiftUI

struct VuuroInputGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.inputRadius, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
    }
}

struct VuuroInputRow<Trailing: View>: View {
    var leadingIcon: String? = nil
    var label: String? = nil
    var showsDivider: Bool = true
    let trailing: Trailing

    init(
        leadingIcon: String? = nil,
        label: String? = nil,
        showsDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leadingIcon = leadingIcon
        self.label = label
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .frame(width: 22, height: 22)
            }
            if let label {
                Text(label)
                    .font(.system(size: 15))
                    .tracking(-0.2)
                    .foregroundStyle(VuuroColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            } else {
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(VuuroColor.borderSoft).frame(height: 1)
            }
        }
    }
}

struct VuuroScanCTA: View {
    enum Style { case primary, secondary }

    let style: Style
    let badgeIcon: String
    let badgeText: String
    let title: String
    let subtitle: String
    let action: () -> Void

    private var background: LinearGradient {
        switch style {
        case .primary:
            return LinearGradient(
                colors: [
                    Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255),
                    Color(red: 255 / 255, green: 154 / 255, blue: 61 / 255),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            return LinearGradient(
                colors: [
                    Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255),
                    Color(red: 196 / 255, green: 233 / 255, blue: 85 / 255),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shadowColor: Color {
        switch style {
        case .primary: return Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255).opacity(0.30)
        case .secondary: return Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255).opacity(0.26)
        }
    }

    private var titleColor: Color {
        style == .primary ? .white : Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
    }

    private var subtitleColor: Color {
        style == .primary
            ? Color.white.opacity(0.88)
            : Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255).opacity(0.72)
    }

    private var badgeBackground: Color {
        style == .primary ? Color.white.opacity(0.20) : Color.white.opacity(0.38)
    }

    private var badgeForeground: Color {
        style == .primary ? .white : Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: badgeIcon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(badgeBackground, in: Capsule())
                .foregroundStyle(badgeForeground)
                .padding(.bottom, 14)

                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(titleColor)
                    .padding(.bottom, 6)

                Text(subtitle)
                    .font(.system(size: 13))
                    .tracking(-0.1)
                    .foregroundStyle(subtitleColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.11))
                    .frame(width: 160, height: 160)
                    .offset(x: 40, y: -40)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: shadowColor, radius: 30, x: 0, y: 10)
        }
        .buttonStyle(VuuroScanCTAPressStyle())
    }
}

private struct VuuroScanCTAPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct VuuroQualityBar: View {
    let score: Int
    var maxScore: Int = 100

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(VuuroColor.borderSoft)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [VuuroColor.accent, VuuroColor.lime],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: proxy.size.width * CGFloat(min(max(score, 0), maxScore)) / CGFloat(maxScore))
                }
            }
            .frame(height: 5)

            Text("\(score)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(VuuroColor.textPrimary)
        }
    }
}

struct VuuroRoomMetricGrid: View {
    struct Item: Identifiable {
        let id = UUID()
        let value: String
        let unit: String?
        let label: String

        init(value: String, unit: String? = nil, label: String) {
            self.value = value
            self.unit = unit
            self.label = label
        }
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                VStack(spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(item.value)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(VuuroColor.textPrimary)
                        if let unit = item.unit {
                            Text(unit)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(VuuroColor.textSecondary)
                        }
                    }
                    Text(item.label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(VuuroColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(VuuroColor.bgCard)
            }
        }
        .background(VuuroColor.borderSoft)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct VuuroSkeleton: View {
    var cornerRadius: CGFloat = 8
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(VuuroColor.borderSoft)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, VuuroColor.borderMed, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: animate ? proxy.size.width : -proxy.size.width * 0.6)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}