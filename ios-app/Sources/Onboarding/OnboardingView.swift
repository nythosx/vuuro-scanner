import SwiftUI

private struct VuuroOnboardingSlide: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let imageURL: URL?
    let fallbackColors: [Color]
}

struct OnboardingView: View {
    let onSkip: () -> Void
    let onGetStarted: () -> Void

    @State private var index = 0

    private let slides: [VuuroOnboardingSlide] = [
        VuuroOnboardingSlide(
            title: "Capture any room in minutes",
            body: "Point your iPhone, walk the room, and get a precise, shareable floor plan. No extra hardware required.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1618221195710-dd6b41faaea6?w=1200&q=80&auto=format&fit=crop"),
            fallbackColors: [
                Color(red: 0.12, green: 0.11, blue: 0.10),
                Color(red: 0.06, green: 0.06, blue: 0.07),
            ]
        ),
        VuuroOnboardingSlide(
            title: "Multi-room, one plan",
            body: "Walk through an entire unit. Vuuro Scan aligns every room into one fused floor plan automatically.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1503387762-592deb58ef4e?w=1200&q=80&auto=format&fit=crop"),
            fallbackColors: [
                Color(red: 0.06, green: 0.09, blue: 0.12),
                Color(red: 0.04, green: 0.05, blue: 0.07),
            ]
        ),
        VuuroOnboardingSlide(
            title: "Ready for your workflow",
            body: "Notes, photos, and exports designed for property professionals. Full audit trails and shareable access.",
            imageURL: URL(string: "https://images.unsplash.com/photo-1556761175-b413da4baf72?w=1200&q=80&auto=format&fit=crop"),
            fallbackColors: [
                Color(red: 0.09, green: 0.10, blue: 0.08),
                Color(red: 0.05, green: 0.05, blue: 0.06),
            ]
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            backgroundLayer
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomContent
            }
        }
        .preferredColorScheme(.dark)
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: slides[index].fallbackColors,
                startPoint: .top,
                endPoint: .bottom
            )
            if let url = slides[index].imageURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                .id(url)
                .transition(.opacity)
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0.00),
                    .init(color: .black.opacity(0.08), location: 0.22),
                    .init(color: .black.opacity(0.05), location: 0.45),
                    .init(color: .black.opacity(0.55), location: 0.72),
                    .init(color: .black.opacity(0.92), location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Text("Vuuro Scan")
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(.white)
            Spacer()
            Button("Skip", action: onSkip)
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.18), in: Capsule())
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var bottomContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(slides[index].title)
                .font(.system(size: 34, weight: .bold))
                .tracking(-1)
                .lineSpacing(2)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)

            Text(slides[index].body)
                .font(.system(size: 15))
                .tracking(-0.2)
                .lineSpacing(5)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 26)

            HStack(spacing: 6) {
                ForEach(0..<slides.count, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.white : Color.white.opacity(0.35))
                        .frame(width: i == index ? 22 : 6, height: 6)
                }
            }
            .padding(.bottom, 22)

            Button(action: advance) {
                Text(index == slides.count - 1 ? "Get started" : "Continue")
                    .font(.system(size: 16, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(VuuroColor.accent, in: Capsule())
                    .shadow(color: VuuroColor.accent.opacity(0.28), radius: 20, x: 0, y: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func advance() {
        if index < slides.count - 1 {
            withAnimation(.easeInOut(duration: 0.35)) {
                index += 1
            }
        } else {
            onGetStarted()
        }
    }
}