//
//  VuuroScanApp.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see Models/ScanIdentity.swift header.
//
//  Not a full app shell — there's no property/unit picker, auth, or
//  Vuuro-account wiring yet (all later, real decisions, not stubbed here).
//  This is the smallest entry point that exercises the Phase 1-2 path end
//  to end: identity intake (with a real occupied/consent step) -> device
//  capability check -> one or more guided room captures, stitched onto the
//  same session (PHASES.md Phase 2's "unit story") -> optional notes/photo
//  URLs on the finished unit -> show the returned FloorPlan. That's what
//  Phase 1 ("basic dimensions readable end to end") and Phase 2 ("multi-room
//  session... photos and notes attach to the same unit package") need
//  proven once a device/Xcode makes proving it possible.

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

/// Owns the whole manual-smoke-test flow: identity intake, one session
/// created once and reused across every room capture in it (this is what
/// makes it a "unit story" and not N unrelated single-room sessions), then
/// an optional attachments step before showing the result.
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
                // Forces a fresh CaptureCoordinator/RoomCaptureSession per
                // room attempt: SwiftUI would otherwise reuse the same
                // @StateObject across "capturing" re-entries (same case,
                // same position in the switch) since it doesn't diff enum
                // associated values for view identity.
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

/// One room capture, uploaded onto `existingSession` if there is one, or a
/// freshly created session otherwise. Reused for every room in a multi-room
/// session — the caller (ScanFlowView) decides whether to loop back here for
/// another room or move on, based on the user's choice in the completion
/// prompt below.
private struct RoomCaptureFlowStep: View {
    let identity: ScanIdentity
    let existingSession: ScanSessionResponse?
    let onRoomCaptured: (ScanSessionResponse, FloorPlan, _ addAnotherRoom: Bool) -> Void
    let onError: (String) -> Void

    @StateObject private var coordinator = CaptureCoordinator()
    @State private var isUploading = false
    @State private var justCaptured: (session: ScanSessionResponse, floorPlan: FloorPlan)?

    private let client = ScanServiceClient()

    var body: some View {
        Group {
            if !DeviceCapability.isRoomPlanSupported {
                UnsupportedDeviceScreen()
            } else if let justCaptured {
                AnotherRoomPromptView(roomCount: justCaptured.floorPlan.rooms.count) { addAnother in
                    onRoomCaptured(justCaptured.session, justCaptured.floorPlan, addAnother)
                }
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
            Task { await submit(room) }
        case .finished(roomAvailable: false):
            onError("Capture finished without a usable room.")
        case .failed(let message):
            onError(message)
        case .scanning:
            break
        }
    }

    @MainActor
    private func submit(_ room: CapturedRoom) async {
        isUploading = true
        defer { isUploading = false }
        do {
            let session: ScanSessionResponse
            if let existingSession {
                session = existingSession
            } else {
                session = try await client.createSession(identity: identity)
            }
            let export = CapturedRoomExporter.export(room)
            let floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            justCaptured = (session, floorPlan)
        } catch {
            onError("Upload failed: \(error.localizedDescription)")
        }
    }
}

/// Shown right after a room upload succeeds — "one more room, or done with
/// this unit?" — before the user leaves the property, matching PHASES.md
/// Phase 2's multi-room "unit story" and hard constraint #7's evidence
/// bucketing (a captured room is "implemented but not yet verified" until
/// this screen and the next both prove it end to end).
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

/// Optional last step before the summary: attach a note and/or a photo URL
/// to the finished unit package (PHASES.md Phase 2 — "photos and notes
/// attach to the same unit package, not a separate side-channel"). There is
/// no image picker/upload target here yet (see ScanServiceClient.addPhoto's
/// doc comment) — only a URL field, matching what the Scan Service actually
/// accepts today.
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

                // PHASES.md Phase 3: the point of this signal is showing it
                // here, before the user leaves the room — not buried in a
                // later report they'll never open.
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
