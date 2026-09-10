
import CoreText
import SwiftUI

enum VuuroColor {
    static let primary = Color(red: 255 / 255, green: 130 / 255, blue: 18 / 255)      // #FF8212
    static let accentLime = Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255)   // #AFDF25
    static let accentCyan = Color(red: 46 / 255, green: 195 / 255, blue: 255 / 255)   // #2EC3FF
    static let textPrimary = Color(red: 39 / 255, green: 39 / 255, blue: 41 / 255)    // #272729
    static let textSecondary = textPrimary.opacity(0.55)
    static let surface = Color.white
    static let surfaceMuted = Color(red: 249 / 255, green: 249 / 255, blue: 251 / 255) // #F9F9FB
    static let cardBorder = Color(red: 246 / 255, green: 246 / 255, blue: 246 / 255)   // #F6F6F6
    static let danger = Color(red: 214 / 255, green: 69 / 255, blue: 62 / 255)
    static let warningTint = primary.opacity(0.16)
    static let warningText = Color(red: 180 / 255, green: 90 / 255, blue: 13 / 255)
    static let goodTint = accentLime.opacity(0.24)
    static let goodText = Color(red: 91 / 255, green: 122 / 255, blue: 10 / 255)
    static let infoTint = accentCyan.opacity(0.16)
    static let infoText = Color(red: 12 / 255, green: 126 / 255, blue: 174 / 255)
}

enum VuuroMetrics {
    static let cardRadius: CGFloat = 8
    static let buttonRadius: CGFloat = 6
    static let badgeRadius: CGFloat = 100
    static let cardShadowRadius: CGFloat = 20
    static let cardShadowColor = Color(red: 131 / 255, green: 137 / 255, blue: 149 / 255).opacity(0.1)
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

enum VuuroFontRegistration {
    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "OpenSans-Variable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

enum VuuroBadgeStyle {
    case info
    case warning
    case good

    var tint: Color {
        switch self {
        case .info: VuuroColor.infoTint
        case .warning: VuuroColor.warningTint
        case .good: VuuroColor.goodTint
        }
    }

    var text: Color {
        switch self {
        case .info: VuuroColor.infoText
        case .warning: VuuroColor.warningText
        case .good: VuuroColor.goodText
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
            }
            Text(text)
        }
        .font(VuuroFont.body(11, weight: .bold))
        .foregroundStyle(style.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
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
            .font(VuuroFont.body(10, weight: .heavy))
            .foregroundStyle(VuuroColor.textPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .background(VuuroColor.accentLime, in: VuuroRibbonShape())
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
    }
}

struct VuuroPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VuuroFont.body(17, weight: .bold))
            .foregroundStyle(isEnabled ? .white : VuuroColor.textSecondary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? VuuroColor.primary.opacity(configuration.isPressed ? 0.85 : 1) : VuuroColor.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.buttonRadius, style: .continuous))
    }
}

struct VuuroSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VuuroFont.body(17, weight: .bold))
            .foregroundStyle(isEnabled ? VuuroColor.textPrimary : VuuroColor.textSecondary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? VuuroColor.accentLime.opacity(configuration.isPressed ? 0.7 : 1) : VuuroColor.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.buttonRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == VuuroPrimaryButtonStyle {
    static var vuuroPrimary: VuuroPrimaryButtonStyle { VuuroPrimaryButtonStyle() }
}

extension ButtonStyle where Self == VuuroSecondaryButtonStyle {
    static var vuuroSecondary: VuuroSecondaryButtonStyle { VuuroSecondaryButtonStyle() }
}

struct VuuroIconButtonStyle: ButtonStyle {
    let tint: Color
    let background: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : VuuroColor.textSecondary)
            .frame(width: 28, height: 28)
            .background((isEnabled ? background : VuuroColor.surfaceMuted).opacity(configuration.isPressed ? 0.6 : 1), in: Circle())
    }
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

@MainActor
final class VuuroToast: ObservableObject {
    static let shared = VuuroToast()

    @Published fileprivate var message: String?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String) {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            message = text
        }
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                self.message = nil
            }
        }
    }
}

private struct VuuroToastOverlay: View {
    @ObservedObject private var toast = VuuroToast.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = toast.message {
                Text(message)
                    .font(VuuroFont.body(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(VuuroColor.textPrimary, in: Capsule())
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func vuuroToastHost() -> some View {
        overlay(VuuroToastOverlay())
    }
}
