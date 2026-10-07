import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class AttachmentFlushCoordinator: ObservableObject {
    @Published private(set) var generation: Int = 0
    private var expected: Int = 0
    private var received: Int = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func reset(expected: Int) {
        self.expected = expected
        self.received = 0
        if expected == 0, let continuation {
            continuation.resume()
            self.continuation = nil
        }
    }

    func signal() {
        guard expected > 0 else { return }
        received += 1
        if received >= expected, let continuation {
            continuation.resume()
            self.continuation = nil
        }
    }

    func requestFlush() async {
        if expected == 0 { return }
        if received >= expected { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func bumpGeneration() {
        generation &+= 1
    }
}

struct AttachmentsScreen: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onFinished: (FloorPlan) -> Void
    let onAddRoom: () -> Void
    let onBack: () -> Void

    @State private var current: FloorPlan
    @State private var isSaving = false
    @State private var appError: AppError?
    @State private var preview: PhotoPreview?
    @StateObject private var flushCoordinator = AttachmentFlushCoordinator()

    private let client = ScanServiceClient()

    private var expectedFlushCount: Int {
        var count = current.rooms.count
        let unitPhotos = current.photos.filter { $0.roomId == nil }
        let unitNotes = current.notes.filter { $0.roomId == nil }
        if !unitPhotos.isEmpty || !unitNotes.isEmpty || current.rooms.isEmpty {
            count += 1
        }
        return count
    }

    init(
        session: ScanSessionResponse,
        floorPlan: FloorPlan,
        onFinished: @escaping (FloorPlan) -> Void,
        onAddRoom: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) {
        self.session = session
        self.floorPlan = floorPlan
        self.onFinished = onFinished
        self.onAddRoom = onAddRoom
        self.onBack = onBack
        _current = State(initialValue: floorPlan)
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Notes & photos",
                leading: { VuuroNavButton("Home", icon: "chevron.left", action: onBack).accessibilityIdentifier("attachments.home") },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroHero(
                        greeting: nil,
                        title: "Add context",
                        subtitle: "Attach photos and notes per room. They'll appear on the PDF export."
                    )

                    roomsSection
                    unitSection
                    actionButtons

                    if let appError {
                        ErrorCodeView(error: appError)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer().frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
            .disabled(isSaving)
        }
        .background(VuuroColor.bgApp)
        .environmentObject(flushCoordinator)
        .sheet(item: $preview) { item in
            AttachmentPhotoViewer(
                session: session,
                photo: item.photo,
                onDelete: { updated in
                    current = updated
                    preview = nil
                },
                onClose: { preview = nil }
            )
        }
    }

    @ViewBuilder
    private var roomsSection: some View {
        if current.rooms.isEmpty {
            Text(current.rooms.isEmpty && current.photos.isEmpty && current.notes.isEmpty
                 ? "Notes-only session. Add notes and photos below."
                 : "No rooms captured for this scan.")
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(VuuroColor.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
                .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        } else {
            ForEach(current.rooms, id: \.roomId) { room in
                AttachmentRoomCard(
                    session: session,
                    room: room,
                    photos: current.photos.filter { $0.roomId == room.roomId },
                    notes: current.notes.filter { $0.roomId == room.roomId },
                    onOpenPhoto: { photo in
                        preview = PhotoPreview(photo: photo)
                    },
                    onUpdate: { updated in current = updated },
                    onError: { appError = $0 }
                )
            }
        }
    }

    @ViewBuilder
    private var unitSection: some View {
        let unitPhotos = current.photos.filter { $0.roomId == nil }
        let unitNotes = current.notes.filter { $0.roomId == nil }

        if !unitPhotos.isEmpty || !unitNotes.isEmpty || current.rooms.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.rooms.isEmpty ? "Whole session (no rooms)" : "Whole unit")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)

                if unitNotes.count > 1 {
                    RoomAttachmentsList(
                        session: session,
                        photos: [],
                        notes: Array(unitNotes.dropFirst())
                    )
                }

                SessionAttachmentEditor(
                    session: session,
                    notes: unitNotes,
                    photos: unitPhotos,
                    onUpdate: { updated in current = updated },
                    onError: { appError = $0 }
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                guard !isSaving else { return }
                isSaving = true
                let expected = expectedFlushCount
                flushCoordinator.reset(expected: expected)
                flushCoordinator.bumpGeneration()
                Task { @MainActor in
                    await flushCoordinator.requestFlush()
                    onFinished(current)
                }
            } label: {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Finish & upload")
                }
            }
            .accessibilityIdentifier("attachments.finishAndUpload")
            .buttonStyle(.vuuroPrimary)
            .disabled(isSaving)

            if DeviceCapability.canCaptureRooms {
                Button("Scan another room", action: onAddRoom)
                    .accessibilityIdentifier("attachments.scanAnotherRoom")
                    .buttonStyle(.vuuroGhostSmall)
                    .disabled(isSaving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

private struct PhotoPreview: Identifiable {
    let photo: FloorPlan.Photo
    var id: String { photo.photoId }
}

private struct AttachmentRoomCard: View {
    let session: ScanSessionResponse
    let room: FloorPlan.Room
    let photos: [FloorPlan.Photo]
    let notes: [FloorPlan.Note]
    let onOpenPhoto: (FloorPlan.Photo) -> Void
    let onUpdate: (FloorPlan) -> Void
    let onError: (AppError) -> Void

    @State private var labelDraft: String
    @State private var committedLabel: String
    @State private var noteDraft: String = ""
    @State private var committedNote: String = ""
    @State private var savedNoteId: String?
    @State private var selectedTags: Set<InspectionTag> = []
    @State private var committedTags: Set<InspectionTag> = []
    @State private var isSavingNote = false
    @State private var isUploadingPhoto = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var labelSaveTask: Task<Void, Never>?
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var showCameraPicker = false
    @EnvironmentObject private var flushCoordinator: AttachmentFlushCoordinator
    @State private var showCameraDeniedAlert = false
    @State private var showPhotoSourceDialog = false
    @State private var showPhotoPicker = false
    @Environment(\.scenePhase) private var scenePhase

    private let client = ScanServiceClient()

    init(
        session: ScanSessionResponse,
        room: FloorPlan.Room,
        photos: [FloorPlan.Photo],
        notes: [FloorPlan.Note],
        onOpenPhoto: @escaping (FloorPlan.Photo) -> Void,
        onUpdate: @escaping (FloorPlan) -> Void,
        onError: @escaping (AppError) -> Void
    ) {
        self.session = session
        self.room = room
        self.photos = photos
        self.notes = notes
        self.onOpenPhoto = onOpenPhoto
        self.onUpdate = onUpdate
        self.onError = onError
        let confirmedType = Self.confirmedTypeText(for: room)
        _labelDraft = State(initialValue: confirmedType)
        _committedLabel = State(initialValue: confirmedType)
    }

    private static func confirmedTypeText(for room: FloorPlan.Room) -> String {
        guard let confirmed = room.roomType?.confirmed, !confirmed.isEmpty else { return "" }
        return RoomTypeClassifier.displayName(for: confirmed)
    }

    private var roomTypePlaceholder: String {
        if let guess = room.roomType?.guess, !guess.isEmpty {
            return String(format: vuuroLocalized("Room type (suggested: %@)"), RoomTypeClassifier.displayName(for: guess))
        }
        return vuuroLocalized("Room type, e.g. Living room")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            labelField
            noteEditor
            photoStrip
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .onAppear { seedFromDraftOrServer() }
        .onDisappear { flushPendingSaves() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                flushPendingSaves()
            }
        }
        .onChange(of: flushCoordinator.generation) { _, _ in
            Task { @MainActor in
                await flushPendingSavesAsync()
                flushCoordinator.signal()
            }
        }
        .confirmationDialog("Add a photo", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            if CameraAccess.canTakePhoto {
                Button("Take Photo") {
                    if CameraAccess.isDenied {
                        showCameraDeniedAlert = true
                    } else {
                        showCameraPicker = true
                    }
                }
                .accessibilityIdentifier("attachments.takePhoto")
            }
            Button("Choose from Library") {
                showPhotoPicker = true
            }
            .accessibilityIdentifier("attachments.chooseFromLibrary")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("attachments.photoSourceCancel")
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView(
                onImageCaptured: { image in
                    if let data = image.jpegData(compressionQuality: 0.8) {
                        Task { await uploadPhotoData(data) }
                    }
                },
                onDismiss: {
                    showCameraPicker = false
                }
            )
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 1, matching: .images)
        .cameraDeniedAlert(isPresented: $showCameraDeniedAlert, onChooseFromLibrary: { showPhotoPicker = true })
        .onChange(of: photoPickerItems) { _, items in
            guard let item = items.first else { return }
            Task { await uploadPhoto(item) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(VuuroColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
                VuuroBadge("Confirmed", systemImage: "checkmark", style: .info)
            }
        }
    }

    private var headerTitle: String {
        let confirmed = Self.confirmedTypeText(for: room)
        return confirmed.isEmpty ? room.label : confirmed
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(roomTypePlaceholder, text: $labelDraft)
                .accessibilityIdentifier("attachments.roomLabel")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VuuroColor.textSecondary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onChange(of: labelDraft) { _, _ in scheduleLabelSave() }
                .onSubmit { flushLabelSave() }

            if let suggestion = suggestedLabel, labelDraft.isEmpty {
                Button {
                    labelDraft = suggestion
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(format: vuuroLocalized("Use %@"), suggestion))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(VuuroColor.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(VuuroColor.accent.opacity(0.12), in: Capsule())
                }
                .accessibilityIdentifier("attachments.roomLabelSuggestion")
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestedLabel: String? {
        guard let guess = room.roomType?.guess, !guess.isEmpty else { return nil }
        return RoomTypeClassifier.displayName(for: guess)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if notes.count > 1 {
                Text("\(notes.count) notes attached — editing the first. Open the result screen to see all.")
                    .font(.system(size: 11))
                    .foregroundStyle(VuuroColor.warningText)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteDraft)
                    .accessibilityIdentifier("attachments.note")
                    .font(.system(size: 14))
                    .frame(minHeight: 68)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                if noteDraft.isEmpty {
                    Text("Add notes…")
                        .font(.system(size: 14))
                        .foregroundStyle(VuuroColor.textTertiary)
                        .padding(.top, 16)
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                }
            }
            .background(VuuroColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(VuuroColor.borderMed, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: noteDraft) { _, _ in scheduleNoteSave() }
            InspectionTagPicker(selected: $selectedTags)
                .onChange(of: selectedTags) { _, _ in scheduleNoteSave() }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos, id: \.photoId) { photo in
                    AttachedPhotoThumbnail(session: session, url: photo.url) {
                        onOpenPhoto(photo)
                    }
                }

                Button {
                    showPhotoSourceDialog = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(VuuroColor.bgInset)
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                VuuroColor.borderMed,
                                style: StrokeStyle(lineWidth: 2, dash: [4])
                            )
                        if isUploadingPhoto {
                            ProgressView().tint(VuuroColor.accent)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(VuuroColor.textTertiary)
                        }
                    }
                    .frame(width: 64, height: 64)
                }
                .accessibilityIdentifier("attachments.addPhoto")
                .disabled(isUploadingPhoto)
            }
            .padding(.vertical, 2)
        }
    }

    private func seedFromDraftOrServer() {
        let serverTags = Set((notes.first?.tags ?? []).compactMap { InspectionTag(rawValue: $0) })
        let draft = DraftStore.drafts(for: session.id).rooms[room.roomId]
        if let draft {
            committedLabel = Self.confirmedTypeText(for: room)
            labelDraft = draft.label == room.label ? committedLabel : draft.label
            noteDraft = draft.note
            committedNote = notes.first?.text ?? ""
            savedNoteId = draft.savedNoteId ?? notes.first?.noteId
            committedTags = serverTags
            selectedTags = Set(draft.noteTags.compactMap { InspectionTag(rawValue: $0) })
            return
        }
        if let first = notes.first, noteDraft.isEmpty {
            noteDraft = first.text
            committedNote = first.text
            savedNoteId = first.noteId
            committedTags = serverTags
            selectedTags = serverTags
        }
    }

    private func persistDraft() {
        var drafts = DraftStore.drafts(for: session.id)
        drafts.rooms[room.roomId] = RoomDraft(
            label: labelDraft,
            note: noteDraft,
            noteTags: Array(selectedTags).map { $0.rawValue },
            savedNoteId: savedNoteId
        )
        DraftStore.save(drafts, sessionId: session.id)
    }

    private func clearDraftIfFullySynced() {
        if labelDraft == committedLabel && noteDraft == committedNote && selectedTags == committedTags {
            DraftStore.clearRoom(sessionId: session.id, roomId: room.roomId)
        }
    }

    private func scheduleLabelSave() {
        guard labelDraft != committedLabel else { return }
        labelSaveTask?.cancel()
        let target = labelDraft
        labelSaveTask = Task { @MainActor in
            persistDraft()
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await saveLabel(target)
        }
    }

    private func flushLabelSave() {
        labelSaveTask?.cancel()
        let target = labelDraft
        guard target != committedLabel else { return }
        labelSaveTask = Task { @MainActor in
            await saveLabel(target)
        }
    }

    @MainActor
    private func saveLabel(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storedValue = RoomTypeClassifier.storedValue(forEntered: trimmed) else { return }
        guard trimmed != committedLabel else { return }
        do {
            let updated = try await client.updateRoomType(
                sessionId: session.id,
                accessToken: session.accessToken,
                roomId: room.roomId,
                roomType: storedValue
            )
            committedLabel = trimmed
            onUpdate(updated)
            clearDraftIfFullySynced()
        } catch is CancellationError {
            DiagnosticsLog.shared.record("Room type save task was cancelled.", category: .info)
        } catch {
            onError(AppError(site: .roomTypeUpdate, underlying: error))
            labelDraft = committedLabel
        }
    }

    private func scheduleNoteSave() {
        guard noteDraft != committedNote || selectedTags != committedTags else { return }
        noteSaveTask?.cancel()
        let target = noteDraft
        let existing = savedNoteId
        noteSaveTask = Task { @MainActor in
            persistDraft()
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await saveNote(target, existingId: existing)
        }
    }

    private func flushPendingSaves() {
        Task { @MainActor in await flushPendingSavesAsync() }
    }

    @MainActor
    private func flushPendingSavesAsync() async {
        labelSaveTask?.cancel()
        noteSaveTask?.cancel()
        let labelTarget = labelDraft
        let noteTarget = noteDraft
        let existingNote = savedNoteId
        persistDraft()
        if labelTarget != committedLabel {
            await saveLabel(labelTarget)
        }
        if noteTarget != committedNote || selectedTags != committedTags {
            await saveNote(noteTarget, existingId: existingNote)
        }
    }

    @MainActor
    private func saveNote(_ text: String, existingId: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSavingNote else { return }
        isSavingNote = true
        defer { isSavingNote = false }
        do {
            let updated: FloorPlan
            let tagList = Array(selectedTags)
            if let existingId {
                updated = try await client.updateNote(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    noteId: existingId,
                    text: trimmed,
                    tags: tagList
                )
            } else {
                updated = try await client.addNote(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    text: trimmed,
                    roomId: room.roomId,
                    tags: tagList
                )
            }
            savedNoteId = updated.notes
                .first(where: { $0.roomId == room.roomId })?
                .noteId ?? existingId
            committedNote = text
            committedTags = Set(tagList)
            onUpdate(updated)
            clearDraftIfFullySynced()
        } catch is CancellationError {
            DiagnosticsLog.shared.record("Note save task was cancelled.", category: .info)
        } catch {
            onError(AppError(site: .noteAdd, underlying: error))
        }
    }

    @MainActor
    private func uploadPhoto(_ item: PhotosPickerItem) async {
        defer { photoPickerItems = [] }
        guard !isUploadingPhoto else { return }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let data = PhotoUploadImage.jpegData(from: raw) else {
                throw PlainError(message: "Couldn't read the selected photo.")
            }
            if data.count > 25 * 1024 * 1024 {
                throw PlainError(message: AppError.Site.photoTooLarge.defaultMessage)
            }
            let upload = try await client.uploadPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                imageData: data,
                filename: "room-\(room.roomId).jpg",
                mimeType: "image/jpeg"
            )
            let updated = try await client.addPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                url: upload.url,
                caption: "",
                roomId: room.roomId
            )
            onUpdate(updated)
            VuuroToast.shared.show(vuuroLocalized("Photo added"))
        } catch is CancellationError {
        } catch {
            onError(AppError(site: .photoUpload, underlying: error))
        }
    }

    @MainActor
    private func uploadPhotoData(_ data: Data) async {
        guard !isUploadingPhoto else { return }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            if data.count > 25 * 1024 * 1024 {
                throw PlainError(message: AppError.Site.photoTooLarge.defaultMessage)
            }
            let upload = try await client.uploadPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                imageData: data,
                filename: "room-\(room.roomId).jpg",
                mimeType: "image/jpeg"
            )
            let updated = try await client.addPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                url: upload.url,
                caption: "",
                roomId: room.roomId
            )
            onUpdate(updated)
            VuuroToast.shared.show(vuuroLocalized("Photo added"))
        } catch is CancellationError {
        } catch {
            onError(AppError(site: .photoUpload, underlying: error))
        }
    }
}

