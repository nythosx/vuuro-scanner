import ImageIO
import PhotosUI
import RoomPlan
import SwiftUI
import UIKit

@main
struct VuuroScanApp: App {
    @AppStorage(AppLanguageSettings.storageKey) private var appLanguageRaw: String = AppLanguage.system.rawValue

    init() {
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

struct VuuroRootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("darkModeEnabled") private var darkMode = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                NavigationStack {
                    ScanFlowView()
                        .background(VuuroColor.bgApp)
                }
            } else {
                OnboardingFlowView {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hasCompletedOnboarding = true
                    }
                }
            }
        }
        .preferredColorScheme(darkMode ? .dark : .light)
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
        case attachments(session: ScanSessionResponse, floorPlan: FloorPlan, identity: ScanIdentity)
        case summary(session: ScanSessionResponse, floorPlan: FloorPlan)
        case error(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
        case multiRoomError(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
    }

    @State private var stage: Stage
    @State private var showStartSheet = false
    @State private var startType: ScanStartType = .single
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
                        startType = .single
                        showStartSheet = true
                    },
                    onStartMulti: {
                        startType = .multi
                        showStartSheet = true
                    },
                    onOpenSettings: { showSettings = true },
                    onOpenHistory: { showHistory = true },
                    onOpenTerms: { showTerms = true }
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
                    stage = .home
                }
                .toolbar(.hidden, for: .navigationBar)

            case .summary(let session, let floorPlan):
                ResultSummaryView(session: session, floorPlan: floorPlan) {
                    VuuroToast.shared.show("Scan saved to history")
                    stage = .home
                }
                .toolbar(.hidden, for: .navigationBar)

            case .error(let appError, let identity, let existingSession):
                ErrorView(error: appError) {
                    if let pending = PendingUploadStore.load() {
                        stage = .resumingUpload(pending)
                    } else {
                        stage = .capturing(identity: identity, session: existingSession, attempt: UUID())
                    }
                }
                .toolbar(.hidden, for: .navigationBar)

            case .multiRoomError(let appError, let identity, let existingSession):
                ErrorView(error: appError) {
                    if let pending = PendingUploadStore.load() {
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
                onResumeToAddRoom: { entry in
                    showHistory = false
                    stage = .capturing(
                        identity: entry.asResumableIdentity(),
                        session: entry.asResumableSession(),
                        attempt: UUID()
                    )
                },
                onAttachToSession: { entry, floorPlan in
                    showHistory = false
                    stage = .attachments(
                        session: entry.asResumableSession(),
                        floorPlan: floorPlan,
                        identity: entry.asResumableIdentity()
                    )
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
    @State private var partialCaptureFailureMessage: String?
    @State private var isUploadingPartialCapture = false
    @State private var showDiscardConfirmation = false
    @State private var isDegenerateCapture = false
    @State private var uploadRejection: (error: AppError, export: RoomPlanCaptureExport, session: ScanSessionResponse, idempotencyKey: String, bodyJSON: Data)?
    @State private var isRetryingUpload = false
    @State private var capturedLocation: CaptureLocation?
    @State private var capturedHeadingDeg: Double?
    @State private var roomTypeGuessOn = RoomTypeGuessSettings.isEnabled
    @State private var didStart = false
    @State private var showCorrectionDialog = false
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
                    RoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

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
                .onAppear {
                    guard !didStart else { return }
                    didStart = true
                    coordinator.start()
                    Task { capturedLocation = await locationProvider.currentLocation() }
                    Task { capturedHeadingDeg = await headingProvider.currentHeadingDeg() }
                }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background, coordinator.state == .scanning {
                        DiagnosticsLog.shared.record("App backgrounded mid-scan — ARKit/RoomPlan behavior here is unverified.", category: .state)
                    }
                }
            }
        }
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
                Spacer(minLength: 0)
                VuuroCaptureTogglePill(isOn: roomTypeGuessOn) {
                    roomTypeGuessOn.toggle()
                    RoomTypeGuessSettings.isEnabled = roomTypeGuessOn
                    VuuroToast.shared.show(roomTypeGuessOn ? "Room-type guessing on" : "Room-type guessing off")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer().frame(height: 24)

            VuuroScanRing(walls: coordinator.liveStats.walls)

            Spacer().frame(height: 14)

            VuuroScanHint(text: "Slowly pan around the walls")

            if let guess = coordinator.liveRoomTypeGuess, !coordinator.hasAnsweredRoomType {
                Spacer().frame(height: 20)
                guessPill(for: guess)
            }

            Spacer(minLength: 20)

            if coordinator.isApproachingSizeLimit {
                Text("This room looks larger than RoomPlan's practical scanning range (~9m) — accuracy may degrade beyond this size.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            VuuroLiveStatsRow(stats: coordinator.liveStats)
                .padding(.horizontal, 20)

            Spacer().frame(height: 12)

            VuuroFinishRoomButton(label: "Finish room") {
                didRequestStop = true
                coordinator.stop()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .alert("Discard this scan?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                coordinator.stop()
                onGoBack()
            }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text("Everything captured so far in this room will be lost.")
        }
    }

    @ViewBuilder
    private func guessPill(for guess: RoomTypeClassifier.Guess) -> some View {
        VuuroCaptureGuessPill(
            typeName: RoomTypeClassifier.displayName(for: guess.type),
            onConfirm: { coordinator.confirmRoomTypeGuess() },
            onReject: { showCorrectionDialog = true }
        )
        .confirmationDialog(
            "What kind of room is this?",
            isPresented: $showCorrectionDialog,
            titleVisibility: .visible
        ) {
            ForEach(RoomTypeClassifier.allTypes.filter { $0 != guess.type }, id: \.self) { type in
                Button(RoomTypeClassifier.displayName(for: type)) {
                    coordinator.rejectRoomTypeGuess(correctedTo: type)
                }
            }
            Button("Other") {
                coordinator.rejectRoomTypeGuess(correctedTo: "other")
            }
            Button("Not sure", role: .cancel) {
                coordinator.rejectRoomTypeGuess(correctedTo: nil)
            }
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
    private func submit(_ export: RoomPlanCaptureExport) async {
        defer { isUploadingPartialCapture = false }

        guard export.hasUsableFloorOutline else {
            DiagnosticsLog.shared.record("Local reject: floor outline too small/degenerate, upload skipped", category: .error)
            isDegenerateCapture = true
            return
        }
        isUploading = true
        defer { isUploading = false }

        let idempotencyKey = UUID().uuidString
        guard let bodyJSON = try? client.encodeCaptureBody(capture: export, location: capturedLocation) else {
            onError(AppError(site: .captureFailed, underlying: PlainError(message: "Could not prepare this capture for upload.")), existingSession)
            return
        }

        let session: ScanSessionResponse
        if let existingSession {
            session = existingSession
        } else {
            PendingUploadStore.save(PendingUploadState(session: nil, identity: identity, captures: [.init(idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)]))
            do {
                session = try await client.createSession(identity: identity)
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
                consentObtained: identity.consentObtained
            ))
        }

        PendingUploadStore.save(PendingUploadState(session: session, identity: identity, captures: [.init(idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)]))
        do {
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)
            PendingUploadStore.clear()
            ScanHistoryStore.shared.updateRoomSummary(sessionId: session.id, summary: RoomSummary.text(for: floorPlan.rooms))
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
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)
            PendingUploadStore.clear()
            ScanHistoryStore.shared.updateRoomSummary(sessionId: session.id, summary: RoomSummary.text(for: floorPlan.rooms))
            justCaptured = (session, floorPlan)
        } catch {
            uploadRejection = (AppError(site: .captureUpload, underlying: error), export, session, idempotencyKey, bodyJSON)
        }
    }
}