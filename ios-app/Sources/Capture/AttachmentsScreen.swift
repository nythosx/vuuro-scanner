import PhotosUI
import SwiftUI
import UIKit

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

    private let client = ScanServiceClient()

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
                leading: { VuuroNavButton("Home", icon: "chevron.left", action: onBack) },
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
        }
        .background(VuuroColor.bgApp)
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
            Text("No rooms captured for this scan.")
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

        if !unitPhotos.isEmpty || !unitNotes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Whole unit")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)

                RoomAttachmentsList(
                    session: session,
                    photos: unitPhotos,
                    notes: unitNotes
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
                onFinished(current)
            } label: {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Finish & upload")
                }
            }
            .buttonStyle(.vuuroPrimary)
            .disabled(isSaving)

            Button("Scan another room", action: onAddRoom)
                .buttonStyle(.vuuroGhostSmall)
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
    @State private var isSavingNote = false
    @State private var isUploadingPhoto = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var labelSaveTask: Task<Void, Never>?
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var showCameraPicker = false
    @State private var showPhotoSourceDialog = false
    @State private var showPhotoPicker = false

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
        _labelDraft = State(initialValue: room.label)
        _committedLabel = State(initialValue: room.label)
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
        .onAppear { seedNote() }
        .onDisappear { flushPendingSaves() }
        .confirmationDialog("Add a photo", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            Button("Take Photo") {
                showCameraPicker = true
            }
            Button("Choose from Library") {
                showPhotoPicker = true
            }
            Button("Cancel", role: .cancel) {}
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
        .onChange(of: photoPickerItems) { _, items in
            guard let item = items.first else { return }
            Task { await uploadPhoto(item) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(room.label)
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

    private var labelField: some View {
        TextField("Room type", text: $labelDraft)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(VuuroColor.textSecondary)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onChange(of: labelDraft) { _, _ in scheduleLabelSave() }
            .onSubmit { flushLabelSave() }
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $noteDraft)
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
                .disabled(isUploadingPhoto)
            }
            .padding(.vertical, 2)
        }
    }

    private func seedNote() {
        guard let first = notes.first else { return }
        if noteDraft.isEmpty {
            noteDraft = first.text
            committedNote = first.text
            savedNoteId = first.noteId
        }
    }

    private func scheduleLabelSave() {
        guard labelDraft != committedLabel else { return }
        labelSaveTask?.cancel()
        let target = labelDraft
        labelSaveTask = Task { @MainActor in
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
        guard !trimmed.isEmpty else { return }
        guard trimmed != committedLabel else { return }
        do {
            let updated = try await client.updateRoomLabel(
                sessionId: session.id,
                accessToken: session.accessToken,
                roomId: room.roomId,
                label: trimmed
            )
            committedLabel = trimmed
            onUpdate(updated)
        } catch is CancellationError {
            DiagnosticsLog.shared.record("Label save task was cancelled.", category: .info)
        } catch {
            onError(AppError(site: .roomLabelUpdate, underlying: error))
            labelDraft = committedLabel
        }
    }

    private func scheduleNoteSave() {
        guard noteDraft != committedNote else { return }
        noteSaveTask?.cancel()
        let target = noteDraft
        let existing = savedNoteId
        noteSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await saveNote(target, existingId: existing)
        }
    }

    private func flushPendingSaves() {
        labelSaveTask?.cancel()
        noteSaveTask?.cancel()
        let labelTarget = labelDraft
        let noteTarget = noteDraft
        let existingNote = savedNoteId
        Task { @MainActor in
            if labelTarget != committedLabel {
                await saveLabel(labelTarget)
            }
            if noteTarget != committedNote {
                await saveNote(noteTarget, existingId: existingNote)
            }
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
            if let existingId {
                updated = try await client.updateNote(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    noteId: existingId,
                    text: trimmed
                )
            } else {
                updated = try await client.addNote(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    text: trimmed,
                    roomId: room.roomId
                )
            }
            savedNoteId = updated.notes
                .first(where: { $0.roomId == room.roomId })?
                .noteId ?? existingId
            committedNote = text
            onUpdate(updated)
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
            guard let data = try await item.loadTransferable(type: Data.self) else {
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
            VuuroToast.shared.show(String(localized: "Photo added"))
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
            VuuroToast.shared.show(String(localized: "Photo added"))
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
                (
                    Text("Note: ").font(.system(size: 12, weight: .semibold))
                    + Text(note.text).font(.system(size: 12))
                )
                .foregroundStyle(VuuroColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                }

                Button {
                    Task { await confirmAndDelete() }
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
                .buttonStyle(.plain)
                .disabled(isDeleting)
            }
        }
        .padding(.bottom, 32)
    }

    private func confirmAndDelete() async {
        await deletePhoto()
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
            VuuroToast.shared.show(String(localized: "Photo removed"))
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