struct CameraPickerView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (UIImage) -> Void
        let onDismiss: () -> Void

        init(onImageCaptured: @escaping (UIImage) -> Void, onDismiss: @escaping () -> Void) {
            self.onImageCaptured = onImageCaptured
            self.onDismiss = onDismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImageCaptured(image)
            }
            onDismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDismiss()
        }
    }
}

struct RoomAttachmentsList: View {
    let session: ScanSessionResponse
    let photos: [FloorPlan.Photo]
    let notes: [FloorPlan.Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notes, id: \.noteId) { note in
                VStack(alignment: .leading, spacing: 4) {
                    (
                        Text("Note: ").font(.system(size: 12, weight: .semibold))
                        + Text(note.text).font(.system(size: 12))
                    )
                    .foregroundStyle(VuuroColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    InspectionTagChips(tags: note.tags ?? [])
                }
            }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos, id: \.photoId) { photo in
                            AttachedPhotoThumbnail(session: session, url: photo.url) {}
                        }
                    }
                }
            }
        }
    }
}

struct AttachedPhotoThumbnail: View {
    let session: ScanSessionResponse
    let url: String
    var onTap: (() -> Void)?

    @State private var image: UIImage?
    @State private var isLoading = false

    private let client = ScanServiceClient()

    var body: some View {
        Button {
            onTap?()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VuuroColor.bgInset)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if isLoading {
                    ProgressView().tint(VuuroColor.accent)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(VuuroColor.textTertiary)
                }
            }
            .frame(width: 64, height: 64)
            .clipped()
        }
        .accessibilityIdentifier("attachments.photoThumbnail")
        .buttonStyle(.plain)
        .task(id: url) {
            if let cached = PhotoImageCache.shared.image(for: url) {
                image = cached
                return
            }
            guard image == nil, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            if let data = try? await client.fetchPhotoData(url: url, accessToken: session.accessToken),
               let decoded = UIImage(data: data) {
                PhotoImageCache.shared.store(decoded, for: url)
                image = decoded
            }
        }
    }
}

