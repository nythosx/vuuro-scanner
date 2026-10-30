import SwiftUI
import UIKit

struct RoomPhotoCaptureOverlay: View {
    @ObservedObject var coordinator: RoomPhotoCaptureCoordinator
    let onSkip: () -> Void
    let onFinish: () -> Void

    @AppStorage("photoTour.onboardingSeenForScan.v3") private var onboardingSeenForScan = ""
    @AppStorage("photoTour.standIntroSeen.v1") private var standIntroSeen = false
    @State private var showStandIntro = false
    @AppStorage("walkthroughCaptureEnabled") private var walkthroughCaptureEnabled = false
    @State private var showOnboarding = false
    @State private var showSkipConfirmation = false
    @State private var showFinishAnywayAlert = false
    @State private var previewPhoto: PhotoPreviewItem?
    @State private var showExpandedMinimap = false
    @State private var showGallery = false
    @State private var flashVisible = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0

    var body: some View {
        ZStack {
            ZStack {
                LiveCameraPreview(arSession: coordinator.session)
                    .scaleEffect(zoom)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let newZoom = max(1.0, min(2.0, baseZoom * value))
                        zoom = newZoom
                        coordinator.zoom = newZoom
                    }
                    .onEnded { _ in
                        baseZoom = zoom
                    }
            )

            Color.white
                .opacity(flashVisible ? 0.6 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                floatingHint
                    .padding(.horizontal, 20)
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                bottomPanel
            }

            if let toastMessage {
                VStack {
                    Spacer()
                    Text(toastMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.95), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
                        .padding(.bottom, 140)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showGallery {
                galleryOverlay
                    .transition(.opacity)
            }

            if showOnboarding {
                onboardingOverlay
                    .transition(.opacity)
            }

            if showStandIntro {
                standIntroOverlay
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.25), value: showGallery)
        .animation(.easeOut(duration: 0.25), value: showOnboarding)
        .animation(.easeOut(duration: 0.25), value: showStandIntro)
        .animation(.easeOut(duration: 0.3), value: toastMessage)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if onboardingSeenForScan != coordinator.captureGroupId {
                showOnboarding = true
            }
            zoom = 1.0
            baseZoom = 1.0
            coordinator.zoom = 1.0
        }
        .onDisappear {
            toastTask?.cancel()
            coordinator.stopStand()
        }
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
                    if coordinator.photos.isEmpty {
                        showGallery = false
                    }
                },
                onClose: { previewPhoto = nil }
            )
        }
        .portraitLocked()
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                showSkipConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.white.opacity(0.15), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .accessibilityIdentifier("photoTour.cancel")
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Room %lld", coordinator.roomNumber))
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                Text("Photos show tenants what this room looks like")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            }

            Spacer(minLength: 0)

            Button {
                showOnboarding = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.white.opacity(0.15), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .accessibilityLabel("How this step works")
            .accessibilityIdentifier("photoTour.help")
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.6), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    @ViewBuilder
    private var floatingHint: some View {
        if coordinator.isTrackingLimited {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Finding your position. Hold still or move slowly.")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .background(VuuroColor.danger.opacity(0.25), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("photoTour.trackingLimited")
        } else if let hint = coordinator.coverage.nextAction {
            let ready = coordinator.coverage.isReadyToFinish
            HStack(spacing: 6) {
                Image(systemName: ready ? "checkmark.circle.fill" : "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VuuroColor.lime)
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(ready ? VuuroColor.lime : Color.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .background((ready ? VuuroColor.lime.opacity(0.12) : Color.black.opacity(0.15)), in: Capsule())
            .overlay(Capsule().stroke(ready ? VuuroColor.lime.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("photoTour.nextAction")
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if showExpandedMinimap {
                expandedMinimap
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                infoRow
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            captureWarningsView
            walkthroughBanner
            if coordinator.isMaximumReached {
                photoCapBanner
            }
            errorLine
            if !coordinator.isHeldSideways {
                landscapePill
            }
            controlsRow
        }
        .animation(.easeOut(duration: 0.3), value: showExpandedMinimap)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0), location: 0),
                    .init(color: Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.85), location: 0.3),
                    .init(color: Color.black.opacity(0.95), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var landscapePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.landscape.rotate")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VuuroColor.accent)
            Text("Turn the phone sideways for wider photos")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photoTour.landscapeHint")
    }

    private var infoRow: some View {
        HStack(alignment: .center, spacing: 12) {
            miniMinimap
            coverageSummary
            photoStack
        }
    }

    @ViewBuilder
    private var miniMinimap: some View {
        Button {
            if coordinator.coverage.outline.count >= 3 {
                showExpandedMinimap = true
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                if coordinator.coverage.outline.count >= 3 {
                    liveMinimap(compact: true)
                        .padding(6)
                } else {
                    Image(systemName: "map")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(4)
            }
            .frame(width: 90, height: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open coverage map")
        .accessibilityHint("Red walls still need a photo. Grey areas show where you have not walked yet. Striped areas are near a wall and do not need walking.")
        .accessibilityIdentifier("photoTour.minimapExpand")
    }

    private var expandedMinimap: some View {
        Button {
            showExpandedMinimap = false
        } label: {
            VStack(spacing: 8) {
                liveMinimap(compact: false)
                    .frame(maxWidth: 320, maxHeight: 180)
                CoverageMinimapLegend()
                Text("Tap to close")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photoTour.minimapClose")
    }

    private func liveMinimap(compact: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: false)) { _ in
            CoverageMinimap(
                outline: outlineCGPoints,
                coverage: coordinator.coverage,
                currentPosition: coordinator.livePositionLocal(),
                currentHeadingDeg: coordinator.liveHeadingDeg(),
                compact: compact,
                positionReliable: !coordinator.isTrackingLimited,
                chromeless: true,
                coveredWallColor: .white,
                standSpots: walkthroughCaptureEnabled ? coordinator.standPositionsLocal : [],
                suggestedSpot: walkthroughCaptureEnabled && !coordinator.isCapturingStand ? coordinator.suggestedStandPositionLocal : nil
            )
        }
        .allowsHitTesting(false)
    }

    private var coverageSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%d%%", Int(coordinator.coverage.overallCoverage * 100)))
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.8)
                    .monospacedDigit()
                    .foregroundStyle(coordinator.coverage.isReadyToFinish ? VuuroColor.lime : VuuroColor.accent)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                Text(coordinator.coverage.isReadyToFinish ? LocalizedStringKey("walls photographed · ready") : LocalizedStringKey("walls photographed"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(String(
                format: vuuroLocalized("Walked %d%% (optional)"),
                Int(coordinator.coverage.walkablePositionCoverage * 100)
            ))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photoTour.coverageSummary")
    }

    private var photoStack: some View {
        Button {
            if coordinator.photos.isEmpty {
                showToast("Tap the shutter to take a photo first.")
            } else {
                showGallery = true
            }
        } label: {
            HStack(spacing: 4) {
                if coordinator.photos.isEmpty {
                    Image(systemName: "camera")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        )
                } else {
                    HStack(spacing: -20) {
                        ForEach(Array(coordinator.photos.suffix(3)), id: \.localId) { photo in
                            stackedThumbnail(photo)
                        }
                    }
                    Text("\(coordinator.photoCount)")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "%lld photo%@", coordinator.photoCount, coordinator.photoCount == 1 ? "" : "s"))
        .accessibilityIdentifier("photoTour.photoStrip")
    }

    private func stackedThumbnail(_ photo: RoomPhotoMetadata) -> some View {
        ZStack {
            Color(white: 0.2)
            if let thumb = coordinator.loadThumbnail(photo) {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }

    private var galleryOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.65)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { showGallery = false }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.bottom, 16)
                HStack {
                    Text(String(format: "%lld photo%@", coordinator.photoCount, coordinator.photoCount == 1 ? "" : "s"))
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        showGallery = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("photoTour.galleryClose")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coordinator.photos, id: \.localId) { photo in
                            galleryThumbnail(photo)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 8)
            }
            .padding(.top, 20)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity)
            .background(
                Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255),
                in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func galleryThumbnail(_ photo: RoomPhotoMetadata) -> some View {
        Button {
            previewPhoto = PhotoPreviewItem(photo: photo)
        } label: {
            ZStack {
                Color(white: 0.2)
                if let thumb = coordinator.loadThumbnail(photo) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photoTour.stripItem")
    }

    private var onboardingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(VuuroColor.accent)
                    .frame(width: 56, height: 56)
                    .background(VuuroColor.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.bottom, 16)
                Text("Photos for the tour")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .padding(.bottom, 10)
                Text("The scan measured the room's shape and size. These photos show what it looks like: tenants see them in the photo tour and as photo dots in the 3D view.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: 10) {
                    onboardingTip("rectangle.landscape.rotate", "Hold the phone sideways to fit more of a wall in each photo.")
                    onboardingTip("map", "Photograph each red wall on the map. You can finish once the walls are covered.")
                    onboardingTip("figure.walk", "Start where the scan ended and move slowly, so the dot on the map stays in the right place. Walking around is optional.")
                    onboardingTip("forward.end", "Skip if you don't need photos. The room will then show the plan and 3D only.")
                }
                .padding(.bottom, 24)
                Button {
                    onboardingSeenForScan = coordinator.captureGroupId
                    showOnboarding = false
                } label: {
                    Text("Got it")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(VuuroColor.lime, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("photoTour.onboardingDismiss")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(white: 0.2), lineWidth: 1)
            )
            .padding(24)
        }
        .accessibilityIdentifier("photoTour.onboarding")
    }

    private func onboardingTip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VuuroColor.accent)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var walkthroughBanner: some View {
        if walkthroughCaptureEnabled {
            if coordinator.isCapturingStand {
                standProgressBanner
            } else {
                VStack(spacing: 8) {
                    nextSpotPill
                    startStandButton
                }
            }
        }
    }

    private var startStandButton: some View {
        HStack(spacing: 8) {
            startStandMainButton
            Button {
                showStandIntro = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(Text(vuuroLocalized("How to take a 360 spot")))
            .accessibilityIdentifier("photoTour.standHelp")
            .buttonStyle(.plain)
        }
    }

    private var startStandMainButton: some View {
        Button {
            if standIntroSeen {
                coordinator.startStand()
            } else {
                showStandIntro = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 12, weight: .semibold))
                Text(vuuroLocalized("Start stand"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.12), in: Capsule())
        }
        .accessibilityIdentifier("photoTour.startStand")
        .buttonStyle(.plain)
    }

    private var standProgressBanner: some View {
        HStack(spacing: 12) {
            standRings
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: Self.standInstructionSymbol(coordinator.standInstruction))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(VuuroColor.lime)
                    Text(vuuroLocalized(Self.standInstructionKey(coordinator.standInstruction)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(format: vuuroLocalized("Shot %lld of %lld"), coordinator.standSectorCount, RoomPhotoCaptureCoordinator.standSectorTotal))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("photoTour.standInstruction")
            Spacer(minLength: 0)
            Button {
                coordinator.stopStand()
            } label: {
                Text(vuuroLocalized("Done"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(VuuroColor.lime, in: Capsule())
            }
            .accessibilityIdentifier("photoTour.doneStand")
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var captureWarningsView: some View {
        if !coordinator.captureWarnings.isEmpty {
            VStack(spacing: 6) {
                ForEach(coordinator.captureWarnings, id: \.self) { warning in
                    HStack(spacing: 8) {
                        Image(systemName: Self.warningSymbol(warning))
                            .font(.system(size: 13, weight: .bold))
                        Text(vuuroLocalized(Self.warningKey(warning)))
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(warning == .tooHot ? Color.white : Color.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        warning == .tooHot ? Color(red: 0.86, green: 0.2, blue: 0.18) : Color(red: 1.0, green: 0.8, blue: 0.25),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("photoTour.captureWarnings")
        }
    }

    static func warningKey(_ warning: RoomPhotoCaptureCoordinator.CaptureWarning) -> String {
        switch warning {
        case .tooHot: return "The phone is too hot. Stop and let it cool down, or tracking will fail."
        case .gettingHot: return "The phone is getting hot. Take a short break if the picture starts to stutter."
        case .tooDark: return "It is too dark. Turn on the lights for sharper photos."
        case .nearWall: return "Too close to a wall for a 360 spot. Step back a little."
        }
    }

    static func warningSymbol(_ warning: RoomPhotoCaptureCoordinator.CaptureWarning) -> String {
        switch warning {
        case .tooHot, .gettingHot: return "thermometer"
        case .tooDark: return "lightbulb.fill"
        case .nearWall: return "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private var nextSpotPill: some View {
        if coordinator.suggestedStandPositionLocal != nil {
            TimelineView(.animation(minimumInterval: 0.2, paused: false)) { _ in
                if let guide = coordinator.nextStandGuide() {
                    HStack(spacing: 8) {
                        if guide.distanceM <= RoomPhotoCaptureCoordinator.nextStandArrivedM {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(VuuroColor.lime)
                            Text(vuuroLocalized("Good spot. Start the 360 spot here."))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(VuuroColor.lime)
                                .rotationEffect(.degrees(guide.relativeDeg))
                            Text(String(format: vuuroLocalized("Next 360 spot: %.1f m"), guide.distanceM))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.3), in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("photoTour.nextSpot")
                }
            }
        }
    }

    private var standRings: some View {
        ZStack {
            standRing(RoomPhotoCaptureCoordinator.standCells(.up), diameter: 44)
            standRing(RoomPhotoCaptureCoordinator.standCells(.horizon), diameter: 33)
            standRing(RoomPhotoCaptureCoordinator.standCells(.down), diameter: 22)
            VStack(spacing: 4) {
                standPoleDot(RoomPhotoCaptureCoordinator.standCells(.zenith).lowerBound)
                standPoleDot(RoomPhotoCaptureCoordinator.standCells(.nadir).lowerBound)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private func standRing(_ cells: Range<Int>, diameter: CGFloat) -> some View {
        let count = CGFloat(cells.count)
        return ZStack {
            ForEach(Array(cells.enumerated()), id: \.element) { item in
                Circle()
                    .trim(from: CGFloat(item.offset) / count + 0.01, to: CGFloat(item.offset + 1) / count - 0.01)
                    .stroke(
                        coordinator.capturedStandSectors.contains(item.element) ? VuuroColor.lime : Color.white.opacity(0.22),
                        style: StrokeStyle(lineWidth: 3, lineCap: .butt)
                    )
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    private func standPoleDot(_ cell: Int) -> some View {
        Circle()
            .fill(coordinator.capturedStandSectors.contains(cell) ? VuuroColor.lime : Color.white.opacity(0.3))
            .frame(width: 5, height: 5)
    }

    static func standInstructionKey(_ instruction: RoomPhotoCaptureCoordinator.StandInstruction) -> String {
        switch instruction {
        case .waitTracking: return "Move the phone slowly so it can find its place"
        case .slowDown: return "Slow down a little"
        case .levelPhone: return "Hold the phone level, at eye height"
        case .turnSlowly: return "Turn slowly in place"
        case .tiltUp: return "Now tilt the phone up"
        case .tiltDownLittle: return "Tilt down a little"
        case .turnTiltedUp: return "Keep it tilted up and turn slowly"
        case .tiltDown: return "Now tilt the phone down"
        case .tiltUpLittle: return "Tilt up a little"
        case .turnTiltedDown: return "Keep it tilted down and turn slowly"
        case .pointUp: return "Point the phone straight up at the ceiling"
        case .pointDown: return "Point the phone straight down at the floor"
        case .done: return "This spot is done"
        }
    }

    static func standInstructionSymbol(_ instruction: RoomPhotoCaptureCoordinator.StandInstruction) -> String {
        switch instruction {
        case .waitTracking: return "location.magnifyingglass"
        case .slowDown: return "tortoise.fill"
        case .levelPhone: return "iphone"
        case .turnSlowly, .turnTiltedUp, .turnTiltedDown: return "arrow.triangle.2.circlepath"
        case .tiltUp, .tiltUpLittle: return "arrow.up"
        case .tiltDown, .tiltDownLittle: return "arrow.down"
        case .pointUp: return "arrow.up.to.line"
        case .pointDown: return "arrow.down.to.line"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var standIntroOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Image(systemName: "view.3d")
                    .font(.system(size: 24))
                    .foregroundStyle(VuuroColor.accent)
                    .frame(width: 56, height: 56)
                    .background(VuuroColor.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.bottom, 16)
                Text("Take a 360 spot")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .padding(.bottom, 10)
                Text("Tenants can stand here in the walk-through and look all around, including the floor and ceiling. The phone takes the photos for you.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: 10) {
                    onboardingTip("figure.stand", "Pick a spot, like the middle of the room or a doorway, and keep your feet still.")
                    onboardingTip("iphone", "Hold the phone upright at eye height, close to your body.")
                    onboardingTip("arrow.triangle.2.circlepath", "Turn slowly in place. A photo is taken each time a new part of the ring can fill.")
                    onboardingTip("arrow.up.and.down", "After the first round, tilt the phone up and turn again, then tilt it down and turn again.")
                    onboardingTip("arrow.up.to.line", "Last, point the phone straight up at the ceiling and straight down at the floor.")
                    onboardingTip("text.bubble", "Follow the line at the top of the screen. It tells you what to do next.")
                }
                .padding(.bottom, 24)
                Button {
                    standIntroSeen = true
                    showStandIntro = false
                    coordinator.startStand()
                } label: {
                    Text("Start this spot")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(VuuroColor.lime, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("photoTour.standIntroStart")
                Button {
                    showStandIntro = false
                } label: {
                    Text("Not now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("photoTour.standIntroClose")
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(white: 0.2), lineWidth: 1)
            )
            .padding(24)
        }
        .accessibilityIdentifier("photoTour.standIntro")
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

    private var controlsRow: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                showSkipConfirmation = true
            } label: {
                Text("Skip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minWidth: 70, alignment: .leading)
            }
            .accessibilityHint("Leaves this room without photos. It will show the plan and 3D only.")
            .accessibilityIdentifier("photoTour.skip")
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            shutterButton

            Spacer(minLength: 0)

            Button {
                if coordinator.coverage.isReadyToFinish || coordinator.isMaximumReached {
                    onFinish()
                } else {
                    showFinishAnywayAlert = true
                }
            } label: {
                Text("Finish")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(finishForeground)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(minWidth: 70)
                    .background(finishBackground, in: Capsule())
            }
            .accessibilityHint("Saves the photos for this room and moves on.")
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
        if coordinator.photoCount == 0 { return .white.opacity(0.4) }
        return .black
    }

    private var shutterButton: some View {
        Button {
            Task { await capture() }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3.5)
                    .frame(width: 66, height: 66)
                Circle()
                    .fill(Color.white)
                    .frame(width: 52, height: 52)
                    .scaleEffect(coordinator.isCapturing ? 0.85 : 1)
                if coordinator.isCapturing {
                    ProgressView().tint(.black)
                }
            }
            .opacity(coordinator.isMaximumReached ? 0.4 : 1)
            .animation(.easeOut(duration: 0.1), value: coordinator.isCapturing)
        }
        .accessibilityLabel("Take photo")
        .accessibilityIdentifier("photoTour.shutter")
        .buttonStyle(.plain)
        .disabled(coordinator.isCapturing || coordinator.isMaximumReached || coordinator.isCapturingStand)
    }

    @MainActor
    private func capture() async {
        withAnimation(.easeOut(duration: 0.05)) { flashVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.easeOut(duration: 0.2)) { flashVisible = false }
        }
        await coordinator.capturePhoto()
        if coordinator.isMaximumReached {
            showToast("That's the maximum of \(coordinator.maximumPhotos) photos for this room.")
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    private var skipMessage: String {
        if coordinator.photoCount == 0 {
            return vuuroLocalized("This room will be in the tour with the plan and 3D only, no photos.")
        }
        if coordinator.photoCount == 1 {
            return vuuroLocalized("The photo you took will be uploaded. Walls without a photo will be missing from the photo tour.")
        }
        return String(format: vuuroLocalized("The %lld photos you took will be uploaded. Walls without a photo will be missing from the photo tour."), coordinator.photoCount)
    }

    private var finishAnywayMessage: String {
        let uncoveredWallCount = coordinator.coverage.uncoveredWalls.count
        if uncoveredWallCount > 0 {
            return PhotoTourStrings.finishAnywayWalls(uncoveredWallCount)
        }
        return PhotoTourStrings.finishAnywayOk
    }

    private var photoCapBanner: some View {
        Text(PhotoTourStrings.photoCapBanner)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.4))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55), in: Capsule())
            .accessibilityIdentifier("photoTour.photoCapBanner")
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
