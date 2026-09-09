import PhotosUI
import RoomPlan
import SwiftUI
import UIKit

@main
struct VuuroScanApp: App {
    init() {
        KeychainTokenStore.resetIfReinstalled()
    }

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
        case resumingUpload(PendingUploadState)
        case capturing(identity: ScanIdentity, session: ScanSessionResponse?, attempt: UUID)
        case multiRoomCapturing(identity: ScanIdentity, session: ScanSessionResponse?, attempt: UUID)
        case attachments(session: ScanSessionResponse, floorPlan: FloorPlan)
        case summary(session: ScanSessionResponse, floorPlan: FloorPlan)
        case error(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
        case multiRoomError(AppError, identity: ScanIdentity, existingSession: ScanSessionResponse?)
    }

    @State private var stage: Stage

    init() {
        if let pending = PendingUploadStore.load() {
            _stage = State(initialValue: .resumingUpload(pending))
        } else {
            _stage = State(initialValue: .intake)
        }
    }
    #if DEBUG
    @State private var showDiagnostics = false
    private var isCapturingStage: Bool {
        if case .capturing = stage { return true }
        if case .multiRoomCapturing = stage { return true }
        return false
    }
    #endif

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            #if DEBUG
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
            case .resumingUpload(let pending):
                PendingUploadRecoveryView(state: pending) { session, floorPlan in
                    stage = .attachments(session: session, floorPlan: floorPlan)
                } onDiscarded: {
                    stage = .intake
                }
            case .intake:
                IdentityIntakeScreen(onStart: { identity in
                    stage = .capturing(identity: identity, session: nil, attempt: UUID())
                }, onStartMultiRoom: { identity in
                    stage = .multiRoomCapturing(identity: identity, session: nil, attempt: UUID())
                })
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink("History") {
                            ScanHistoryView(onResumeToAddRoom: { entry in
                                stage = .capturing(
                                    identity: entry.asResumableIdentity(),
                                    session: entry.asResumableSession(),
                                    attempt: UUID()
                                )
                            }, onAttachToSession: { entry, floorPlan in
                                stage = .attachments(session: entry.asResumableSession(), floorPlan: floorPlan)
                            })
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
                    PendingUploadStore.clear()
                    stage = .intake
                } onDiscardRoom: {
                    PendingUploadStore.clear()
                    if let session {
                        stage = .capturing(identity: identity, session: session, attempt: UUID())
                    } else {
                        stage = .intake
                    }
                }
                .id(attempt)
            case .multiRoomCapturing(let identity, let session, let attempt):
                MultiRoomCaptureFlowView(identity: identity, existingSession: session) { session, floorPlan in
                    stage = .attachments(session: session, floorPlan: floorPlan)
                } onError: { appError, sessionToResume in
                    stage = .multiRoomError(appError, identity: identity, existingSession: sessionToResume)
                } onGoBack: {
                    PendingUploadStore.clear()
                    stage = .intake
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
                    if let pending = PendingUploadStore.load() {
                        stage = .resumingUpload(pending)
                    } else {
                        stage = .capturing(identity: identity, session: existingSession, attempt: UUID())
                    }
                }
            case .multiRoomError(let appError, let identity, let existingSession):
                ErrorView(error: appError) {
                    if let pending = PendingUploadStore.load() {
                        stage = .resumingUpload(pending)
                    } else {
                        stage = .multiRoomCapturing(identity: identity, session: existingSession, attempt: UUID())
                    }
                }
            }
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
    @State private var justCaptured: (session: ScanSessionResponse, floorPlan: FloorPlan)?
    @State private var didRequestStop = false
    @State private var partialCaptureFailureMessage: String?
    @State private var isUploadingPartialCapture = false
    @State private var showDiscardConfirmation = false
    @State private var isDegenerateCapture = false
    @State private var uploadRejection: (error: AppError, export: RoomPlanCaptureExport, session: ScanSessionResponse, idempotencyKey: String, bodyJSON: Data)?
    @State private var isRetryingUpload = false
    @State private var capturedLocation: CaptureLocation?
    @Environment(\.scenePhase) private var scenePhase

    private let client = ScanServiceClient()
    private let locationProvider = LocationProvider()

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
                ProgressView("Uploading capture…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let partialCaptureFailureMessage {
                PartialCaptureFailureView(
                    message: partialCaptureFailureMessage,
                    onUsePartial: {
                        let room = coordinator.capturedRoom!
                        isUploadingPartialCapture = true
                        Task { await submit(CapturedRoomExporter.export(room, roomTypeConfirmation: coordinator.roomTypeConfirmationForExport, walkPath: coordinator.capturedRoomWalkPath)) }
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
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let uploadRejection {
                UploadRejectedView(
                    error: uploadRejection.error,
                    onRetryUpload: {
                        let pending = uploadRejection
                        self.uploadRejection = nil
                        isRetryingUpload = true
                        Task { await retryUpload(session: pending.session, export: pending.export, idempotencyKey: pending.idempotencyKey, bodyJSON: pending.bodyJSON) }
                    },
                    onRescan: {
                        onDiscardRoom()
                    }
                )
            } else if !DeviceCapability.isRoomPlanSupported {
                #if DEBUG
                ProgressView("Generating fake capture (Debug)…")
                    .onAppear { Task { await submit(FakeCaptureGenerator.random()) } }
                #else
                EmptyView()
                #endif
            } else {
                ZStack {
                    RoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

                    if let guess = coordinator.liveRoomTypeGuess {
                        VStack {
                            RoomTypeGuessOverlay(
                                guess: guess,
                                onConfirm: { coordinator.confirmRoomTypeGuess() },
                                onReject: { picked in coordinator.rejectRoomTypeGuess(correctedTo: picked) }
                            )
                            .id(guess.type)
                            Spacer()
                        }
                    }

                    if isUploading {
                        ProgressView("Uploading capture…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if didRequestStop {
                        ProgressView("Finishing scan…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if coordinator.state == .scanning {
                        VStack {
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
                            Spacer()
                            if coordinator.isApproachingSizeLimit {
                                Text("This room looks larger than RoomPlan's practical scanning range (~9m) — accuracy may degrade beyond this size.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                    .padding(.bottom, 8)
                            }
                            Button("Done") {
                                didRequestStop = true
                                coordinator.stop()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.bottom, 40)
                        }
                    }
                }
                .onAppear {
                    coordinator.start()
                    Task { capturedLocation = await locationProvider.currentLocation() }
                }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background, coordinator.state == .scanning {
                        #if DEBUG
                        DiagnosticsLog.shared.record("App backgrounded mid-scan — ARKit/RoomPlan behavior here is unverified.", category: .state)
                        #endif
                    }
                }
            }
        }
    }

    private func handle(_ state: CaptureCoordinator.State) {
        switch state {
        case .finished(roomAvailable: true):
            guard let room = coordinator.capturedRoom else { return }
            Task { await submit(CapturedRoomExporter.export(room, roomTypeConfirmation: coordinator.roomTypeConfirmationForExport, walkPath: coordinator.capturedRoomWalkPath)) }
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
        guard export.hasUsableFloorOutline else {
            isUploadingPartialCapture = false
            #if DEBUG
            DiagnosticsLog.shared.record("Local reject: floor outline too small/degenerate, upload skipped", category: .error)
            #endif
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
                expiresAt: session.expiresAt
            ))
        }

        PendingUploadStore.save(PendingUploadState(session: session, identity: identity, captures: [.init(idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)]))
        do {
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: idempotencyKey, bodyJSON: bodyJSON)
            PendingUploadStore.clear()
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
            justCaptured = (session, floorPlan)
        } catch {
            uploadRejection = (AppError(site: .captureUpload, underlying: error), export, session, idempotencyKey, bodyJSON)
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

struct DegenerateCaptureView: View {
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Keep scanning").font(.headline)
            Text("This room's outline came out too small or flat to use. Try scanning more slowly and cover the whole floor before tapping Done.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Rescan this room", action: onRescan).buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct UploadRejectedView: View {
    let error: AppError
    let onRetryUpload: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Upload didn't go through").font(.headline)
            ErrorCodeView(error: error)
                .multilineTextAlignment(.center)
            if error.isLikelyRetryable {
                Text("This room's capture is still on your device. Retry the same upload, or rescan if the room itself needs it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry upload", action: onRetryUpload).buttonStyle(.borderedProminent)
                Button("Rescan this room", role: .destructive, action: onRescan)
            } else {
                Text("The server rejected this capture's data — retrying the same upload won't change that. Rescanning this room is the way forward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Rescan this room", action: onRescan).buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct AttachmentsScreen: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onDone: (FloorPlan) -> Void

    @State private var noteText = ""
    @State private var photoUrl = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var current: FloorPlan
    @State private var appError: AppError?
    @State private var isSaving = false
    @State private var isUploadingPhoto = false
    @State private var selectedRoomId: String?
    @State private var showCamera = false
    @State private var batchUploadMessage: String?
    @State private var isUpdatingRoomType: Set<String> = []

    private let client = ScanServiceClient()

    private static let roomTypeOptions = RoomTypeClassifier.allTypes + ["other"]

    init(session: ScanSessionResponse, floorPlan: FloorPlan, onDone: @escaping (FloorPlan) -> Void) {
        self.session = session
        self.floorPlan = floorPlan
        self.onDone = onDone
        _current = State(initialValue: floorPlan)
    }

    var body: some View {
        Form {
            if current.rooms.count > 1 {
                Section("Applies to") {
                    Picker("Room", selection: $selectedRoomId) {
                        Text("Whole unit").tag(String?.none)
                        ForEach(current.rooms, id: \.roomId) { room in
                            Text(room.label).tag(String?.some(room.roomId))
                        }
                    }
                }
            }

            Section("Room type") {
                ForEach(current.rooms, id: \.roomId) { room in
                    VStack(alignment: .leading) {
                        Picker(room.label, selection: Binding(
                            get: { room.roomType?.confirmed },
                            set: { newValue in Task { await updateRoomType(roomId: room.roomId, to: newValue) } }
                        )) {
                            Text("Unset").tag(String?.none)
                            ForEach(Self.roomTypeOptions, id: \.self) { type in
                                Text(RoomTypeClassifier.displayName(for: type)).tag(String?.some(type))
                            }
                        }
                        .disabled(isUpdatingRoomType.contains(room.roomId))
                        if room.roomType?.confirmed == nil, let guess = room.roomType?.guess {
                            Text("Auto-detected: \(RoomTypeClassifier.displayName(for: guess))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Add a note (optional)") {
                TextField("Note text", text: $noteText, axis: .vertical)
                Button("Add note") { Task { await addNote() } }
                    .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            Section("Add a photo (optional)") {
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images) {
                    if isUploadingPhoto {
                        ProgressView()
                    } else {
                        Text("Choose from library")
                    }
                }
                .disabled(isUploadingPhoto)
                .onChange(of: selectedPhotoItems) { _, newItems in
                    guard !newItems.isEmpty else { return }
                    Task {
                        isUploadingPhoto = true
                        var failureCount = 0
                        for item in newItems {
                            if await uploadSelectedPhoto(item) == false {
                                failureCount += 1
                            }
                        }
                        selectedPhotoItems = []
                        isUploadingPhoto = false
                        batchUploadMessage = failureCount > 0 ? "\(failureCount) of \(newItems.count) photo(s) failed to upload." : nil
                    }
                }

                if let batchUploadMessage {
                    Text(batchUploadMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take a photo") {
                        showCamera = true
                    }
                    .disabled(isUploadingPhoto)
                    .sheet(isPresented: $showCamera) {
                        CameraCaptureView(onCaptured: { data in
                            showCamera = false
                            Task {
                                isUploadingPhoto = true
                                await uploadPhotoData(data)
                                isUploadingPhoto = false
                            }
                        }, onCancel: {
                            showCamera = false
                        })
                    }
                }

                Text("Or paste a URL to a photo already hosted elsewhere:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…", text: $photoUrl)
                Button("Add photo URL") { Task { await addPhoto() } }
                    .disabled(photoUrl.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            if !current.photos.isEmpty {
                Section("Photos attached") {
                    ForEach(current.photos, id: \.photoId) { photo in
                        HStack(alignment: .top, spacing: 12) {
                            AttachedPhotoThumbnail(session: session, url: photo.url)
                            VStack(alignment: .leading, spacing: 2) {
                                if let roomId = photo.roomId, let room = current.rooms.first(where: { $0.roomId == roomId }) {
                                    Text(room.label).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Whole unit").font(.caption).foregroundStyle(.secondary)
                                }
                                if !photo.caption.isEmpty {
                                    Text(photo.caption).font(.caption2)
                                }
                            }
                        }
                    }
                }
            }

            if !current.notes.isEmpty {
                Section("Notes attached") {
                    ForEach(current.notes, id: \.noteId) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            if let roomId = note.roomId, let room = current.rooms.first(where: { $0.roomId == roomId }) {
                                Text(room.label).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Whole unit").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(note.text)
                        }
                    }
                }
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
    private func updateRoomType(roomId: String, to newValue: String?) async {
        isUpdatingRoomType.insert(roomId)
        defer { isUpdatingRoomType.remove(roomId) }
        do {
            current = try await client.updateRoomType(sessionId: session.id, accessToken: session.accessToken, roomId: roomId, roomType: newValue)
            appError = nil
        } catch {
            appError = AppError(site: .roomTypeUpdate, underlying: error)
        }
    }

    @MainActor
    private func addNote() async {
        isSaving = true
        defer { isSaving = false }
        do {
            current = try await client.addNote(sessionId: session.id, accessToken: session.accessToken, text: noteText, roomId: selectedRoomId)
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
            current = try await client.addPhoto(sessionId: session.id, accessToken: session.accessToken, url: photoUrl, roomId: selectedRoomId)
            photoUrl = ""
            appError = nil
        } catch {
            appError = AppError(site: .photoAdd, underlying: error)
        }
    }

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

    private static let maxPhotoUploadBytes = 25 * 1024 * 1024

    @discardableResult
    private func uploadSelectedPhoto(_ item: PhotosPickerItem) async -> Bool {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                appError = AppError(site: .photoUpload, underlying: nil)
                return false
            }
            return await uploadPhotoData(data)
        } catch {
            appError = AppError(site: .photoUpload, underlying: error)
            return false
        }
    }

    @discardableResult
    private func uploadPhotoData(_ data: Data) async -> Bool {
        if data.count > Self.maxPhotoUploadBytes {
            appError = AppError(site: .photoTooLarge, underlying: nil)
            return false
        }
        do {
            let (mime, ext) = detectedMimeType(for: data)
            let uploaded = try await client.uploadPhoto(sessionId: session.id, accessToken: session.accessToken, imageData: data, filename: "photo.\(ext)", mimeType: mime)
            current = try await client.addPhoto(sessionId: session.id, accessToken: session.accessToken, url: uploaded.url, roomId: selectedRoomId)
            appError = nil
            return true
        } catch {
            appError = AppError(site: .photoUpload, underlying: error)
            return false
        }
    }
}

private struct AttachedPhotoThumbnail: View {
    let session: ScanSessionResponse
    let url: String

    @State private var image: UIImage?
    @State private var failed = false

    private let client = ScanServiceClient()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil else { return }
            do {
                let data = try await client.fetchPhotoData(url: url, accessToken: session.accessToken)
                image = UIImage(data: data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onCaptured: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            Task.detached(priority: .userInitiated) {
                let data = image.jpegData(compressionQuality: 0.9)
                await MainActor.run {
                    if let data {
                        self.parent.onCaptured(data)
                    } else {
                        self.parent.onCancel()
                    }
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
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
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private let client = ScanServiceClient()

    var body: some View {
        List {
            ForEach(floorPlan.rooms, id: \.roomId) { room in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(room.label).font(.headline)
                        if room.structureOriginM != nil {
                            Label("Fused", systemImage: "square.on.square")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
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
            let data = try await client.fetchFloorPlanImage(sessionId: session.id, accessToken: session.accessToken, unit: exportUnit)
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
            let data = try await client.fetchFloorPlanPDF(sessionId: session.id, accessToken: session.accessToken, unit: exportUnit)
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