private struct AttachmentPhotoViewer: View {
    let session: ScanSessionResponse
    let photo: FloorPlan.Photo
    let onDelete: (FloorPlan) -> Void
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var deleteError: AppError?

    private let client = ScanServiceClient()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                body_
                Spacer(minLength: 0)
                footer
            }
        }
        .task { await loadImage() }
        .alert("Delete this photo?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deletePhoto() }
            }
            .accessibilityIdentifier("photoViewer.deleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photo is removed from this scan and from the server. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Photo")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityIdentifier("photoViewer.close")
            .accessibilityLabel("Close photo")
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var body_: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(20)
        } else if isLoading {
            ProgressView().tint(.white)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Couldn't load this photo.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let deleteError {
                ErrorCodeView(error: deleteError)
                    .frame(maxWidth: 320)
            }

            HStack(spacing: 10) {
                if let image {
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Photo", image: Image(uiImage: image))
                    ) {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityIdentifier("photoViewer.save")
                }

                Button {
                    showDeleteConfirmation = true
                } label: {
                    if isDeleting {
                        ProgressView().tint(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    } else {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.39))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
                .accessibilityIdentifier("photoViewer.delete")
                .accessibilityLabel("Delete photo")
                .buttonStyle(.plain)
                .disabled(isDeleting)
            }
        }
        .padding(.bottom, 32)
    }

    @MainActor
    private func loadImage() async {
        if let cached = PhotoImageCache.shared.image(for: photo.url) {
            image = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        if let data = try? await client.fetchPhotoData(url: photo.url, accessToken: session.accessToken),
           let decoded = UIImage(data: data) {
            PhotoImageCache.shared.store(decoded, for: photo.url)
            image = decoded
        }
    }

    @MainActor
    private func deletePhoto() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let updated = try await client.deletePhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                photoId: photo.photoId
            )
            PhotoImageCache.shared.remove(for: photo.url)
            VuuroToast.shared.show(vuuroLocalized("Photo removed"))
            onDelete(updated)
        } catch {
            deleteError = AppError(site: .photoDelete, underlying: error)
        }
    }
}

