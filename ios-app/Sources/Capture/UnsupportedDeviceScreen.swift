import SwiftUI

struct UnsupportedDeviceScreen: View {
    var onGoBack: (() -> Void)? = nil

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(systemName: "exclamationmark.triangle", tint: VuuroColor.accent, background: VuuroColor.accent.opacity(0.12), size: 72, iconSize: 34)
            Text("LiDAR not available")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            Text(DeviceCapability.unsupportedReason)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if let onGoBack {
                Button("Go back", action: onGoBack)
                    .accessibilityIdentifier("unsupportedDevice.goBack")
                    .buttonStyle(.vuuroGhostSmall)
                    .padding(.top, 20)
                    .frame(maxWidth: 200)
            }
        }
    }
}