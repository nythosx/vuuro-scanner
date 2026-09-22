import SwiftUI
import UIKit

extension Color {
    init(light: Color, dark: Color) {
        let lightUI = UIColor(light)
        let darkUI = UIColor(dark)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkUI : lightUI
        })
    }
}

enum VuuroColor {
    static let accent = Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255)
    static let lime = Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255)
    static let danger = Color(red: 214 / 255, green: 69 / 255, blue: 62 / 255)
    static let accentCyan = Color(red: 46 / 255, green: 195 / 255, blue: 255 / 255)

    static let textPrimary = Color(
        light: Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255),
        dark: Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
    )
    static let textSecondary = Color(
        light: Color(red: 113 / 255, green: 113 / 255, blue: 122 / 255),
        dark: Color(red: 161 / 255, green: 161 / 255, blue: 170 / 255)
    )
    static let textTertiary = Color(
        light: Color(red: 180 / 255, green: 180 / 255, blue: 188 / 255),
        dark: Color(red: 107 / 255, green: 107 / 255, blue: 115 / 255)
    )

    static let bgApp = Color(
        light: Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255),
        dark: Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255)
    )
    static let bgCard = Color(
        light: .white,
        dark: Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    )
    static let bgInset = Color(
        light: Color(red: 244 / 255, green: 244 / 255, blue: 246 / 255),
        dark: Color(red: 42 / 255, green: 42 / 255, blue: 44 / 255)
    )
    static let bgInput = Color(
        light: .white,
        dark: Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    )

    static let borderSoft = Color(
        light: Color(red: 242 / 255, green: 242 / 255, blue: 244 / 255),
        dark: Color(red: 42 / 255, green: 42 / 255, blue: 44 / 255)
    )
    static let borderMed = Color(
        light: Color(red: 236 / 255, green: 236 / 255, blue: 238 / 255),
        dark: Color(red: 42 / 255, green: 42 / 255, blue: 44 / 255)
    )

    static let accentSoft = Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255).opacity(0.15)
    static let dangerTint = Color(red: 214 / 255, green: 69 / 255, blue: 62 / 255).opacity(0.14)
    static let neutralTint = Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(0.12)
    static let neutralText = Color(
        light: Color(red: 74 / 255, green: 74 / 255, blue: 78 / 255),
        dark: Color(red: 212 / 255, green: 212 / 255, blue: 216 / 255)
    )

    static let overlayInk = Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
    static let overlayPill = Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
    static let handle = Color(red: 212 / 255, green: 212 / 255, blue: 216 / 255)

    static let primary = accent
    static let accentLime = lime
    static let surface = bgCard
    static let surfaceMuted = bgApp
    static let cardBorder = borderSoft

    static let warningTint = Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255).opacity(0.15)
    static let warningText = Color(
        light: Color(red: 180 / 255, green: 90 / 255, blue: 13 / 255),
        dark: Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255)
    )
    static let goodTint = Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255).opacity(0.22)
    static let goodText = Color(
        light: Color(red: 91 / 255, green: 122 / 255, blue: 10 / 255),
        dark: Color(red: 196 / 255, green: 233 / 255, blue: 85 / 255)
    )
    static let infoTint = Color(red: 46 / 255, green: 195 / 255, blue: 255 / 255).opacity(0.15)
    static let infoText = Color(
        light: Color(red: 12 / 255, green: 126 / 255, blue: 174 / 255),
        dark: Color(red: 46 / 255, green: 195 / 255, blue: 255 / 255)
    )
}

enum VuuroMetrics {
    static let cardRadius: CGFloat = 16
    static let cardLargeRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 14
    static let buttonSmallRadius: CGFloat = 11
    static let inputRadius: CGFloat = 14
    static let chipRadius: CGFloat = 100
    static let badgeRadius: CGFloat = 100
    static let sheetRadius: CGFloat = 24
    static let cardMargin: CGFloat = 20
    static let horizontalMargin: CGFloat = 20
    static let cardShadowRadius: CGFloat = 16
    static let cardShadowTightRadius: CGFloat = 2
    static let cardShadowColor = Color.black.opacity(0.04)
    static let cardShadowTightColor = Color.black.opacity(0.03)
    static let contentSpacing: CGFloat = 12
}

enum VuuroFont {
    static let familyName = "Open Sans"

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(familyName, size: size).weight(weight)
    }
    static func body(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .custom(familyName, size: size).weight(weight)
    }
}

enum VuuroBadgeStyle {
    case info
    case warning
    case good
    case danger
    case neutral

    var tint: Color {
        switch self {
        case .info: return VuuroColor.infoTint
        case .warning: return VuuroColor.warningTint
        case .good: return VuuroColor.goodTint
        case .danger: return VuuroColor.dangerTint
        case .neutral: return VuuroColor.neutralTint
        }
    }

    var text: Color {
        switch self {
        case .info: return VuuroColor.infoText
        case .warning: return VuuroColor.warningText
        case .good: return VuuroColor.goodText
        case .danger: return VuuroColor.danger
        case .neutral: return VuuroColor.neutralText
        }
    }
}

struct VuuroBadge: View {
    let text: String
    let systemImage: String?
    let style: VuuroBadgeStyle

    init(_ text: String, systemImage: String? = nil, style: VuuroBadgeStyle) {
        self.text = text
        self.systemImage = systemImage
        self.style = style
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .bold))
        .tracking(0.1)
        .foregroundStyle(style.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(style.tint, in: Capsule())
    }
}