@MainActor
final class PhotoImageCache {
    static let shared = PhotoImageCache()

    private let entries: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private init() {}

    func image(for url: String) -> UIImage? {
        entries.object(forKey: url as NSString)
    }

    func store(_ image: UIImage, for url: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        entries.setObject(image, forKey: url as NSString, cost: cost)
    }

    func remove(for url: String) {
        entries.removeObject(forKey: url as NSString)
    }

    func clear() {
        entries.removeAllObjects()
    }
}

private struct SessionAttachmentEditor: View {
    let session: ScanSessionResponse
    let notes: [FloorPlan.Note]
    var photos: [FloorPlan.Photo] = []
    let onUpdate: (FloorPlan) -> Void
    let onError: (AppError) -> Void

    @State private var noteDraft: String = ""
    @State private var committedNote: String = ""
    @State private var savedNoteId: String? = nil
    @State private var selectedTags: Set<InspectionTag> = []
    @State private var committedTags: Set<InspectionTag> = []
    @State private var isSavingNote = false
    @State private var noteSaveTask: Task<Void, Never>? = nil
    @State private var didSeed = false

    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showCameraPicker = false
    @State private var showCameraDeniedAlert = false
    @State private var showPhotoSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var isUploadingPhoto = false
    @State private var removingPhotoIds: Set<String> = []
    @EnvironmentObject private var flushCoordinator: AttachmentFlushCoordinator

