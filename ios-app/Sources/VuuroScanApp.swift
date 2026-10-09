import ImageIO
import PhotosUI
import RoomPlan
import SwiftUI
import UIKit

@main
struct VuuroScanApp: App {
    @UIApplicationDelegateAdaptor(VuuroAppDelegate.self) private var appDelegate
    @AppStorage(AppLanguageSettings.storageKey) private var appLanguageRaw: String = AppLanguage.system.rawValue

    init() {
        PerfTrace.begin(.launchToHome)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetOnboarding") {
            UserDefaults.standard.removeObject(forKey: OnboardingKeys.hasCompleted)
            UserDefaults.standard.removeObject(forKey: OnboardingKeys.version)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetState") {
            PendingUploadStore.clear()
            WalkthroughStore.clear()
        }
        #endif
        DispatchQueue.global(qos: .utility).async {
            KeychainTokenStore.resetIfReinstalled()
        }
    }

    var body: some Scene {
        WindowGroup {
            VuuroRootView()
                .tint(VuuroColor.accent)
                .environment(\.locale, AppLanguage(rawValue: appLanguageRaw)?.locale ?? Locale.autoupdatingCurrent)
        }
    }
}

private enum OnboardingKeys {
    static let hasCompleted = "hasCompletedOnboarding"
    static let version = "onboardingCompletedVersion"
    static let currentVersion = 2
}

struct VuuroRootView: View {
    @AppStorage(OnboardingKeys.hasCompleted) private var hasCompletedOnboarding = false
    @AppStorage(OnboardingKeys.version) private var onboardingVersion = 0
    @AppStorage("darkModeEnabled") private var darkMode = false

    private var onboardingNeeded: Bool {
        !hasCompletedOnboarding || onboardingVersion < OnboardingKeys.currentVersion
    }

    var body: some View {
        Group {
            if !onboardingNeeded {
                NavigationStack {
                    ScanFlowView()
                        .background(VuuroColor.bgApp)
                }
            } else {
                OnboardingFlowView {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hasCompletedOnboarding = true
                        onboardingVersion = OnboardingKeys.currentVersion
                    }
                }
            }
        }
        .preferredColorScheme(darkMode ? .dark : .light)
        .onAppear {
            if onboardingNeeded { PerfTrace.cancel(.launchToHome) }
        }
        .vuuroToastHost()
        .vuuroOfflineBannerHost()
    }
}

struct OnboardingFlowView: View {
    enum Stage { case onboarding, permissions }

    let onComplete: () -> Void
    @State private var stage: Stage = .onboarding

    var body: some View {
        switch stage {
        case .onboarding:
            OnboardingView(
                onSkip: onComplete,
                onGetStarted: { stage = .permissions }
            )
        case .permissions:
            PermissionsView(
                onBack: { stage = .onboarding },
                onContinue: onComplete
            )
        }
    }
}

