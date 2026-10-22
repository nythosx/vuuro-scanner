import SwiftUI

struct RoomPhotoCaptureOverlay: View {
    @ObservedObject var coordinator: RoomPhotoCaptureCoordinator
    let onSkip: () -> Void
    let onFinish: () -> Void

    @State private var showSkipConfirmation = false
    @State private var showFinishAnywayAlert = false
    @State private var previewPhoto: PhotoPreviewItem?

    var body: some View {
        ZStack {
            LiveCameraPreview(arSession: coordinator.session)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomPanel
            }
        }
        .background(Color.black)
        .alert("Skip photos for this room?", isPresented: $showSkipConfirmation) {
            Button("Skip", role: .destructive, action: onSkip)
                .accessibilityIdentifier("photoTour.skipConfirm")
            Button("Keep taking photos", role: .cancel) {}
                .accessibilityIdentifier("photoTour.skipCancel")
        } message: {
            Text(skipMessage)
        }
        .alert("Finish anyway?", isPresented: $showFinishAnywayAlert) {
            Button("Finish", role: .destructive, action: onFinish)
                .accessibilityIdentifier("photoTour.finishAnywayConfirm")
            Button("Keep taking photos", role: .cancel) {}
                .accessibilityIdentifier("photoTour.finishAnywayCancel")
        } message: {
            Text(finishAnywayMessage)
        }
        .sheet(item: $previewPhoto) { item in
            PhotoPreviewSheet(
                image: coordinator.loadThumbnail(item.photo),
                onDelete: {
                    coordinator.deletePhoto(item.photo)
                    previewPhoto = nil
                },
                onClose: { previewPhoto = nil }
            )
        }
        .portraitLocked()
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
                Text(String(format: "Room %lld", coordinator.roomNumber))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.7), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            minimapSection
            coverageSummary
            if let hint = coordinator.coverage.nextAction {
                nextActionHint(hint)
            }
            photoStrip
            errorLine
            shutterRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var minimapSection: some View {
        if coordinator.coverage.outline.count >= 3 {
            TimelineView(.animation(minimumInterval: 0.1, paused: false)) { _ in
                CoverageMinimap(
                    outline: outlineCGPoints,
                    coverage: coordinator.coverage,
                    currentPosition: coordinator.livePositionLocal(),
                    currentHeadingDeg: coordinator.liveHeadingDeg()
                )
            }
            .frame(height: 140)
        } else {
            Text("Room outline unavailable")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var coverageSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%d%%", Int(coordinator.coverage.overallCoverage * 100)))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(coordinator.coverage.isReadyToFinish ? VuuroColor.lime : .white)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.coverage.isReadyToFinish ? "photo coverage · ready" : "photo coverage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(String(
                    format: "Position %d%% · Walls %d%%",
                    Int(coordinator.coverage.positionCoverage * 100),
                    Int(coordinator.coverage.wallCoverage * 100)
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 0)

            Text(String(
                format: "%lld photo%@",
                coordinator.photoCount,
                coordinator.photoCount == 1 ? "" : "s"
            ))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.65))
        }
        .accessibilityIdentifier("photoTour.coverageSummary")
    }

    private func nextActionHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VuuroColor.lime)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("photoTour.nextAction")
    }

    @ViewBuilder
    private var photoStrip: some View {
        if !coordinator.photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(coordinator.photos, id: \.localId) { photo in
                        photoThumbnail(photo)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("photoTour.photoStrip")
        }
    }

    private func photoThumbnail(_ photo: RoomPhotoMetadata) -> some View {
        Button {
            previewPhoto = PhotoPreviewItem(photo: photo)
        } label: {
            ZStack {
                if let thumb = coordinator.loadThumbnail(photo) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photoTour.stripItem")
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
                if coordinator.coverage.isReadyToFinish || coordinator.photoCount == 0 {
                    onFinish()
                } else {
                    showFinishAnywayAlert = true
                }
            } label: {
                Text("Finish")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(finishForeground)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(finishBackground, in: Capsule())
            }
            .accessibilityIdentifier("photoTour.finish")
            .buttonStyle(.plain)
            .disabled(coordinator.photoCount == 0)
        }
    }

    private var finishBackground: Color {
        if coordinator.photoCount == 0 { return Color.white.opacity(0.15) }
        if coordinator.coverage.isReadyToFinish { return VuuroColor.lime }
        return Color.white.opacity(0.95)
    }

    private var finishForeground: Color {
        if coordinator.photoCount == 0 { return .white.opacity(0.5) }
        return Color(red: 24/255, green: 24/255, blue: 27/255)
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

    private var skipMessage: String {
        if coordinator.photoCount == 0 {
            return "No photos have been taken for this room. It will be added to the tour without photos."
        }
        return "\(coordinator.photoCount) photo\(coordinator.photoCount == 1 ? "" : "s") so far, less than the recommended \(coordinator.minimumPhotos). Photos you have already taken will be uploaded."
    }

    private var finishAnywayMessage: String {
        let uncoveredWallCount = coordinator.coverage.uncoveredWalls.count
        let positionPct = Int(coordinator.coverage.positionCoverage * 100)
        if uncoveredWallCount > 0 {
            return "\(uncoveredWallCount) wall\(uncoveredWallCount == 1 ? "" : "s") \(uncoveredWallCount == 1 ? "hasn't" : "haven't") been photographed. The tour will be missing those views."
        }
        if positionPct < Int(RoomPhotoCoverage.readyPositionCoverage * 100) {
            return "You've walked \(positionPct)% of the room. Walking through the grey areas will make the tour richer."
        }
        return "You can finish anyway, or keep scanning for a better tour."
    }

    private var outlineCGPoints: [CGPoint] {
        coordinator.coverage.outline.map { CGPoint(x: $0.x, y: $0.y) }
    }
}

private struct PhotoPreviewItem: Identifiable {
    let photo: RoomPhotoMetadata
    var id: String { photo.localId }
}

private struct PhotoPreviewSheet: View {
    let image: UIImage?
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image)
                        .padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                        .accessibilityIdentifier("photoTour.photoPreviewClose")
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive, action: onDelete)
                        .accessibilityIdentifier("photoTour.photoPreviewDelete")
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
