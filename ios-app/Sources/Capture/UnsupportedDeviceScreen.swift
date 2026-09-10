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
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(VuuroColor.primary)

            Text("LiDAR scanning isn't available on this device")
                .font(VuuroFont.display(19))
                .foregroundStyle(VuuroColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(DeviceCapability.unsupportedReason)
                .font(VuuroFont.body(15))
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let onGoBack {
                Button("Go back", action: onGoBack)
                    .buttonStyle(.vuuroSecondary)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}