struct ScanFlowView: View {
    private enum Stage {
        case home
        case resumingUpload(PendingUploadState)
        case capturing(identity: ScanIdentity, session: ScanSessionResponse?, attempt: UUID)
        case multiRoomCapturing(identity: ScanIdentity, session: ScanSessionResponse?, attempt: UUID)
        case noteOnly(identity: ScanIdentity)
        case attachments(session: ScanSessionResponse, floorPlan: FloorPlan, identity: ScanIdentity)
        case summary(session: ScanSessionResponse, floorPlan: FloorPlan)
        case error(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
        case multiRoomError(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
    }

    @State private var stage: Stage
    @State private var showStartSheet = false
    @State private var startType: ScanStartType = .single
    @State private var showScanInstructions = false
    @State private var openSetupAfterInstructions = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showTerms = false
    @State private var showDiagnostics = false
    @AppStorage(AppLanguageSettings.storageKey) private var appLanguageRaw: String = AppLanguage.system.rawValue

    init() {
        if let pending = PendingUploadStore.load(), pending.skippedAt == nil {
            _stage = State(initialValue: .resumingUpload(pending))
        } else {
            _stage = State(initialValue: .home)
        }
    }

    var body: some View {
        Group {
            switch stage {
            case .home:
                HomeView(
                    onStartSingle: {
                        beginStart(.single)
                    },
                    onStartMulti: {
                        beginStart(.multi)
                    },
                    onOpenSettings: { showSettings = true },
                    onOpenHistory: { showHistory = true },
                    onOpenTerms: { showTerms = true },
                    onResumePendingUpload: {
                        if let pending = PendingUploadStore.load() {
                            stage = .resumingUpload(pending)
                        }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)

            case .resumingUpload(let pending):
                PendingUploadRecoveryView(
                    state: pending,
                    onFinished: { session, floorPlan in
                        stage = .attachments(session: session, floorPlan: floorPlan, identity: pending.identity)
                    },
                    onDiscarded: { stage = .home },
                    onSkipped: {
                        PendingUploadStore.markSkipped()
                        stage = .home
                    }
                )
                .toolbar(.hidden, for: .navigationBar)

            case .capturing(let identity, let session, let attempt):
                RoomCaptureFlowStep(
                    identity: identity,
                    existingSession: session
                ) { session, floorPlan, addAnotherRoom in
                    if addAnotherRoom {
                        stage = .capturing(identity: identity, session: session, attempt: UUID())
                    } else {
                        stage = .attachments(session: session, floorPlan: floorPlan, identity: identity)
                    }
                } onError: { appError, sessionToResume in
                    stage = .error(appError, identity: identity, existingSession: sessionToResume)
                } onGoBack: {
                    PendingUploadStore.clear()
                    stage = .home
                } onDiscardRoom: {
                    PendingUploadStore.clear()
                    if let session {
                        stage = .capturing(identity: identity, session: session, attempt: UUID())
                    } else {
                        stage = .home
                    }
                }
                .id(attempt)
                .toolbar(.hidden, for: .navigationBar)

            case .multiRoomCapturing(let identity, let session, let attempt):
                MultiRoomCaptureFlowView(
                    identity: identity,
                    existingSession: session
                ) { session, floorPlan in
                    stage = .attachments(session: session, floorPlan: floorPlan, identity: identity)
                } onError: { appError, sessionToResume in
                    stage = .multiRoomError(appError, identity: identity, existingSession: sessionToResume)
                } onGoBack: {
                    PendingUploadStore.clear()
                    stage = .home
                }
                .id(attempt)
                .toolbar(.hidden, for: .navigationBar)

            case .noteOnly(let identity):
                NoteOnlyFlowStep(
                    identity: identity,
                    onFinished: { session, floorPlan in
                        stage = .attachments(session: session, floorPlan: floorPlan, identity: identity)
                    },
                    onGoBack: {
                        stage = .home
                    }
                )
                .toolbar(.hidden, for: .navigationBar)

            case .attachments(let session, let floorPlan, let identity):
                AttachmentsScreen(
                    session: session,
                    floorPlan: floorPlan
                ) { updated in
                    stage = .summary(session: session, floorPlan: updated)
                } onAddRoom: {
                    stage = .capturing(identity: identity, session: session, attempt: UUID())
                } onBack: {
                    PendingUploadStore.clear()
                    DraftStore.clearAll(sessionId: session.id)
                    stage = .home
                }
                .toolbar(.hidden, for: .navigationBar)

            case .summary(let session, let floorPlan):
                ResultSummaryView(session: session, floorPlan: floorPlan) {
                    DraftStore.clearAll(sessionId: session.id)
                    VuuroToast.shared.show(vuuroLocalized("Scan saved to history"))
                    stage = .home
                }
                .toolbar(.hidden, for: .navigationBar)

            case .error(let appError, let identity, let existingSession):
                ErrorView(error: appError) {
                    if let pending = PendingUploadStore.load(), pending.skippedAt == nil, pending.identity == identity {
                        stage = .resumingUpload(pending)
                    } else {
                        stage = .capturing(identity: identity, session: existingSession, attempt: UUID())
                    }
                }
                .toolbar(.hidden, for: .navigationBar)

            case .multiRoomError(let appError, let identity, let existingSession):
                ErrorView(error: appError) {
                    if let pending = PendingUploadStore.load(), pending.skippedAt == nil, pending.identity == identity {
                        stage = .resumingUpload(pending)
                    } else {
                        stage = .multiRoomCapturing(identity: identity, session: existingSession, attempt: UUID())
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .sheet(isPresented: $showStartSheet) {
            StartScanSheet(
                type: startType,
                onCancel: { showStartSheet = false },
                onStart: { identity in
                    showStartSheet = false
                    if startType == .multi {
                        stage = .multiRoomCapturing(identity: identity, session: nil, attempt: UUID())
                    } else {
                        stage = .capturing(identity: identity, session: nil, attempt: UUID())
                    }
                },
                onStartNoteOnly: { identity in
                    showStartSheet = false
                    stage = .noteOnly(identity: identity)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(VuuroMetrics.sheetRadius)
        }
        .sheet(isPresented: $showScanInstructions, onDismiss: {
            if openSetupAfterInstructions {
                openSetupAfterInstructions = false
                showStartSheet = true
            }
        }) {
            ScanInstructionsView(
                type: startType,
                primaryLabel: "Got it, set up the scan",
                onPrimary: {
                    ScanInstructionsSettings.markSeen(startType)
                    openSetupAfterInstructions = true
                    showScanInstructions = false
                },
                onClose: {
                    ScanInstructionsSettings.markSeen(startType)
                    showScanInstructions = false
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(VuuroMetrics.sheetRadius)
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView(
                onBack: { showSettings = false },
                onOpenTerms: { showTerms = true },
                onOpenDiagnostics: { showDiagnostics = true }
            )
            .toolbar(.hidden, for: .navigationBar)
        }
        .navigationDestination(isPresented: $showHistory) {
            ScanHistoryView(
                onResumeToAddRoom: { entry, continueAsUnit in
                    showHistory = false
                    if continueAsUnit {
                        stage = .multiRoomCapturing(
                            identity: entry.asResumableIdentity(),
                            session: entry.asResumableSession(),
                            attempt: UUID()
                        )
                    } else {
                        stage = .capturing(
                            identity: entry.asResumableIdentity(),
                            session: entry.asResumableSession(),
                            attempt: UUID()
                        )
                    }
                },
                onAttachToSession: { entry, floorPlan in
                    showHistory = false
                    stage = .attachments(
                        session: entry.asResumableSession(),
                        floorPlan: floorPlan,
                        identity: entry.asResumableIdentity()
                    )
                },
                onAddRoomsToHome: { identity in
                    showHistory = false
                    stage = .multiRoomCapturing(identity: identity, session: nil, attempt: UUID())
                }
            )
        }
        .navigationDestination(isPresented: $showTerms) {
            TermsAndPrivacyView()
        }
        .navigationDestination(isPresented: $showDiagnostics) {
            DiagnosticsLogView()
        }
    }

    private func beginStart(_ type: ScanStartType) {
        startType = type
        if ScanInstructionsSettings.hasSeen(type) {
            showStartSheet = true
        } else {
            showScanInstructions = true
        }
    }
}

private struct RoomCaptureFlowStep: View {
    let identity: ScanIdentity
    let existingSession: ScanSessionResponse?
    let onRoomCaptured: (ScanSessionResponse, FloorPlan, _ addAnotherRoom: Bool) -> Void
    let onError: (AppError, ScanSessionResponse?) -> Void
    let onGoBack: () -> Void
    let onDiscardRoom: () -> Void

    @StateObject private var coordinator = CaptureCoordinator()
    @State private var isUploading = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var justCaptured: (session: ScanSessionResponse, floorPlan: FloorPlan)?
    @State private var didRequestStop = false
    @State private var showMissingOpeningsPrompt = false
    @State private var missingOpenings: CaptureLiveStats.MissingOpenings = .doorsAndWindows
    @State private var partialCaptureFailureMessage: String?
    @State private var isUploadingPartialCapture = false
    @State private var showDiscardConfirmation = false
    @State private var isDegenerateCapture = false
    @State private var uploadRejection: (error: AppError, export: RoomPlanCaptureExport, session: ScanSessionResponse, idempotencyKey: String, bodyJSON: Data)?
    @State private var isRetryingUpload = false
    @State private var pendingRescan: PendingRescanChoice?
    @State private var rescanExport: RoomPlanCaptureExport?
    @State private var capturedLocation: CaptureLocation?
    @State private var capturedHeadingDeg: Double?
    @State private var roomTypeGuessOn = RoomTypeGuessSettings.isEnabled
    @State private var didStart = false
    @State private var showCorrectionDialog = false
    @State private var showRoomNamePrompt = false
    @State private var customRoomName = ""
    @State private var captureFloor: String = ""
    @State private var captureFloorBeforePrompt: String = ""
    @State private var showFloorPrompt = false
    @State private var showHowToScan = false
    @State private var cameraDenied = CameraAccess.isDenied
    @Environment(\.scenePhase) private var scenePhase

    private let client = ScanServiceClient()
    private let locationProvider = LocationProvider()
    private let headingProvider = HeadingProvider()

    private var debugFakeCaptureActive: Bool {
        #if DEBUG
        FakeLidarMode.isEnabled
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if !DeviceCapability.isRoomPlanSupported && !debugFakeCaptureActive {
                UnsupportedDeviceScreen(onGoBack: onGoBack)
            } else if DeviceCapability.isRoomPlanSupported && cameraDenied {
                CameraAccessDeniedScreen(onGoBack: onGoBack, onAccessRestored: { cameraDenied = false })
            } else if let justCaptured {
                AnotherRoomPromptView(roomCount: justCaptured.floorPlan.rooms.count) { addAnother in
                    onRoomCaptured(justCaptured.session, justCaptured.floorPlan, addAnother)
                }
            } else if isUploadingPartialCapture {
                UploadProgressView(message: "Uploading capture…", onCancel: { uploadTask?.cancel() })
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let partialCaptureFailureMessage {
                PartialCaptureFailureView(
                    message: partialCaptureFailureMessage,
                    onUsePartial: {
                        self.partialCaptureFailureMessage = nil
                        guard let room = coordinator.capturedRoom else {
                            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
                            return
                        }
                        isUploadingPartialCapture = true
                        uploadTask = Task {
                            await submit(CapturedRoomExporter.export(
                                room,
                                roomTypeConfirmation: coordinator.roomTypeConfirmationForExport,
                                walkPath: coordinator.capturedRoomWalkPath,
                                headingDeg: capturedHeadingDeg
                            ))
                        }
                    },
                    onDiscard: {
                        onError(AppError(site: .captureFailed, underlying: PlainError(message: partialCaptureFailureMessage)), existingSession)
                    }
                )
            } else if isDegenerateCapture {
                DegenerateCaptureView {
                    onDiscardRoom()
                }
            } else if isRetryingUpload {
                UploadProgressView(message: "Uploading capture…", onCancel: { uploadTask?.cancel() })
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let uploadRejection {
                UploadRejectedView(
                    error: uploadRejection.error,
                    onRetryUpload: {
                        let pending = uploadRejection
                        self.uploadRejection = nil
                        isRetryingUpload = true
                        uploadTask = Task {
                            await retryUpload(
                                session: pending.session,
                                export: pending.export,
                                idempotencyKey: pending.idempotencyKey,
                                bodyJSON: pending.bodyJSON
                            )
                        }
                    },
                    onRescan: {
                        onDiscardRoom()
                    }
                )
            } else if !DeviceCapability.isRoomPlanSupported {
                #if DEBUG
                if isUploading {
                    UploadProgressView(message: "Uploading fake capture…", onCancel: { uploadTask?.cancel() })
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VuuroCenterView {
                        VuuroIconBadge(systemName: "wand.and.stars", tint: VuuroColor.accent, background: VuuroColor.accentSoft)
                        Text("Debug: fake capture")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(VuuroColor.textPrimary)
                        Text("This device/simulator has no LiDAR. Tap Scan to generate synthetic RoomPlan-shaped data and upload it to the configured Scan Service.")
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(VuuroColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                        Button("Scan (fake data)") {
                            uploadTask = Task { await submit(FakeCaptureGenerator.random()) }
                        }
                        .accessibilityIdentifier("capture.fakeScan")
                        .buttonStyle(.vuuroPrimary)
                        .padding(.top, 12)
                        .frame(maxWidth: 340)
                    }
                }
                #else
                EmptyView()
                #endif
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 0) {
                        ZStack {
                            RoomCaptureScreen(coordinator: coordinator)
                                .ignoresSafeArea(edges: .top)

                            if isUploading {
                                UploadProgressView(message: "Uploading capture…", onCancel: { uploadTask?.cancel() })
                                    .padding()
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            } else if didRequestStop {
                                ProgressView("Finishing scan…")
                                    .padding()
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            } else if coordinator.state == .scanning {
                                singleCaptureOverlay
                            }
                        }
                        singleCaptureBottomChrome
                            .opacity(showsSingleCaptureChrome ? 1 : 0)
                            .allowsHitTesting(showsSingleCaptureChrome)
                    }
                }
                .onAppear {
                    guard !didStart else { return }
                    didStart = true
                    captureFloor = (existingSession?.defaultFloor ?? identity.floor ?? "")
                    coordinator.start()
                    Task { capturedLocation = await locationProvider.currentLocation() }
                    Task { capturedHeadingDeg = await headingProvider.currentHeadingDeg() }
                }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
                .onChange(of: coordinator.cameraFeedMissing) { _, missing in
                    guard missing else { return }
                    onError(AppError(site: .captureFailed, underlying: PlainError(message: vuuroLocalized("The camera didn't start. Close any other app using the camera, then tap Try again."))), existingSession)
                }
                .task(id: didRequestStop) {
                    guard didRequestStop else { return }
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard !Task.isCancelled, didRequestStop, coordinator.state == .scanning, !isUploading else { return }
                    DiagnosticsLog.shared.record("Finish room got no result from RoomPlan within 45s — surfacing an error instead of spinning", category: .error)
                    onError(AppError(site: .captureFailed, underlying: PlainError(message: vuuroLocalized("Finishing the scan took too long. Please scan the room again."))), existingSession)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background, coordinator.state == .scanning {
                        DiagnosticsLog.shared.record("App backgrounded mid-scan — ARKit/RoomPlan behavior here is unverified.", category: .state)
                    }
                }
            }
        }
    }

    private func finishSingleRoom() {
        if !FloorValidation.isValid(captureFloor) {
            captureFloorBeforePrompt = captureFloor
            showFloorPrompt = true
            return
        }
        didRequestStop = true
        coordinator.stop()
    }

    private var showsSingleCaptureChrome: Bool {
        coordinator.state == .scanning && !isUploading && !didRequestStop
    }

    private var singleCaptureBottomChrome: some View {
        VStack(spacing: 12) {
            VuuroLiveStatsRow(stats: coordinator.liveStats)
            VuuroFinishRoomButton(label: "Finish room") {
                if let missing = coordinator.liveStats.missingOpenings {
                    missingOpenings = missing
                    showMissingOpeningsPrompt = true
                } else {
                    finishSingleRoom()
                }
            }
            .accessibilityIdentifier("capture.finishRoom")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var singleCaptureOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VuuroCaptureCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Discard scan"
                ) {
                    showDiscardConfirmation = true
                }
                .accessibilityIdentifier("capture.cancel")
                Spacer(minLength: 0)
                VuuroCaptureTogglePill(isOn: roomTypeGuessOn) {
                    roomTypeGuessOn.toggle()
                    RoomTypeGuessSettings.isEnabled = roomTypeGuessOn
                    VuuroToast.shared.show(vuuroLocalized(roomTypeGuessOn ? "Room-type guessing on" : "Room-type guessing off"))
                }
                .accessibilityIdentifier("capture.roomTypeGuessToggle")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HStack {
                ScanHowToChip { showHowToScan = true }
                    .accessibilityIdentifier("capture.howToScan")
                Spacer()
                Button {
                    captureFloorBeforePrompt = captureFloor
                    showFloorPrompt = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2")
                            .font(.system(size: 11, weight: .semibold))
                        Text(captureFloor.isEmpty ? vuuroLocalized("Set floor") : captureFloor)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.4), in: Capsule())
                }
                .accessibilityIdentifier("capture.floor")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer().frame(height: 24)

            VuuroScanRing(walls: coordinator.liveStats.walls)

            Spacer().frame(height: 14)

            VuuroScanHint(text: vuuroLocalized("Slowly pan around the walls"))

            if let guess = coordinator.liveRoomTypeGuess, !coordinator.hasAnsweredRoomType {
                Spacer().frame(height: 20)
                guessPill(for: guess)
            }

            Spacer(minLength: 20)

            if coordinator.isApproachingSizeLimit {
                Text("This room is getting large. Walk slowly along the walls, or save here and scan the rest as a separate room.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showHowToScan) {
            ScanInstructionsView(
                type: .single,
                primaryLabel: "Back to scanning",
                onPrimary: { showHowToScan = false },
                onClose: { showHowToScan = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(VuuroMetrics.sheetRadius)
        }
        .alert(missingOpenings.alertTitle, isPresented: $showMissingOpeningsPrompt) {
            Button("Scan more", role: .cancel) {}
                .accessibilityIdentifier("capture.missingOpenings.scanMore")
            Button("Finish anyway") {
                finishSingleRoom()
            }
            .accessibilityIdentifier("capture.missingOpenings.finishAnyway")
        } message: {
            Text(verbatim: missingOpenings.alertMessage)
        }
        .sheet(item: $pendingRescan) { choice in
            RescanChoiceSheet(
                choice: choice,
                onReplace: { roomId in resolveRescan(replacing: roomId) },
                onAddNew: { resolveRescan(replacing: nil) }
            )
        }
        .alert("Discard this scan?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                coordinator.stop()
                onGoBack()
            }
            .accessibilityIdentifier("capture.discardConfirm")
            Button("Keep Scanning", role: .cancel) {}
                .accessibilityIdentifier("capture.keepScanning")
        } message: {
            Text("Everything captured so far in this room will be lost.")
        }
        .alert("Which floor?", isPresented: $showFloorPrompt) {
            TextField("e.g. Attic, 1st floor", text: $captureFloor)
                .accessibilityIdentifier("capture.floorField")
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Save") {
                guard FloorValidation.isValid(captureFloor) else { return }
                Task { await persistCaptureFloor() }
            }
            .accessibilityIdentifier("capture.floorSave")
            Button("Cancel", role: .cancel) {
                captureFloor = captureFloorBeforePrompt
            }
            .accessibilityIdentifier("capture.floorCancel")
        } message: {
            Text("Applies to this room and to the next rooms you scan in this session, until you change it.")
        }
        .portraitLocked()
    }

    @MainActor
    private func persistCaptureFloor() async {
        guard let session = existingSession else { return }
        let trimmed = captureFloor.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await client.setDefaultFloor(
                sessionId: session.id,
                accessToken: session.accessToken,
                floor: trimmed.isEmpty ? nil : trimmed
            )
            captureFloor = trimmed
            ScanHistoryStore.shared.updateFloor(sessionId: session.id, floor: trimmed.isEmpty ? nil : trimmed)
        } catch is CancellationError {
        } catch {
            DiagnosticsLog.shared.record("Failed to update default floor: \(error.localizedDescription)", category: .error)
        }
    }

    @ViewBuilder
    private func guessPill(for guess: RoomTypeClassifier.Guess) -> some View {
        VuuroCaptureGuessPill(
            typeName: RoomTypeClassifier.displayName(for: guess.type),
            onConfirm: { coordinator.confirmRoomTypeGuess() },
            onReject: { showCorrectionDialog = true }
        )
        .accessibilityIdentifier("capture.roomTypeGuessPill")
        .confirmationDialog(
            "What kind of room is this?",
            isPresented: $showCorrectionDialog,
            titleVisibility: .visible
        ) {
            ForEach(RoomTypeClassifier.allTypes.filter { $0 != guess.type }, id: \.self) { type in
                Button(RoomTypeClassifier.displayName(for: type)) {
                    coordinator.rejectRoomTypeGuess(correctedTo: type)
                }
                .accessibilityIdentifier("capture.roomType.\(type)")
            }
            Button("Type a name…") {
                customRoomName = ""
                showRoomNamePrompt = true
            }
            .accessibilityIdentifier("capture.roomType.customName")
            Button("Other") {
                coordinator.rejectRoomTypeGuess(correctedTo: "other")
            }
            .accessibilityIdentifier("capture.roomType.other")
            Button("Not sure", role: .cancel) {
                coordinator.rejectRoomTypeGuess(correctedTo: nil)
            }
            .accessibilityIdentifier("capture.roomType.notSure")
        }
        .alert("Name this room", isPresented: $showRoomNamePrompt) {
            TextField("e.g. Study, Utility room", text: $customRoomName)
                .accessibilityIdentifier("capture.roomNameField")
                .textInputAutocapitalization(.words)
            Button("Save") {
                coordinator.nameRoom(customRoomName)
            }
            .accessibilityIdentifier("capture.roomNameSave")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name is used for this room in the plan and the PDF.")
        }
    }

    private func handle(_ state: CaptureCoordinator.State) {
        switch state {
        case .finished(roomAvailable: true):
            guard let room = coordinator.capturedRoom else { return }
            Task { await submit(CapturedRoomExporter.export(room, roomTypeConfirmation: coordinator.roomTypeConfirmationForExport, walkPath: coordinator.capturedRoomWalkPath, headingDeg: capturedHeadingDeg)) }
        case .finished(roomAvailable: false):
            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
        case .failed(let message, let partialRoomAvailable):
            if partialRoomAvailable {
                partialCaptureFailureMessage = message
            } else if didRequestStop {
                onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
            } else {
                onError(AppError(site: .captureFailed, underlying: PlainError(message: message)), existingSession)
            }
        case .scanning:
            break
        }
    }

    @MainActor
    private func rescanCandidates(for export: RoomPlanCaptureExport, session: ScanSessionResponse) async -> [RescanCandidate] {
        do {
            let plan = try await client.fetchSession(sessionId: session.id, accessToken: session.accessToken)
            return RescanMatcher.candidates(for: export, floor: captureFloor, existing: plan.rooms)
        } catch is CancellationError {
            return []
        } catch {
            DiagnosticsLog.shared.record("Rescan check skipped: \(error.localizedDescription)", category: .error)
            return []
        }
    }

    @MainActor
    private func resolveRescan(replacing roomId: String?) {
        guard var export = rescanExport else { return }
        pendingRescan = nil
        rescanExport = nil
        export.replacesRoomId = roomId
        DiagnosticsLog.shared.record(roomId.map { "Rescan: replacing \($0)" } ?? "Rescan: added as a new room", category: .info)
        uploadTask = Task { await submit(export, rescanDecided: true) }
    }

    @MainActor
    private func submit(_ export: RoomPlanCaptureExport, rescanDecided: Bool = false) async {
        defer { isUploadingPartialCapture = false }
        if !FloorValidation.isValid(captureFloor) {
            captureFloor = [existingSession?.defaultFloor, identity.floor].compactMap { $0 }.map(FloorValidation.sanitized).first { !$0.isEmpty } ?? ""
        }

        guard export.hasUsableFloorOutline else {
            DiagnosticsLog.shared.record("Local reject: floor outline too small/degenerate, upload skipped", category: .error)
            isDegenerateCapture = true
            return
        }
        if !rescanDecided, let existingSession {
            isUploading = true
            let candidates = await rescanCandidates(for: export, session: existingSession)
            isUploading = false
            if !candidates.isEmpty {
                let floor = captureFloor.trimmingCharacters(in: .whitespacesAndNewlines)
                if let bodyJSON = try? client.encodeCaptureBody(capture: export, location: capturedLocation, floor: floor.isEmpty ? nil : floor) {
                    var pending = PendingUploadState(session: existingSession, identity: identity, captures: [.init(idempotencyKey: UUID().uuidString, bodyJSON: bodyJSON)])
                    pending.pendingRescan = StoredRescanChoice(roomIndex: 0, candidates: candidates)
                    PendingUploadStore.save(pending)
                }
                rescanExport = export
                pendingRescan = PendingRescanChoice(candidates: candidates)
                return
            }
        }
        isUploading = true
        defer { isUploading = false }

        let idempotencyKey = UUID().uuidString
        let trimmedFloor = captureFloor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bodyJSON = try? client.encodeCaptureBody(
            capture: export,
            location: capturedLocation,
            floor: trimmedFloor.isEmpty ? nil : trimmedFloor
        ) else {
            onError(AppError(site: .captureFailed, underlying: PlainError(message: "Could not prepare this capture for upload.")), existingSession)
            return
        }

        let session: ScanSessionResponse
        if let existingSession {
            session = existingSession
        } else {
            PendingUploadStore.save(PendingUploadState(session: nil, identity: identity, captures: [.init(idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)]))
            do {
                session = try await client.createSession(identity: identity.withFloor(captureFloor))
            } catch {
                onError(AppError(site: .sessionCreate, underlying: error), nil)
                return
            }
            ScanHistoryStore.shared.add(ScanHistoryEntry(
                sessionId: session.id,
                accessToken: session.accessToken,
                propertyId: identity.propertyId,
                unitId: identity.unitId,
                organisationId: identity.organisationId,
                purpose: identity.purpose,
                createdAt: Date(),
                expiresAt: session.expiresAt,
                occupied: identity.occupied,
                consentObtained: identity.consentObtained,
                floor: session.defaultFloor ?? identity.floor
            ))
        }

        PendingUploadStore.save(PendingUploadState(session: session, identity: identity, captures: [.init(idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)]))
        do {
            let result = try await client.uploadCaptureKeepingRoom(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)
            let floorPlan = result.floorPlan
            if result.addedAsNew {
                VuuroToast.shared.show(vuuroLocalized(RescanResume.addedAsNewNotice))
            }
            PendingUploadStore.clear()
            ScanHistoryStore.shared.updateRoomSummary(
                sessionId: session.id,
                summary: RoomSummary.text(for: floorPlan.rooms),
                floorAreaM2: floorPlan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
            )
            ScanHistoryStore.shared.updateRoomsByFloor(
                sessionId: session.id,
                roomsByFloor: CachedFloorSummary.buckets(from: floorPlan.rooms)
            )
            justCaptured = (session, floorPlan)
        } catch {
            uploadRejection = (AppError(site: .captureUpload, underlying: error), export, session, idempotencyKey, bodyJSON)
        }
    }

    @MainActor
    private func retryUpload(session: ScanSessionResponse, export: RoomPlanCaptureExport, idempotencyKey: String, bodyJSON: Data) async {
        defer { isRetryingUpload = false }
        PendingUploadStore.save(PendingUploadState(session: session, identity: identity, captures: [.init(idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)]))
        do {
            let result = try await client.uploadCaptureKeepingRoom(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)
            let floorPlan = result.floorPlan
            if result.addedAsNew {
                VuuroToast.shared.show(vuuroLocalized(RescanResume.addedAsNewNotice))
            }
            PendingUploadStore.clear()
            ScanHistoryStore.shared.updateRoomSummary(
                sessionId: session.id,
                summary: RoomSummary.text(for: floorPlan.rooms),
                floorAreaM2: floorPlan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
            )
            ScanHistoryStore.shared.updateRoomsByFloor(
                sessionId: session.id,
                roomsByFloor: CachedFloorSummary.buckets(from: floorPlan.rooms)
            )
            justCaptured = (session, floorPlan)
        } catch {
            uploadRejection = (AppError(site: .captureUpload, underlying: error), export, session, idempotencyKey, bodyJSON)
        }
    }
}

private struct NoteOnlyFlowStep: View {
    let identity: ScanIdentity
    let onFinished: (ScanSessionResponse, FloorPlan) -> Void
    let onGoBack: () -> Void

    @State private var isWorking = false
    @State private var createdSession: ScanSessionResponse?
    @State private var appError: AppError?
    private let client = ScanServiceClient()

    var body: some View {
        VuuroCenterView {
            VuuroIconBadge(
                systemName: "note.text",
                tint: VuuroColor.accent,
                background: VuuroColor.accentSoft,
                size: 72,
                iconSize: 34
            )
            Text("Notes-only session")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
            Text("This phone can't capture a floor plan, but you can still save inspection notes and photos against this property.")
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if isWorking {
                ProgressView()
                    .tint(VuuroColor.accent)
                    .padding(.top, 12)
            } else {
                VStack(spacing: 10) {
                    Button("Start notes-only session") {
                        Task { await createAndContinue() }
                    }
                    .accessibilityIdentifier("noteOnly.start")
                    .buttonStyle(.vuuroPrimary)

                    Button("Cancel", action: onGoBack)
                        .accessibilityIdentifier("noteOnly.cancel")
                        .buttonStyle(.vuuroGhostSmall)
                }
                .padding(.top, 12)
                .frame(maxWidth: 340)
            }

            if let appError {
                ErrorCodeView(error: appError)
                    .frame(maxWidth: 340)
                    .padding(.top, 8)
            }
        }
        .background(VuuroColor.bgApp)
    }

    @MainActor
    private func createAndContinue() async {
        guard !isWorking else { return }
        isWorking = true
        appError = nil
        defer { isWorking = false }
        do {
            let session: ScanSessionResponse
            if let createdSession {
                session = createdSession
            } else {
                session = try await client.createSession(identity: identity)
                createdSession = session
                ScanHistoryStore.shared.add(ScanHistoryEntry(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    propertyId: identity.propertyId,
                    unitId: identity.unitId,
                    organisationId: identity.organisationId,
                    purpose: identity.purpose,
                    createdAt: Date(),
                    expiresAt: session.expiresAt,
                    occupied: identity.occupied,
                    consentObtained: identity.consentObtained,
                    floor: session.defaultFloor ?? identity.floor
                ))
            }
            let floorPlan = try await client.markNoteOnly(
                sessionId: session.id,
                accessToken: session.accessToken
            )
            onFinished(session, floorPlan)
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .sessionCreate, underlying: error)
        }
    }
}
