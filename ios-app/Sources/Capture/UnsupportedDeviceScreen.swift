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
  
    var onContinueWithoutScan: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lidar.disabled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("LiDAR scanning isn't available on this device")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(DeviceCapability.unsupportedReason)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let onContinueWithoutScan {
                Button("Continue without a scan", action: onContinueWithoutScan)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .padding()
    }
}
