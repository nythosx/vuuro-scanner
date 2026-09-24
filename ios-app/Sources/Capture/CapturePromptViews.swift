import SwiftUI

struct AnotherRoomPromptView: View {
    let roomCount: Int
    let onChoice: (Bool) -> Void

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(systemName: "checkmark", tint: VuuroColor.goodText, background: VuuroColor.lime.opacity(0.20))
            Text("Room \(roomCount) captured")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            Text("Scan another room in this unit, or finish and attach photos and notes.")
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            VStack(spacing: 10) {
                Button("Scan another room") { onChoice(true) }
                    .accessibilityIdentifier("anotherRoom.scanAnother")
                    .buttonStyle(.vuuroPrimary)
                Button("Finish unit") { onChoice(false) }
                    .accessibilityIdentifier("anotherRoom.finishUnit")
                    .buttonStyle(.vuuroSecondary)
            }
            .padding(.top, 12)
            .frame(maxWidth: 340)
        }
    }
}

struct PartialCaptureFailureView: View {
    let message: String
    let onUsePartial: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(systemName: "exclamationmark.triangle", tint: VuuroColor.warningText, background: VuuroColor.accent.opacity(0.15))
            Text("Scan interrupted")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Text("Some of this room was captured before the interruption. You can try uploading it as-is, or discard it and scan again.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            VStack(spacing: 10) {
                Button("Upload what was captured", action: onUsePartial)
                    .accessibilityIdentifier("partialCapture.upload")
                    .buttonStyle(.vuuroPrimary)
                Button("Discard and try again", action: onDiscard)
                    .accessibilityIdentifier("partialCapture.discard")
                    .buttonStyle(.vuuroDestructive)
            }
            .padding(.top, 12)
            .frame(maxWidth: 340)
        }
    }
}

struct DegenerateCaptureView: View {
    let onRescan: () -> Void

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(systemName: "viewfinder", tint: VuuroColor.accent, background: VuuroColor.accentSoft)
            Text("Keep scanning")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            Text("This room's outline came out too small or flat to use. Try scanning more slowly and cover the whole floor before tapping Done.")
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Rescan this room", action: onRescan)
                .accessibilityIdentifier("degenerateCapture.rescan")
                .buttonStyle(.vuuroPrimary)
                .padding(.top, 12)
                .frame(maxWidth: 340)
        }
    }
}

struct UploadRejectedView: View {
    let error: AppError
    let onRetryUpload: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(systemName: "exclamationmark.triangle", tint: VuuroColor.danger, background: VuuroColor.dangerTint)
            Text("Upload didn't go through")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            ErrorCodeView(error: error)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if error.isLikelyRetryable {
                Text("This room's capture is still on your device. Retry the same upload, or rescan if the room itself needs it.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                VStack(spacing: 10) {
                    Button("Retry upload", action: onRetryUpload).buttonStyle(.vuuroPrimary)
                        .accessibilityIdentifier("uploadRejected.retry")
                    Button("Rescan this room", action: onRescan).buttonStyle(.vuuroDestructive)
                        .accessibilityIdentifier("uploadRejected.rescan")
                }
                .padding(.top, 12)
                .frame(maxWidth: 340)
            } else {
                Text("The server rejected this capture's data — retrying the same upload won't change that. Rescanning this room is the way forward.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Rescan this room", action: onRescan)
                    .accessibilityIdentifier("uploadRejected.rescan")
                    .buttonStyle(.vuuroPrimary)
                    .padding(.top, 12)
                    .frame(maxWidth: 340)
            }
        }
    }
}

struct UploadProgressOverlay: View {
    let message: String
    var onCancel: (() -> Void)? = nil
    let stillWorkingAfterSeconds: Int = 5

    @State private var elapsedSeconds = 0

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(VuuroColor.accent)
            Text(elapsedSeconds >= stillWorkingAfterSeconds ? "\(message) (\(elapsedSeconds)s)" : message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VuuroColor.textPrimary)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("uploadProgress.cancel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VuuroColor.danger)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, x: 0, y: 10)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                elapsedSeconds += 1
            }
        }
    }
}