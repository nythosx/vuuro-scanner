//
//  VuuroScanApp.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see Models/ScanIdentity.swift header.
import RoomPlan
import SwiftUI

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
        case summary(FloorPlan)
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
            case .capturing(let identity, let session, let attempt):
                RoomCaptureFlowStep(identity: identity, existingSession: session) { session, floorPlan, addAnotherRoom in
                    if addAnotherRoom {
                        stage = .capturing(identity: identity, session: session, attempt: UUID())
                    } else {
                        stage = .attachments(session: session, floorPlan: floorPlan)
                    }
                } onError: { message in
                    stage = .error(message)
                }

                .id(attempt)
            case .attachments(let session, let floorPlan):
                AttachmentsScreen(session: session, floorPlan: floorPlan) { updated in
                    stage = .summary(updated)
                }
            case .summary(let floorPlan):
                ResultSummaryView(floorPlan: floorPlan)
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
                UnsupportedDeviceScreen()
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
                Text(errorMessage).foregroundStyle(.red).font(.caption)
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
    let floorPlan: FloorPlan

    var body: some View {
        List(floorPlan.rooms, id: \.roomId) { room in
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
        .navigationTitle("Scan result")
    }
}

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Something went wrong").font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again", action: onRetry).buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
