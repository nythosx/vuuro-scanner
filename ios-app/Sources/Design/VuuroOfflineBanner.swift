import SwiftUI

struct VuuroOfflineBanner: View {
    let message: String
    var retryLabel: String? = nil
    var onRetry: (() -> Void)? = nil

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(VuuroColor.accent)
                .frame(width: 8, height: 8)
                .shadow(color: VuuroColor.accent, radius: 10)
                .opacity(pulse ? 0.5 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retryLabel, let onRetry {
                Button(retryLabel, action: onRetry)
                    .accessibilityIdentifier("offlineBanner.retry")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(VuuroColor.lime)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(VuuroColor.overlayInk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)
    }
}

struct VuuroOfflineBannerHost: ViewModifier {
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var dismissed = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if !network.isConnected && !dismissed {
                    VuuroOfflineBanner(
                        message: "No connection. Changes saved locally.",
                        retryLabel: "Dismiss",
                        onRetry: { dismissed = true }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: network.isConnected) { _, connected in
                if connected {
                    dismissed = false
                }
            }
            .onAppear {
                NetworkMonitor.shared.start()
            }
    }
}

extension View {
    func vuuroOfflineBannerHost() -> some View {
        modifier(VuuroOfflineBannerHost())
    }
}