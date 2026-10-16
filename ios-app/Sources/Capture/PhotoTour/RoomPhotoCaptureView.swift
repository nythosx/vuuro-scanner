import SwiftUI

struct RoomPhotoCaptureOverlay: View {
    @ObservedObject var coordinator: RoomPhotoCaptureCoordinator
    let onSkip: () -> Void
    let onFinish: () -> Void

    @State private var showSkipConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomPanel
        }
        .background(Color.black.opacity(0.001))
        .alert("Skip photos for this room?", isPresented: $showSkipConfirmation) {
            Button("Skip", role: .destructive, action: onSkip)
                .accessibilityIdentifier("photoTour.skipConfirm")
            Button("Keep taking photos", role: .cancel) {}
                .accessibilityIdentifier("photoTour.skipCancel")
        } message: {
            Text(skipMessage)
        }
        .portraitLocked()
    }

    private var skipMessage: String {
        if coordinator.photoCount == 0 {
            return "No photos have been taken for this room. It will be added to the tour without photos."
        }
        return "\(coordinator.photoCount) photo\(coordinator.photoCount == 1 ? "" : "s") so far, less than the recommended \(coordinator.minimumPhotos). Photos you have already taken will be uploaded."
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                showSkipConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .accessibilityIdentifier("photoTour.cancel")
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Photos for this room")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Room \(coordinator.roomNumber)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 0)

            counterBadge
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var counterBadge: some View {
        let count = coordinator.photoCount
        let minimum = coordinator.minimumPhotos
        let met = count >= minimum
        return Text("\(count) / \(minimum)")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(met ? Color(red: 24/255, green: 24/255, blue: 27/255) : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(met ? VuuroColor.lime : Color.white.opacity(0.15), in: Capsule())
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            instruction
            coverageBar
            errorLine
            shutterRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(
            colors: [Color.black.opacity(0), Color.black.opacity(0.75), Color.black.opacity(0.95)],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    private var instruction: some View {
        Text("Take \(coordinator.minimumPhotos) to \(coordinator.maximumPhotos) photos covering the whole room. Slow pan, one photo every two steps. Cover corners, walls, floor, ceiling.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    private var coverageBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(VuuroColor.lime)
                        .frame(width: proxy.size.width * CGFloat(min(max(coordinator.coveragePercent, 0), 1)))
                }
            }
            .frame(height: 4)
            Text(String(format: "Coverage %.0f%%", coordinator.coveragePercent * 100))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = coordinator.lastError {
            Text(error)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.6, blue: 0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shutterRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Button {
                showSkipConfirmation = true
            } label: {
                Text("Skip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .accessibilityIdentifier("photoTour.skip")
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            shutterButton

            Spacer(minLength: 0)

            Button {
                onFinish()
            } label: {
                Text("Finish")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 24/255, green: 24/255, blue: 27/255))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(VuuroColor.lime, in: Capsule())
            }
            .accessibilityIdentifier("photoTour.finish")
            .buttonStyle(.plain)
            .opacity(coordinator.photoCount > 0 ? 1 : 0.5)
        }
    }

    private var shutterButton: some View {
        Button {
            Task { await coordinator.capturePhoto() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 76, height: 76)
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 64, height: 64)
                Circle()
                    .fill(Color.white)
                    .frame(width: 52, height: 52)
                if coordinator.isCapturing {
                    ProgressView().tint(.black)
                }
            }
        }
        .accessibilityIdentifier("photoTour.shutter")
        .buttonStyle(.plain)
        .disabled(coordinator.isCapturing || coordinator.isMaximumReached)
    }
}