struct VuuroRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch = rect.width * 0.12
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width - notch, y: rect.height / 2))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

struct VuuroRibbon: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(VuuroColor.textPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .background(VuuroColor.lime, in: VuuroRibbonShape())
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
    }
}

struct VuuroPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .bold))
            .tracking(-0.2)
            .foregroundStyle(isEnabled ? Color.white : VuuroColor.textSecondary)
            .padding(.vertical, compact ? 11 : 16)
            .padding(.horizontal, compact ? 18 : 0)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? VuuroColor.accent : VuuroColor.bgInset)
            .clipShape(RoundedRectangle(cornerRadius: compact ? VuuroMetrics.buttonSmallRadius : VuuroMetrics.buttonRadius, style: .continuous))
            .shadow(color: isEnabled ? VuuroColor.accent.opacity(0.28) : .clear, radius: 20, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct VuuroSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .bold))
            .tracking(-0.2)
            .foregroundStyle(isEnabled ? Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255) : VuuroColor.textSecondary)
            .padding(.vertical, compact ? 11 : 16)
            .padding(.horizontal, compact ? 18 : 0)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? VuuroColor.lime : VuuroColor.bgInset)
            .clipShape(RoundedRectangle(cornerRadius: compact ? VuuroMetrics.buttonSmallRadius : VuuroMetrics.buttonRadius, style: .continuous))
            .shadow(color: isEnabled ? VuuroColor.lime.opacity(0.28) : .clear, radius: 20, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct VuuroGhostButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(isEnabled ? VuuroColor.textPrimary : VuuroColor.textSecondary)
            .padding(.vertical, compact ? 11 : 16)
            .padding(.horizontal, compact ? 18 : 0)
            .frame(maxWidth: .infinity)
            .background(VuuroColor.overlayPill.opacity(configuration.isPressed ? 0.16 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: compact ? VuuroMetrics.buttonSmallRadius : VuuroMetrics.buttonRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct VuuroOutlineButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(isEnabled ? VuuroColor.textPrimary : VuuroColor.textSecondary)
            .padding(.vertical, compact ? 11 : 16)
            .padding(.horizontal, compact ? 18 : 0)
            .frame(maxWidth: .infinity)
            .background(VuuroColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: compact ? VuuroMetrics.buttonSmallRadius : VuuroMetrics.buttonRadius, style: .continuous)
                    .stroke(VuuroColor.borderMed, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: compact ? VuuroMetrics.buttonSmallRadius : VuuroMetrics.buttonRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct VuuroDestructiveButtonStyle: ButtonStyle {
    var compact: Bool = false
    var filled: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: filled ? .bold : .semibold))
            .tracking(-0.2)
            .foregroundStyle(filled ? Color.white : (isEnabled ? VuuroColor.danger : VuuroColor.textSecondary))
            .padding(.vertical, compact ? 11 : 16)
            .padding(.horizontal, compact ? 18 : 0)
            .frame(maxWidth: .infinity)
            .background(filled ? VuuroColor.danger : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: compact ? VuuroMetrics.buttonSmallRadius : VuuroMetrics.buttonRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension ButtonStyle where Self == VuuroPrimaryButtonStyle {
    static var vuuroPrimary: VuuroPrimaryButtonStyle { VuuroPrimaryButtonStyle() }
    static var vuuroPrimarySmall: VuuroPrimaryButtonStyle { VuuroPrimaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == VuuroSecondaryButtonStyle {
    static var vuuroSecondary: VuuroSecondaryButtonStyle { VuuroSecondaryButtonStyle() }
    static var vuuroSecondarySmall: VuuroSecondaryButtonStyle { VuuroSecondaryButtonStyle(compact: true) }
}

extension ButtonStyle where Self == VuuroGhostButtonStyle {
    static var vuuroGhost: VuuroGhostButtonStyle { VuuroGhostButtonStyle() }
    static var vuuroGhostSmall: VuuroGhostButtonStyle { VuuroGhostButtonStyle(compact: true) }
}

extension ButtonStyle where Self == VuuroOutlineButtonStyle {
    static var vuuroOutline: VuuroOutlineButtonStyle { VuuroOutlineButtonStyle() }
    static var vuuroOutlineSmall: VuuroOutlineButtonStyle { VuuroOutlineButtonStyle(compact: true) }
}

extension ButtonStyle where Self == VuuroDestructiveButtonStyle {
    static var vuuroDestructive: VuuroDestructiveButtonStyle { VuuroDestructiveButtonStyle() }
    static var vuuroDestructiveSmall: VuuroDestructiveButtonStyle { VuuroDestructiveButtonStyle(compact: true) }
    static var vuuroDestructiveFilled: VuuroDestructiveButtonStyle { VuuroDestructiveButtonStyle(filled: true) }
    static var vuuroDestructiveFilledSmall: VuuroDestructiveButtonStyle { VuuroDestructiveButtonStyle(compact: true, filled: true) }
}

struct VuuroIconButtonStyle: ButtonStyle {
    let tint: Color
    let background: Color
    var size: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : VuuroColor.textSecondary)
            .frame(width: size, height: size)
            .background((isEnabled ? background : VuuroColor.bgInset).opacity(configuration.isPressed ? 0.6 : 1), in: Circle())
    }
}

struct VuuroCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
    }
}

extension View {
    func vuuroCard() -> some View {
        modifier(VuuroCardBackground())
    }
}