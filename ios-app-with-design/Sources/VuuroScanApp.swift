//
//  VuuroScanApp.swift
//  VuuroScan
//
//  This branch had fallen behind ios-app/'s logic: the Done/Stop button,
//  Cancel button, partial-capture recovery, and multi-room-session-on-retry
//  fixes below were ported over from there (2026-09) after being verified
//  there but never here — see ARCHITECTURE.md's business-logic-drift note.
//  Not run on real hardware; only ios-app/ has had a real-device test so far.
import PhotosUI
import RoomPlan
import SwiftUI
import UIKit

@main
struct VuuroScanApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScanFlowView()
            }
            .tint(VuuroColor.primary)
        }
    }
}

struct ScanFlowView: View {
    private enum Stage {
        case intake
        case capturing(identity: ScanIdentity, session: ScanSessionResponse?, attempt: UUID)
        case attachments(session: ScanSessionResponse, floorPlan: FloorPlan)
        case summary(session: ScanSessionResponse, floorPlan: FloorPlan)
        // Carries identity/existingSession, not just the error, so "Try
        // again" can resume the same multi-room session instead of resetting
        // to blank intake — see ios-app/'s VuuroScanApp.swift for the real
        // gap this closes (Mark's 2026-09-01 2-room test).
        case error(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
    }

    @State private var stage: Stage = .intake
    #if DEBUG
    @State private var showDiagnostics = false

    // Whether a full-screen .sheet over an active RoomCaptureView/ARSession
    // is safe is unverified — see ios-app/'s copy of this file for the full
    // rationale. Hidden for the whole capturing stage as the conservative
    // choice until confirmed; the log itself keeps recording underneath.
    private var isCapturingStage: Bool {
        if case .capturing = stage { return true }
        return false
    }
    #endif

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            #if DEBUG
            // Top-leading, opposite corner from the capture screen's back
            // button (top-trailing) so the two never overlap.
            if !isCapturingStage {
                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "ladybug")
                        .font(.headline)
                        .foregroundStyle(VuuroColor.textPrimary)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(.leading, 20)
                .padding(.top, 8)
            }
            #endif
        }
        #if DEBUG
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsLogView()
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch stage {
            case .intake:
                IdentityIntakeScreen { identity in
                    stage = .capturing(identity: identity, session: nil, attempt: UUID())
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink("History") {
                            ScanHistoryView()
                        }
                        .foregroundStyle(VuuroColor.primary)
                    }
                }
            case .capturing(let identity, let session, let attempt):
                RoomCaptureFlowStep(identity: identity, existingSession: session) { session, floorPlan, addAnotherRoom in
                    if addAnotherRoom {
                        stage = .capturing(identity: identity, session: session, attempt: UUID())
                    } else {
                        stage = .attachments(session: session, floorPlan: floorPlan)
                    }
                } onError: { appError, sessionToResume in
                    stage = .error(appError, identity: identity, existingSession: sessionToResume)
                } onGoBack: {
                    stage = .intake
                } onDiscardRoom: {
                    // Real bug fixed here: this used to always call onGoBack,
                    // wiping identity AND session for room 2+ of a multi-room
                    // unit — see ios-app/'s copy of this file for the full
                    // rationale. Resume a fresh attempt against the existing
                    // session instead of leaving the flow when one exists.
                    if let session {
                        stage = .capturing(identity: identity, session: session, attempt: UUID())
                    } else {
                        stage = .intake
                    }
                }
                .id(attempt)
            case .attachments(let session, let floorPlan):
                AttachmentsScreen(session: session, floorPlan: floorPlan) { updated in
                    stage = .summary(session: session, floorPlan: updated)
                }
            case .summary(let session, let floorPlan):
                ResultSummaryView(session: session, floorPlan: floorPlan) {
                    stage = .intake
                }
            case .error(let appError, let identity, let existingSession):
                ErrorView(error: appError) {
                    stage = .capturing(identity: identity, session: existingSession, attempt: UUID())
                }
            }
        }
    }
}

