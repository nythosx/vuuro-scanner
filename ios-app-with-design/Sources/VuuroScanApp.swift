//
//  VuuroScanApp.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see Models/ScanIdentity.swift header.
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
        case error(String)
    }

    @State private var stage: Stage = .intake

    var body: some View {
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
                } onError: { message in
                    stage = .error(message)
                } onGoBack: {
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
            case .error(let message):
                ErrorView(message: message) { stage = .intake }
            }
        }
    }
}

private struct RoomCaptureFlowStep: View {
    let identity: ScanIdentity
    let existingSession: ScanSessionResponse?
    let onRoomCaptured: (ScanSessionResponse, FloorPlan, _ addAnotherRoom: Bool) -> Void
    let onError: (String) -> Void
    let onGoBack: () -> Void

    @StateObject private var coordinator = CaptureCoordinator()
    @State private var isUploading = false
    @State private var justCaptured: (session: ScanSessionResponse, floorPlan: FloorPlan)?

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
            onError("Capture finished without a usable room.")
        case .failed(let message):
            onError(message)
        case .scanning:
            break
        }
    }

    @MainActor
    private func submit(_ export: RoomPlanCaptureExport) async {
        isUploading = true
        defer { isUploading = false }
        do {
            let session: ScanSessionResponse
            if let existingSession {
                session = existingSession
            } else {
                session = try await client.createSession(identity: identity)
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
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            justCaptured = (session, floorPlan)
        } catch {
            onError("Upload failed: \(error.localizedDescription)")
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

private struct AttachmentsScreen: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onDone: (FloorPlan) -> Void

    @State private var noteText = ""
    @State private var photoUrl = ""
    @State private var current: FloorPlan
    @State private var errorMessage: String?
    @State private var isSaving = false

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

            Section("Add a photo URL (optional)") {
                TextField("https://…", text: $photoUrl)
                Button("Add photo") { Task { await addPhoto() } }
                    .disabled(photoUrl.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(VuuroColor.danger).font(VuuroFont.body(13))
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
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't add note: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func addPhoto() async {
        isSaving = true
        defer { isSaving = false }
        do {
            current = try await client.addPhoto(sessionId: session.id, accessToken: session.accessToken, url: photoUrl)
            photoUrl = ""
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't add photo: \(error.localizedDescription)"
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
    @State private var exportError: String?

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

                if let exportError {
                    Text(exportError).foregroundStyle(VuuroColor.danger).font(VuuroFont.body(13))
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
                exportError = "The floor plan image couldn't be decoded."
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(session.id).png")
            try data.write(to: url)
            floorPlanImage = image
            floorPlanImageURL = url
            exportError = nil
        } catch {
            exportError = "Couldn't load the floor plan image: \(error.localizedDescription)"
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
            exportError = nil
        } catch {
            exportError = "Couldn't load the floor plan PDF: \(error.localizedDescription)"
        }
    }
}

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Something went wrong")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
            Text(message)
                .font(VuuroFont.body())
                .foregroundStyle(VuuroColor.textPrimary.opacity(0.6))
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
