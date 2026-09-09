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
                .foregroundStyle(.secondary)

            Text("LiDAR scanning isn't available on this device")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(DeviceCapability.unsupportedReason)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let onGoBack {
                Button("Go back", action: onGoBack)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .padding()
    }
}
