
import SwiftUI

enum VuuroColor {
    static let primary = Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255)      // #FF8212
    static let accentLime = Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255)   // #AFDF25
    static let accentCyan = Color(red: 46 / 255, green: 195 / 255, blue: 255 / 255)   // #2EC3FF
    static let textPrimary = Color(red: 39 / 255, green: 39 / 255, blue: 41 / 255)    // #272729
    static let surface = Color.white
    static let surfaceMuted = Color(red: 249 / 255, green: 249 / 255, blue: 251 / 255) // #F9F9FB
    static let cardBorder = Color(red: 246 / 255, green: 246 / 255, blue: 246 / 255)   // #F6F6F6
    static let danger = Color(red: 214 / 255, green: 69 / 255, blue: 62 / 255)
}

enum VuuroMetrics {
    static let cardRadius: CGFloat = 8
    static let buttonRadius: CGFloat = 6
    static let cardShadowRadius: CGFloat = 20
    static let cardShadowColor = Color(red: 131 / 255, green: 137 / 255, blue: 149 / 255).opacity(0.1)
}

enum VuuroFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func body(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct VuuroPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VuuroFont.body(17, weight: .bold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(VuuroColor.primary.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.buttonRadius, style: .continuous))
    }
}

struct VuuroSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VuuroFont.body(17, weight: .bold))
            .foregroundStyle(VuuroColor.textPrimary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(VuuroColor.accentLime.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.buttonRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == VuuroPrimaryButtonStyle {
    static var vuuroPrimary: VuuroPrimaryButtonStyle { VuuroPrimaryButtonStyle() }
}

extension ButtonStyle where Self == VuuroSecondaryButtonStyle {
    static var vuuroSecondary: VuuroSecondaryButtonStyle { VuuroSecondaryButtonStyle() }
}

/// Matches vuuro.com's card treatment: white surface, faint border, soft
/// diffuse shadow, 8pt radius.
struct VuuroCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(VuuroColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius, style: .continuous)
                    .stroke(VuuroColor.cardBorder, lineWidth: 1)
            )
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 0)
    }
}

extension View {
    func vuuroCard() -> some View {
        modifier(VuuroCardBackground())
    }
}