    private let client = ScanServiceClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session notes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VuuroColor.textSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteDraft)
                    .accessibilityIdentifier("attachments.sessionNote")
                    .font(.system(size: 14))
                    .frame(minHeight: 68)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                if noteDraft.isEmpty {
                    Text("Add notes for this session…")
                        .font(.system(size: 14))
                        .foregroundStyle(VuuroColor.textTertiary)
                        .padding(.top, 16)
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                }
            }
            .background(VuuroColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(VuuroColor.borderMed, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: noteDraft) { _, _ in scheduleSave() }
            InspectionTagPicker(selected: $selectedTags)
                .onChange(of: selectedTags) { _, _ in scheduleSave() }
            if isSavingNote {
                HStack(spacing: 6) {
                    ProgressView().tint(VuuroColor.accent)
                    Text("Saving note…")
                        .font(.system(size: 11))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
            }

            Divider().background(VuuroColor.borderSoft)

            Text("Session photos")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VuuroColor.textSecondary)
            photoStrip
        }
        .onAppear { seedIfNeeded() }
        .onDisappear {
            noteSaveTask?.cancel()
            flushSave()
        }
        .onChange(of: flushCoordinator.generation) { _, _ in
            Task { @MainActor in
                await flushSaveAsync()
                flushCoordinator.signal()
            }
        }
        .confirmationDialog("Add a photo", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            if CameraAccess.canTakePhoto {
                Button("Take Photo") {
                    if CameraAccess.isDenied {
                        showCameraDeniedAlert = true
                    } else {
                        showCameraPicker = true
                    }
                }
                .accessibilityIdentifier("sessionAttachments.takePhoto")
            }
            Button("Choose from Library") { showPhotoPicker = true }
                .accessibilityIdentifier("sessionAttachments.chooseFromLibrary")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("sessionAttachments.photoSourceCancel")
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView(
                onImageCaptured: { image in
                    if let data = image.jpegData(compressionQuality: 0.8) {
                        Task { await uploadPhotoData(data) }
                    }
                },
                onDismiss: { showCameraPicker = false }
            )
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 1, matching: .images)
        .cameraDeniedAlert(isPresented: $showCameraDeniedAlert, onChooseFromLibrary: { showPhotoPicker = true })
        .onChange(of: photoPickerItems) { _, items in
            guard let item = items.first else { return }
            Task { await uploadPhoto(item) }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos, id: \.photoId) { photo in
                    ZStack(alignment: .topTrailing) {
                        AttachedPhotoThumbnail(session: session, url: photo.url) {}
                        Button {
                            Task { await removePhoto(photo.photoId) }
                        } label: {
                            if removingPhotoIds.contains(photo.photoId) {
                                ProgressView().tint(.white).padding(4)
                            } else {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Color.black.opacity(0.7), in: Circle())
                            }
                        }
                        .accessibilityIdentifier("sessionAttachments.removePhoto.\(photo.photoId)")
                        .buttonStyle(.plain)
                        .disabled(removingPhotoIds.contains(photo.photoId))
                    }
                }

                Button {
                    showPhotoSourceDialog = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(VuuroColor.bgInset)
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(VuuroColor.borderMed, style: StrokeStyle(lineWidth: 2, dash: [4]))
                        if isUploadingPhoto {
                            ProgressView().tint(VuuroColor.accent)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(VuuroColor.textTertiary)
                        }
                    }
                    .frame(width: 64, height: 64)
                }
                .accessibilityIdentifier("sessionAttachments.addPhoto")
                .disabled(isUploadingPhoto)
            }
            .padding(.vertical, 2)
        }
    }

    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        let serverTags = Set((notes.first?.tags ?? []).compactMap { InspectionTag(rawValue: $0) })
        if let draft = DraftStore.drafts(for: session.id).sessionNote {
            noteDraft = draft.note
            committedNote = notes.first?.text ?? ""
            savedNoteId = draft.savedNoteId ?? notes.first?.noteId
            committedTags = serverTags
            selectedTags = Set(draft.noteTags.compactMap { InspectionTag(rawValue: $0) })
            return
        }
        guard let first = notes.first else { return }
        noteDraft = first.text
        committedNote = first.text
        savedNoteId = first.noteId
        committedTags = serverTags
        selectedTags = serverTags
    }

    private func persistDraft() {
        var drafts = DraftStore.drafts(for: session.id)
        drafts.sessionNote = SessionNoteDraft(
            note: noteDraft,
            noteTags: Array(selectedTags).map { $0.rawValue },
            savedNoteId: savedNoteId
        )
        DraftStore.save(drafts, sessionId: session.id)
    }

    private func clearDraftIfFullySynced() {
        if noteDraft == committedNote && selectedTags == committedTags {
            DraftStore.clearSessionNote(sessionId: session.id)
        }
    }

    private func scheduleSave() {
        guard noteDraft != committedNote || selectedTags != committedTags else { return }
        noteSaveTask?.cancel()
        noteSaveTask = Task { @MainActor in
            persistDraft()
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func flushSave() {
        Task { @MainActor in await flushSaveAsync() }
    }

    @MainActor
    private func flushSaveAsync() async {
        noteSaveTask?.cancel()
        persistDraft()
        await save()
    }

    @MainActor
    private func save() async {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && savedNoteId == nil { return }
        guard !isSavingNote else { return }
        if trimmed == committedNote && selectedTags == committedTags { return }
        isSavingNote = true
        defer { isSavingNote = false }
        let tagList = Array(selectedTags)
        do {
            let updated: FloorPlan
            if let existingId = savedNoteId {
                if trimmed.isEmpty {
                    updated = try await client.deleteNote(
                        sessionId: session.id,
                        accessToken: session.accessToken,
                        noteId: existingId
                    )
                    savedNoteId = nil
                    committedNote = ""
                    committedTags = []
                } else {
                    updated = try await client.updateNote(
                        sessionId: session.id,
                        accessToken: session.accessToken,
                        noteId: existingId,
                        text: trimmed,
                        tags: tagList
                    )
                    committedNote = trimmed
                    committedTags = Set(tagList)
                }
            } else {
                updated = try await client.addNote(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    text: trimmed,
                    roomId: nil,
                    tags: tagList
                )
                savedNoteId = updated.notes.first(where: { $0.roomId == nil })?.noteId
                committedNote = trimmed
                committedTags = Set(tagList)
            }
            onUpdate(updated)
            clearDraftIfFullySynced()
        } catch is CancellationError {
        } catch {
            onError(AppError(site: .noteAdd, underlying: error))
        }
    }

    @MainActor
    private func uploadPhoto(_ item: PhotosPickerItem) async {
        defer { photoPickerItems = [] }
        guard !isUploadingPhoto else { return }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let data = PhotoUploadImage.jpegData(from: raw) else {
                throw PlainError(message: "Couldn't read the selected photo.")
            }
            if data.count > 25 * 1024 * 1024 {
                throw PlainError(message: AppError.Site.photoTooLarge.defaultMessage)
            }
            let upload = try await client.uploadPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                imageData: data,
                filename: "session.jpg",
                mimeType: "image/jpeg"
            )
            let updated = try await client.addPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                url: upload.url,
                caption: "",
                roomId: nil
            )
            onUpdate(updated)
            VuuroToast.shared.show(vuuroLocalized("Photo added"))
        } catch is CancellationError {
        } catch {
            onError(AppError(site: .photoUpload, underlying: error))
        }
    }

    @MainActor
    private func uploadPhotoData(_ data: Data) async {
        guard !isUploadingPhoto else { return }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            if data.count > 25 * 1024 * 1024 {
                throw PlainError(message: AppError.Site.photoTooLarge.defaultMessage)
            }
            let upload = try await client.uploadPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                imageData: data,
                filename: "session.jpg",
                mimeType: "image/jpeg"
            )
            let updated = try await client.addPhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                url: upload.url,
                caption: "",
                roomId: nil
            )
            onUpdate(updated)
            VuuroToast.shared.show(vuuroLocalized("Photo added"))
        } catch is CancellationError {
        } catch {
            onError(AppError(site: .photoUpload, underlying: error))
        }
    }

    @MainActor
    private func removePhoto(_ photoId: String) async {
        guard !removingPhotoIds.contains(photoId) else { return }
        removingPhotoIds.insert(photoId)
        defer { removingPhotoIds.remove(photoId) }
        do {
            let updated = try await client.deletePhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                photoId: photoId
            )
            onUpdate(updated)
            VuuroToast.shared.show(vuuroLocalized("Photo removed"))
        } catch is CancellationError {
        } catch {
            onError(AppError(site: .photoDelete, underlying: error))
        }
    }
}
