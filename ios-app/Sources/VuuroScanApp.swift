//
//  VuuroScanApp.swift
//  VuuroScan
//
//  Real-device confirmed for the core flow through Mark's 2026-09-01 test
//  (feature/vuuro-scan @ a3c6284): identity intake, RoomCaptureScreen with
//  live AR wireframe/coaching, and the error screen all ran for real. The
//  Done/Stop button, Cancel button, and partial-capture recovery in this
//  file were added after that test and are compiled-via-CI only so far —
//  not yet run on real hardware, see Models/ScanIdentity.swift header for
//  what that distinction means generally.
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
        // to blank intake. Real gap this closes: Mark's actual test was a
        // 2-room session (attic, then bathroom) — without this, a room 2
        // failure would silently orphan room 1's already-created session
        // instead of letting him retry room 2 into it.
        case error(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
    }

    @State private var stage: Stage = .intake
    @State private var showDiagnostics = false

    // Whether presenting a full-screen .sheet over an active RoomCaptureView/
    // ARSession is actually safe (does iOS pause/interrupt ARKit tracking
    // when its hosting view stops being frontmost?) is genuinely unverified
    // here — no Xcode/device to check it against, same category as every
    // other "unverified against real SDK behavior" note in this codebase.
    // Hiding the button for the whole capturing stage, not just while
    // coordinator.state == .scanning specifically, is the conservative
    // choice until that's confirmed: this tool exists to help diagnose
    // problems, it should not risk causing the exact class of problem
    // (a world-tracking failure) it was built to help diagnose. The log
    // itself keeps recording underneath regardless — only viewing/exporting
    // it is paused, not capturing it.
    private var isCapturingStage: Bool {
        if case .capturing = stage { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            // Top-leading, opposite corner from the capture screen's back
            // button (top-trailing) so the two never overlap. Shown on every
            // other stage, since real errors happen in session creation/
            // upload/photo-attach too, not only mid-scan — see
            // isCapturingStage for why it's hidden specifically here.
            if !isCapturingStage {
                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "ladybug")
                        .font(.headline)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(.leading, 20)
                .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsLogView()
        }
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
                    // which resets straight to .intake — for room 2+ of a
                    // multi-room unit, that wiped identity AND session,
                    // silently orphaning every already-uploaded room (no
                    // idempotency key on POST /scan-sessions to catch the
                    // duplicate a retry would then create). Discarding THIS
                    // room's in-progress capture should only ever cost this
                    // room, matching what the confirmation alert promises —
                    // so with an existing session, resume a fresh attempt
                    // against it instead of leaving the flow entirely.
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
    // The second parameter is the session to resume with on retry, not
    // necessarily existingSession: if submit() gets far enough to create a
    // new session before failing (createSession succeeds, uploadCapture then
    // fails on a network blip), retrying with existingSession (still nil at
    // that point) would silently create a second orphaned session server-
    // side instead of reusing the one that already exists. Real gap — POST
    // /scan-sessions has no idempotency key the way /capture does, so
    // nothing on the server catches this either.
    let onError: (AppError, ScanSessionResponse?) -> Void
    let onGoBack: () -> Void
    // Separate from onGoBack on purpose: onGoBack means "leave the flow
    // entirely" (only ever correct when nothing has been created server-side
    // yet). Discarding a mid-scan room needs its own callback so the parent
    // can resume with existingSession instead, rather than conflating "exit"
    // and "abandon this one room" into the same action.
    let onDiscardRoom: () -> Void

    @StateObject private var coordinator = CaptureCoordinator()
    @State private var isUploading = false
    @State private var justCaptured: (session: ScanSessionResponse, floorPlan: FloorPlan)?
    @State private var didRequestStop = false
    @State private var partialCaptureFailureMessage: String?
    @State private var isUploadingPartialCapture = false
    @State private var showDiscardConfirmation = false

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
                // capture branch below, on purpose: real bug caught in review
                // before this ever reached Mark — clearing
                // partialCaptureFailureMessage synchronously while submit()
                // only sets isUploading = true one Task{} hop later left a
                // render frame where every guard here was false, which fell
                // through to the bare capture branch and fired
                // coordinator.start() again on an already-ended session
                // (flashing the live camera back on mid-upload). Setting this
                // flag synchronously, in the same scope that clears
                // partialCaptureFailureMessage, closes that gap.
                ProgressView("Uploading capture…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let partialCaptureFailureMessage {
                // Answers Mark's real-device question directly: RoomPlan can
                // still hand back reconstructable geometry after a session-
                // ending error like world tracking failure (see
                // CaptureCoordinator.didEndWith) — so discard-and-retry isn't
                // the only honest option when that happens. Only reachable
                // when coordinator.capturedRoom is actually set (see handle
                // below), so the force-unwrap in onUsePartial is safe.
                PartialCaptureFailureView(
                    message: partialCaptureFailureMessage,
                    onUsePartial: {
                        let room = coordinator.capturedRoom!
                        isUploadingPartialCapture = true
                        Task { await submit(CapturedRoomExporter.export(room)) }
                    },
                    onDiscard: {
                        // No session was created for this attempt (it failed
                        // before ever reaching submit()), so existingSession
                        // is still the right value to resume with.
                        onError(AppError(site: .captureFailed, underlying: PlainError(message: partialCaptureFailureMessage)), existingSession)
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
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if didRequestStop {
                        // Gap between tapping Done and RoomPlan actually
                        // delivering didEndWith (real bug Mark found on a
                        // real device: without this, and without isUploading
                        // yet true, there was no way to end a scan at all —
                        // start() ran on appear but nothing ever called
                        // coordinator.stop()).
                        ProgressView("Finishing scan…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if coordinator.state == .scanning {
                        VStack {
                            // Same bug class as the missing Done button, other
                            // direction: without this, a user who entered
                            // capture by mistake (wrong unit, changed their
                            // mind) had no way back except forcing an error —
                            // there's no automatic nav-bar back button here
                            // since this stage swaps in via @State, not a
                            // NavigationStack push. .ignoresSafeArea() below
                            // is on RoomCaptureScreen alone, not this VStack
                            // or the ZStack — this button already lays out
                            // respecting the safe area on its own, so 8pt is
                            // a buffer past the notch/status bar inset, not
                            // flush against it (corrected here after an
                            // earlier pass bumped this to 50, on a wrong
                            // assumption that it was overlapping — that
                            // would have stacked 50pt past the safe area
                            // inset too, risking crowding RoomPlan's own
                            // coaching UI. Still unverified either way
                            // without a real device — flag to Mark).
                            HStack {
                                Spacer()
                                Button {
                                    showDiscardConfirmation = true
                                } label: {
                                    Image(systemName: "chevron.backward")
                                        .font(.headline)
                                        .padding(10)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .padding(.trailing, 20)
                                .padding(.top, 8)
                                // chevron.backward reads as "go back, nothing
                                // lost" (iOS's standard non-destructive-nav
                                // symbol), but the action is a full abandon —
                                // this confirmation is what makes that icon
                                // honest instead of misleading, matching this
                                // project's own "don't claim more than what
                                // actually happens" standard.
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
                            .buttonStyle(.borderedProminent)
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
            Task { await submit(CapturedRoomExporter.export(room)) }
        case .finished(roomAvailable: false):
            // No session created for this attempt yet (submit() never ran),
            // so existingSession is the right value to resume with.
            onError(AppError(site: .captureNoRoom, underlying: nil), existingSession)
        case .failed(let message, let partialRoomAvailable):
            if partialRoomAvailable {
                // Route through the local partial-capture choice, not
                // straight to onError — see the body's dedicated branch.
                partialCaptureFailureMessage = message
            } else if didRequestStop {
                // The Done button (new, untested on real hardware until
                // Mark's next run) has no minimum-scan-time guard, so an
                // experimental tap right after appearing is a real scenario
                // — RoomBuilder throwing on essentially-empty data here isn't
                // a crash/error, it's "nothing to build yet." Same case
                // .finished(roomAvailable: false) already has a friendly
                // message for; use it here too instead of RoomBuilder's raw
                // (likely cryptic) thrown-error text.
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
        isUploading = true
        defer { isUploading = false }
        let session: ScanSessionResponse
        if let existingSession {
            session = existingSession
        } else {
            do {
                session = try await client.createSession(identity: identity)
            } catch {
                // No session exists yet — nil is correct here, retry should
                // create one, same as this attempt just tried to.
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
            // The real fix: `session` here (not existingSession) is whatever
            // this attempt actually ended up with — including a session
            // createSession just created moments ago, above, if this was the
            // first room. Passing existingSession instead would have retried
            // into a blank session, calling createSession again and orphaning
            // this one server-side with zero captures, silently, since
            // POST /scan-sessions has no idempotency key the way /capture
            // does to catch a duplicate.
            onError(AppError(site: .captureUpload, underlying: error), session)
        }
    }
}

private struct AnotherRoomPromptView: View {
    let roomCount: Int
    let onChoice: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Room \(roomCount) captured").font(.headline)
            Text("Scan another room in this unit, or finish and attach photos/notes.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Scan another room") { onChoice(true) }
                .buttonStyle(.borderedProminent)
            Button("Finish unit") { onChoice(false) }
        }
        .padding()
    }
}

// Real-device finding (Mark, 2026-09-01): a session-ending error like
// CaptureError.worldTrackingFailure doesn't necessarily mean nothing was
// captured — RoomBuilder can still reconstruct a room from the partial
// CapturedRoomData RoomPlan hands back alongside the error (see
// CaptureCoordinator.didEndWith). This view is what turns that into an
// actual choice instead of forcing discard-and-retry every time.
private struct PartialCaptureFailureView: View {
    let message: String
    let onUsePartial: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan interrupted").font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Some of this room was captured before the interruption. You can try uploading it as-is, or discard it and scan again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Upload what was captured") { onUsePartial() }
                .buttonStyle(.borderedProminent)
            Button("Discard and try again", role: .destructive) { onDiscard() }
        }
        .padding()
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
                .disabled(isUploadingPhoto)
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        await uploadSelectedPhoto(newItem)
                        selectedPhotoItem = nil
                    }
                }

                Text("Or paste a URL to a photo already hosted elsewhere:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…", text: $photoUrl)
                Button("Add photo URL") { Task { await addPhoto() } }
                    .disabled(photoUrl.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            if let appError {
                ErrorCodeView(error: appError)
            }

            Section {
                Text("\(current.notes.count) note(s), \(current.photos.count) photo(s) attached so far.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Button("Finish") { onDone(current) }
                    .buttonStyle(.borderedProminent)
            }
        }
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
                    Text(room.label).font(.headline)
                    Text(String(format: "%.2f m²", room.floorAreaM2))
                    Text(String(format: "%.2f m perimeter", room.perimeterM))
                    Text("Indicative — NEN2580-inspired, not certified")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !room.coverage.usable, let message = room.coverage.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    } else {
                        Text("Scan quality: \(room.coverage.score)/100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Vuuro Scan direction brief, "Export priority for early value":
            // floor plan image/PDF through the Scan Service API. The server
            // already renders both (FloorPlanImageRenderer/PdfRenderer,
            // GET .../export/floorplan.png|.pdf) — this is what actually
            // fetches and surfaces them client-side.
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
                .disabled(isFetchingImage)

                if let floorPlanImage {
                    Image(uiImage: floorPlanImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)

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
            }

            Section {
                Button("Done") {
                    cleanUpExportedFiles()
                    onDone()
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
            Text("Something went wrong").font(.headline)
            ErrorCodeView(error: error)
                .multilineTextAlignment(.center)
            Button("Try again", action: onRetry).buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