private struct RoomCaptureFlowStep: View {
    let identity: ScanIdentity
    let existingSession: ScanSessionResponse?
    let onRoomCaptured: (ScanSessionResponse, FloorPlan, _ addAnotherRoom: Bool) -> Void
    // Second parameter is the session to resume with on retry — see
    // ios-app/'s VuuroScanApp.swift for why existingSession alone isn't
    // always right (a session createSession creates inside submit() can
    // otherwise get orphaned if uploadCapture then fails).
    let onError: (AppError, ScanSessionResponse?) -> Void
    let onGoBack: () -> Void
    // See ios-app/'s copy of this file for why this is separate from
    // onGoBack: onGoBack means "leave the flow entirely" (only correct when
    // nothing has been created server-side yet); discarding a mid-scan room
    // needs its own callback so the parent can resume with existingSession.
    let onDiscardRoom: () -> Void

    @StateObject private var coordinator = CaptureCoordinator()
    @State private var isUploading = false
    @State private var justCaptured: (session: ScanSessionResponse, floorPlan: FloorPlan)?
    @State private var didRequestStop = false
    @State private var partialCaptureFailureMessage: String?
    @State private var isUploadingPartialCapture = false
    @State private var showDiscardConfirmation = false
    // See ios-app/'s copy of this file for the full rationale (Mark's
    // 2026-09-02 asks (b) and (c)).
    @State private var isDegenerateCapture = false
    @State private var uploadRejection: (error: AppError, export: RoomPlanCaptureExport, session: ScanSessionResponse)?
    @State private var isRetryingUpload = false

