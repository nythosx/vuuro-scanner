import AVFoundation
import SwiftUI
import UIKit

enum CameraAccess {
    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    static var canTakePhoto: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct CameraAccessDeniedScreen: View {
    let onGoBack: () -> Void
    var onAccessRestored: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(systemName: "camera.fill", tint: VuuroColor.accent, background: VuuroColor.accent.opacity(0.12), size: 72, iconSize: 34)
            Text("Camera access is off")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            Text("Scanning a room needs the camera. Turn it on in Settings > Vuuro Scan > Camera, then come back and start the scan again.")
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            VStack(spacing: 10) {
                Button("Open Settings") { CameraAccess.openSettings() }
                    .accessibilityIdentifier("cameraDenied.openSettings")
                    .buttonStyle(.vuuroPrimary)
                Button("Go back", action: onGoBack)
                    .accessibilityIdentifier("cameraDenied.goBack")
                    .buttonStyle(.vuuroGhostSmall)
            }
            .padding(.top, 20)
            .frame(maxWidth: 300)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && !CameraAccess.isDenied {
                onAccessRestored()
            }
        }
    }
}

struct CameraDeniedAlert: ViewModifier {
    @Binding var isPresented: Bool
    var onChooseFromLibrary: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.alert("Camera access is off", isPresented: $isPresented) {
            Button("Open Settings") { CameraAccess.openSettings() }
                .accessibilityIdentifier("cameraDeniedAlert.openSettings")
            if let onChooseFromLibrary {
                Button("Choose from Library", action: onChooseFromLibrary)
                    .accessibilityIdentifier("cameraDeniedAlert.chooseFromLibrary")
            }
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cameraDeniedAlert.cancel")
        } message: {
            Text("To take photos, turn on Camera for Vuuro Scan in Settings. You can still pick a photo from your library.")
        }
    }
}

extension View {
    func cameraDeniedAlert(isPresented: Binding<Bool>, onChooseFromLibrary: (() -> Void)? = nil) -> some View {
        modifier(CameraDeniedAlert(isPresented: isPresented, onChooseFromLibrary: onChooseFromLibrary))
    }
}
