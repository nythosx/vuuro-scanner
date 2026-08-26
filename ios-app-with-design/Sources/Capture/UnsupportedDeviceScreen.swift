//
//  UnsupportedDeviceScreen.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  The designed fallback path hard constraint #5 requires. Non-Pro devices
//  must land here, never on a crash or a blank/frozen capture screen.
//

import SwiftUI

struct UnsupportedDeviceScreen: View {
  
    var onGoBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            // "lidar.disabled" is not a real SF Symbol name — confirmed live via
            // appetize.io (no camera/LiDAR in that simulator, so this screen is
            // reachable there): "No symbol named 'lidar.disabled' found in system
            // symbol set", rendering as a blank icon. exclamationmark.triangle is
            // a long-standing, certain-to-exist symbol (iOS 13+).
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(VuuroColor.primary)

            Text("LiDAR scanning isn't available on this device")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(DeviceCapability.unsupportedReason)
                .font(VuuroFont.body())
                .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let onGoBack {
                Button("Go back", action: onGoBack)
                    .buttonStyle(.vuuroPrimary)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}