    private let client = ScanServiceClient()

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
                // Real dead-end bug found on this pass, same class as the
                // results-screen one fixed earlier this window: this screen
                // is hard constraint #5's required "designed fallback path"
                // for unsupported devices, but its go-back button was never
                // wired to anything at this call site — a user landing here
                // had literally no way forward without force-quitting the
                // app.
                UnsupportedDeviceScreen(onGoBack: onGoBack)
            } else if let justCaptured {
                AnotherRoomPromptView(roomCount: justCaptured.floorPlan.rooms.count) { addAnother in
                    onRoomCaptured(justCaptured.session, justCaptured.floorPlan, addAnother)
                }
            } else if isUploadingPartialCapture {
                // Checked ahead of partialCaptureFailureMessage and the real-
                // capture branch below — see ios-app/'s VuuroScanApp.swift
                // for the render-frame race this closes.
                ProgressView("Uploading capture…")
                    .tint(VuuroColor.primary)
                    .font(VuuroFont.body())
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius))
            } else if let partialCaptureFailureMessage {
                // RoomPlan can still hand back reconstructable geometry after
                // a session-ending error like world tracking failure — see
                // CaptureCoordinator.didEndWith. Only reachable when
                // coordinator.capturedRoom is actually set, so the
                // force-unwrap in onUsePartial is safe.
                PartialCaptureFailureView(
                    message: partialCaptureFailureMessage,
                    onUsePartial: {
                        let room = coordinator.capturedRoom!
                        isUploadingPartialCapture = true
                        Task { await submit(CapturedRoomExporter.export(room)) }
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
                ProgressView("Uploading capture…")
                    .tint(VuuroColor.primary)
                    .font(VuuroFont.body())
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius))
            } else if let uploadRejection {
                UploadRejectedView(
                    error: uploadRejection.error,
                    onRetryUpload: {
                        // isRetryingUpload must flip synchronously, in the
                        // same scope that clears uploadRejection — see
                        // ios-app/'s copy of this file for the render-frame
                        // race this avoids.
                        let pending = uploadRejection
                        self.uploadRejection = nil
                        isRetryingUpload = true
                        Task { await retryUpload(session: pending.session, export: pending.export) }
                    },
                    onRescan: {
                        onDiscardRoom()
                    }
                )
            } else if !DeviceCapability.isRoomPlanSupported {
                // debugFakeCaptureActive must be true to reach here (see the
                // first branch) — real hardware doesn't support RoomPlan, but
                // the Debug fake-LiDAR override is on. RoomCaptureView/ARKit
                // need real LiDAR and would just hang or crash on a device/
                // simulator without one (e.g. appetize.io), so this skips
                // straight to submitting synthetic data through the exact
                // same upload pipeline instead.
                #if DEBUG
                ProgressView("Generating fake capture (Debug)…")
                    .tint(VuuroColor.primary)
                    .onAppear { Task { await submit(FakeCaptureGenerator.random()) } }
                #else
                // Unreachable in a Release build: debugFakeCaptureActive is
                // always false there, so the first branch above already
                // catches !isRoomPlanSupported. Only here so this branch
                // still returns a View and compiles.
                EmptyView()
                #endif
            } else {
                ZStack {
                    RoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

                    if isUploading {
                        ProgressView("Uploading capture…")
                            .tint(VuuroColor.primary)
                            .font(VuuroFont.body())
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius))
                    } else if didRequestStop {
                        // Gap between tapping Done and RoomPlan delivering
                        // didEndWith — see ios-app/'s VuuroScanApp.swift for
                        // the real bug (no way to end a scan at all) this
                        // and the Done button below close.
                        ProgressView("Finishing scan…")
                            .tint(VuuroColor.primary)
                            .font(VuuroFont.body())
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius))
                    } else if coordinator.state == .scanning {
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    showDiscardConfirmation = true
                                } label: {
                                    Image(systemName: "chevron.backward")
                                        .font(.headline)
                                        .foregroundStyle(VuuroColor.textPrimary)
                                        .padding(10)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .padding(.trailing, 20)
                                // .ignoresSafeArea() below is on
                                // RoomCaptureScreen alone, not this VStack —
                                // 8pt is a buffer past the safe-area inset,
                                // not flush against it. See ios-app/'s copy
                                // of this file for why an earlier pass's
                                // bump to 50 was reverted.
                                .padding(.top, 8)
                                // See ios-app/'s copy of this file for why:
                                // chevron.backward reads as non-destructive,
                                // but the action fully abandons the scan.
                                .alert("Discard this scan?", isPresented: $showDiscardConfirmation) {
                                    Button("Discard", role: .destructive) {
                                        coordinator.stop()
                                        onDiscardRoom()
                                    }
                                    Button("Keep Scanning", role: .cancel) {}
                                } message: {
                                    Text("Everything captured so far in this room will be lost.")
                                }
                            }
                            Spacer()
                            Button("Done") {
                                didRequestStop = true
                                coordinator.stop()
                            }
                            .buttonStyle(.vuuroPrimary)
                            .padding(.bottom, 40)
                        }
                    }
                }
                .onAppear { coordinator.start() }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
            }
        }
    }

    private func handle(_ state: CaptureCoordinator.State) {
        switch state {
        case .finished(roomAvailable: true):
            guard let room = coordinator.capturedRoom else { return }
            // The degenerate-outline guard lives inside submit(), not here —
            // see ios-app/'s copy of this file for why.
            Task { await submit(CapturedRoomExporter.export(room)) }
        case .finished(roomAvailable: false):
            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
        case .failed(let message, let partialRoomAvailable):
            if partialRoomAvailable {
                partialCaptureFailureMessage = message
            } else if didRequestStop {
                // Done has no minimum-scan-time guard, so an experimental
                // tap right after appearing is a real scenario — same
                // friendly message as .finished(roomAvailable: false)
                // instead of RoomBuilder's raw thrown text.
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
        guard export.hasUsableFloorOutline else {
            // See ios-app/'s copy of this file for the full rationale,
            // including why isUploadingPartialCapture must be cleared here.
            isUploadingPartialCapture = false
            #if DEBUG
            DiagnosticsLog.shared.record("Local reject: floor outline too small/degenerate, upload skipped", category: .error)
            #endif
            isDegenerateCapture = true
            return
        }
        isUploading = true
        defer { isUploading = false }
        let session: ScanSessionResponse
        if let existingSession {
            session = existingSession
        } else {
            do {
                session = try await client.createSession(identity: identity)
            } catch {
                onError(AppError(site: .sessionCreate, underlying: error), nil)
                return
            }
            // Local-only scan history — see History/ScanHistoryEntry.swift's
            // header for why this can't be a server-side listing.
            ScanHistoryStore.shared.add(ScanHistoryEntry(
                sessionId: session.id,
                accessToken: session.accessToken,
                propertyId: identity.propertyId,
                unitId: identity.unitId,
                organisationId: identity.organisationId,
                purpose: identity.purpose,
                createdAt: Date()
            ))
        }
        do {
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            justCaptured = (session, floorPlan)
        } catch {
            // Mark's 2026-09-02 ask (c) — kept in place instead of routed to
            // onError, which always started a whole new capture attempt. See
            // ios-app/'s copy of this file for why `session`, not
            // existingSession, is what "Retry upload" resubmits into.
            uploadRejection = (AppError(site: .captureUpload, underlying: error), export, session)
        }
    }

    @MainActor
    private func retryUpload(session: ScanSessionResponse, export: RoomPlanCaptureExport) async {
        defer { isRetryingUpload = false }
        do {
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            justCaptured = (session, floorPlan)
        } catch {
            uploadRejection = (AppError(site: .captureUpload, underlying: error), export, session)
        }
    }
}

private struct AnotherRoomPromptView: View {
    let roomCount: Int
    let onChoice: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Room \(roomCount) captured")
                .font(VuuroFont.display(22))
                .foregroundStyle(VuuroColor.textPrimary)
            Text("Scan another room in this unit, or finish and attach photos/notes.")
                .font(VuuroFont.body())
                .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Scan another room") { onChoice(true) }
                .buttonStyle(.vuuroPrimary)
            Button("Finish unit") { onChoice(false) }
                .buttonStyle(.vuuroSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}

// A session-ending error like CaptureError.worldTrackingFailure doesn't
// necessarily mean nothing was captured — RoomBuilder can still reconstruct
// a room from the partial CapturedRoomData RoomPlan hands back alongside the
// error (see CaptureCoordinator.didEndWith). This view turns that into an
// actual choice instead of forcing discard-and-retry every time.
private struct PartialCaptureFailureView: View {
    let message: String
    let onUsePartial: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan interrupted")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
            Text(message)
                .font(VuuroFont.body())
                .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
                .multilineTextAlignment(.center)
            Text("Some of this room was captured before the interruption. You can try uploading it as-is, or discard it and scan again.")
                .font(VuuroFont.body(12))
                .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                .multilineTextAlignment(.center)
            Button("Upload what was captured") { onUsePartial() }
                .buttonStyle(.vuuroPrimary)
            Button("Discard and try again", role: .destructive) { onDiscard() }
                .buttonStyle(.vuuroSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}

// See ios-app/'s copy of this file for the full rationale (Mark's
// 2026-09-02 ask (b)).
private struct DegenerateCaptureView: View {
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Keep scanning")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
            Text("This room's outline came out too small or flat to use. Try scanning more slowly and cover the whole floor before tapping Done.")
                .font(VuuroFont.body())
                .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Rescan this room", action: onRescan)
                .buttonStyle(.vuuroPrimary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}

// See ios-app/'s copy of this file for the full rationale (Mark's
// 2026-09-02 ask (c)).
private struct UploadRejectedView: View {
    let error: AppError
    let onRetryUpload: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Upload didn't go through")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
            ErrorCodeView(error: error)
                .multilineTextAlignment(.center)
            if error.isLikelyRetryable {
                Text("This room's capture is still on your device. Retry the same upload, or rescan if the room itself needs it.")
                    .font(VuuroFont.body(12))
                    .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                    .multilineTextAlignment(.center)
                Button("Retry upload", action: onRetryUpload)
                    .buttonStyle(.vuuroPrimary)
                Button("Rescan this room", role: .destructive, action: onRescan)
                    .buttonStyle(.vuuroSecondary)
            } else {
                // See ios-app/'s copy of this file for why: a 4xx means the
                // server already rejected this exact data, so retrying the
                // same upload is pointless — only rescan is offered.
                Text("The server rejected this capture's data — retrying the same upload won't change that. Rescanning this room is the way forward.")
                    .font(VuuroFont.body(12))
                    .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                    .multilineTextAlignment(.center)
                Button("Rescan this room", action: onRescan)
                    .buttonStyle(.vuuroPrimary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}

private struct AttachmentsScreen: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onDone: (FloorPlan) -> Void

    @State private var noteText = ""
    @State private var photoUrl = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var current: FloorPlan
    @State private var appError: AppError?
    @State private var isSaving = false
    @State private var isUploadingPhoto = false

    private let client = ScanServiceClient()

    init(session: ScanSessionResponse, floorPlan: FloorPlan, onDone: @escaping (FloorPlan) -> Void) {
        self.session = session
        self.floorPlan = floorPlan
        self.onDone = onDone
        _current = State(initialValue: floorPlan)
    }

    var body: some View {
        Form {
            Section("Add a note (optional)") {
                TextField("Note text", text: $noteText, axis: .vertical)
                Button("Add note") { Task { await addNote() } }
                    .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            Section("Add a photo (optional)") {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    if isUploadingPhoto {
                        ProgressView()
                    } else {
                        Text("Choose from library")
                    }
                }
                .buttonStyle(.vuuroSecondary)
                .disabled(isUploadingPhoto)
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        await uploadSelectedPhoto(newItem)
                        selectedPhotoItem = nil
                    }
                }

                Text("Or paste a URL to a photo already hosted elsewhere:")
                    .font(VuuroFont.body(12))
                    .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                TextField("https://…", text: $photoUrl)
                Button("Add photo URL") { Task { await addPhoto() } }
                    .disabled(photoUrl.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            if let appError {
                ErrorCodeView(error: appError)
            }

            Section {
                Text("\(current.notes.count) note(s), \(current.photos.count) photo(s) attached so far.")
                    .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
                    .font(VuuroFont.body(13))
                Button("Finish") { onDone(current) }
                    .buttonStyle(.vuuroPrimary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .tint(VuuroColor.primary)
        .scrollContentBackground(.hidden)
        .background(VuuroColor.surfaceMuted)
        .navigationTitle("Notes & photos")
    }

    @MainActor
    private func addNote() async {
        isSaving = true
        defer { isSaving = false }
        do {
            current = try await client.addNote(sessionId: session.id, accessToken: session.accessToken, text: noteText)
            noteText = ""
            appError = nil
        } catch {
            appError = AppError(site: .noteAdd, underlying: error)
        }
    }

    @MainActor
    private func addPhoto() async {
        isSaving = true
        defer { isSaving = false }
        do {
            current = try await client.addPhoto(sessionId: session.id, accessToken: session.accessToken, url: photoUrl)
            photoUrl = ""
            appError = nil
        } catch {
            appError = AppError(site: .photoAdd, underlying: error)
        }
    }

    // Sniffs the actual bytes rather than trusting whatever the Photos
    // library labels the item as — same "don't trust the client's own
    // label" principle the Scan Service itself applies server-side
    // (finfo, not the claimed Content-Type) to this same upload.
    private func detectedMimeType(for data: Data) -> (mime: String, extension: String) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ("image/png", "png")
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ("image/jpeg", "jpg")
        }
        if data.count > 12, data[data.startIndex.advanced(by: 4)..<data.startIndex.advanced(by: 8)].elementsEqual("ftyp".utf8) {
            return ("image/heic", "heic")
        }
        return ("image/jpeg", "jpg")
    }

    @MainActor
    private func uploadSelectedPhoto(_ item: PhotosPickerItem) async {
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                appError = AppError(site: .photoUpload, underlying: nil)
                return
            }
            let (mime, ext) = detectedMimeType(for: data)
            let uploaded = try await client.uploadPhoto(sessionId: session.id, accessToken: session.accessToken, imageData: data, filename: "photo.\(ext)", mimeType: mime)
            current = try await client.addPhoto(sessionId: session.id, accessToken: session.accessToken, url: uploaded.url)
            appError = nil
        } catch {
            appError = AppError(site: .photoUpload, underlying: error)
        }
    }
}

private struct ResultSummaryView: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onDone: () -> Void

    @State private var isFetchingImage = false
    @State private var isFetchingPDF = false
    @State private var floorPlanImage: UIImage?
    @State private var floorPlanImageURL: URL?
    @State private var floorPlanPDFURL: URL?
    @State private var appError: AppError?

    private let client = ScanServiceClient()

    var body: some View {
        List {
            ForEach(floorPlan.rooms, id: \.roomId) { room in
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.label)
                        .font(VuuroFont.display(17))
                        .foregroundStyle(VuuroColor.textPrimary)
                    Text(String(format: "%.2f m²", room.floorAreaM2))
                        .font(VuuroFont.body(17, weight: .bold))
                        .foregroundStyle(VuuroColor.primary)
                    Text(String(format: "%.2f m perimeter", room.perimeterM))
                        .font(VuuroFont.body())
                        .foregroundStyle(VuuroColor.textPrimary)
                    Text("Indicative — NEN2580-inspired, not certified")
                        .font(VuuroFont.body(12))
                        .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))

                    if !room.coverage.usable, let message = room.coverage.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(VuuroFont.body(12))
                            .foregroundStyle(VuuroColor.primary)
                            .padding(.top, 2)
                    } else {
                        Text("Scan quality: \(room.coverage.score)/100")
                            .font(VuuroFont.body(11))
                            .foregroundStyle(VuuroColor.textPrimary.opacity(0.5))
                    }
                }
                .padding(.vertical, 4)
            }

            // Per-session, not per-room: the Scan Service renders one PNG
            // (rooms tiled on one sheet) and one PDF (one metrics table) per
            // session, not a separate file per room — see
            // ../../docs/adr/0002-export-coordinate-frame.md for why. Same
            // per-session shape as History/ScanHistoryView.swift's rows.
            Section("Floor plan exports") {
                Button {
                    Task { await loadImage() }
                } label: {
                    if isFetchingImage {
                        ProgressView()
                    } else {
                        Text("Download image")
                    }
                }
                .buttonStyle(.vuuroSecondary)
                .disabled(isFetchingImage)

                if let floorPlanImage {
                    Image(uiImage: floorPlanImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius, style: .continuous))

                    if let floorPlanImageURL {
                        ShareLink(item: floorPlanImageURL) {
                            Label("Save image", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Button {
                    Task { await loadPDF() }
                } label: {
                    if isFetchingPDF {
                        ProgressView()
                    } else {
                        Text("Download PDF")
                    }
                }
                .buttonStyle(.vuuroSecondary)
                .disabled(isFetchingPDF)

                if let floorPlanPDFURL {
                    ShareLink(item: floorPlanPDFURL) {
                        Label("Save PDF", systemImage: "square.and.arrow.up")
                    }
                }

                if let appError {
                    ErrorCodeView(error: appError)
                }
            }

            Section {
                NavigationLink("Access log") {
                    AccessLogView(sessionId: session.id, accessToken: session.accessToken)
                }
                .font(VuuroFont.body(15))
                .foregroundStyle(VuuroColor.primary)
            }

            Section {
                Button("Done") {
                    cleanUpExportedFiles()
                    onDone()
                }
                .buttonStyle(.vuuroPrimary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .tint(VuuroColor.primary)
        .scrollContentBackground(.hidden)
        .background(VuuroColor.surfaceMuted)
        .navigationTitle("Scan result")
        .onDisappear { cleanUpExportedFiles() }
    }

    // loadImage()/loadPDF() write into the shared tmp directory, which iOS
    // doesn't clear on any predictable schedule — without this, every
    // "Download image"/"Download PDF" tap leaves a file behind for the life
    // of the app install.
    @MainActor
    private func cleanUpExportedFiles() {
        for url in [floorPlanImageURL, floorPlanPDFURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        floorPlanImageURL = nil
        floorPlanPDFURL = nil
    }

    @MainActor
    private func loadImage() async {
        isFetchingImage = true
        defer { isFetchingImage = false }
        do {
            let data = try await client.fetchFloorPlanImage(sessionId: session.id, accessToken: session.accessToken)
            guard let image = UIImage(data: data) else {
                appError = AppError(site: .resultImageDecode, underlying: nil)
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(session.id).png")
            try data.write(to: url)
            floorPlanImage = image
            floorPlanImageURL = url
            appError = nil
        } catch {
            appError = AppError(site: .resultImageLoad, underlying: error)
        }
    }

    @MainActor
    private func loadPDF() async {
        isFetchingPDF = true
        defer { isFetchingPDF = false }
        do {
            let data = try await client.fetchFloorPlanPDF(sessionId: session.id, accessToken: session.accessToken)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(session.id).pdf")
            try data.write(to: url)
            floorPlanPDFURL = url
            appError = nil
        } catch {
            appError = AppError(site: .resultPDFLoad, underlying: error)
        }
    }
}

private struct ErrorView: View {
    let error: AppError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Something went wrong")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
            ErrorCodeView(error: error)
                .multilineTextAlignment(.center)
            Button("Try again", action: onRetry)
                .buttonStyle(.vuuroPrimary)
                .padding(.horizontal, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.surfaceMuted)
    }
}
