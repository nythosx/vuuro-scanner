import PhotosUI
import SwiftUI

struct ZoomableImage: View {
    let image: UIImage
    var onSingleTap: (() -> Void)? = nil

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = max(1.0, lastScale * value.magnification)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.0 {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1.0 else { return }
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale > 1.0 {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
            .onTapGesture(count: 1) {
                onSingleTap?()
            }
    }
}

enum PhotoAttachmentUploader {
    static let maxBytes = 25 * 1024 * 1024

    @MainActor
    static func add(
        _ data: Data,
        session: ScanSessionResponse,
        roomId: String?,
        caption: String,
        client: ScanServiceClient
    ) async throws -> FloorPlan {
        if data.count > maxBytes {
            throw PlainError(message: AppError.Site.photoTooLarge.defaultMessage)
        }
        let upload = try await client.uploadPhoto(
            sessionId: session.id,
            accessToken: session.accessToken,
            imageData: data,
            filename: roomId.map { "room-\($0).jpg" } ?? "unit.jpg",
            mimeType: "image/jpeg"
        )
        return try await client.addPhoto(
            sessionId: session.id,
            accessToken: session.accessToken,
            url: upload.url,
            caption: caption,
            roomId: roomId
        )
    }
}

private struct PhotoSourcePicker: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: @MainActor (Result<Data, Error>) -> Void

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showCameraDenied = false
    @State private var libraryItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Add a photo", isPresented: $isPresented, titleVisibility: .visible) {
                if CameraAccess.canTakePhoto {
                    Button("Take Photo") {
                        if CameraAccess.isDenied {
                            showCameraDenied = true
                        } else {
                            showCamera = true
                        }
                    }
                    .accessibilityIdentifier("photoSource.takePhoto")
                }
                Button("Choose from Library") {
                    showLibrary = true
                }
                .accessibilityIdentifier("photoSource.chooseFromLibrary")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("photoSource.cancel")
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView(
                    onImageCaptured: { image in
                        let data = image.jpegData(compressionQuality: 0.8)
                        Task { @MainActor in
                            if let data {
                                onPicked(.success(data))
                            } else {
                                onPicked(.failure(PlainError(message: "Couldn't read the photo from the camera.")))
                            }
                        }
                    },
                    onDismiss: { showCamera = false }
                )
            }
            .photosPicker(isPresented: $showLibrary, selection: $libraryItems, maxSelectionCount: 1, matching: .images)
            .cameraDeniedAlert(isPresented: $showCameraDenied, onChooseFromLibrary: { showLibrary = true })
            .onChange(of: libraryItems) { _, items in
                guard let item = items.first else { return }
                libraryItems = []
                Task { @MainActor in
                    do {
                        guard let raw = try await item.loadTransferable(type: Data.self),
                              let data = PhotoUploadImage.jpegData(from: raw) else {
                            throw PlainError(message: "Couldn't read the selected photo.")
                        }
                        onPicked(.success(data))
                    } catch {
                        onPicked(.failure(error))
                    }
                }
            }
    }
}

extension View {
    func photoSourcePicker(isPresented: Binding<Bool>, onPicked: @escaping @MainActor (Result<Data, Error>) -> Void) -> some View {
        modifier(PhotoSourcePicker(isPresented: isPresented, onPicked: onPicked))
    }
}

struct AttachmentPhotoViewer: View {
    let session: ScanSessionResponse
    let photo: FloorPlan.Photo
    var onChanged: ((FloorPlan) -> Void)? = nil
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadError: AppError?
    @State private var isWorking = false
    @State private var showDeleteConfirmation = false
    @State private var showReplaceSource = false
    @State private var actionError: AppError?

    private let client = ScanServiceClient()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .photoSourcePicker(isPresented: $showReplaceSource) { result in
            switch result {
            case .success(let data):
                Task { await replacePhoto(with: data) }
            case .failure(let error):
                actionError = AppError(site: .photoUpload, underlying: error)
            }
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
    private var content: some View {
        if let image {
            ZoomableImage(image: image)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .accessibilityIdentifier("photoViewer.image")
        } else if isLoading {
            ProgressView().tint(.white)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Couldn't load this photo.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                if let loadError {
                    ErrorCodeView(error: loadError)
                        .frame(maxWidth: 320)
                }
                Button("Try again") {
                    Task { await loadImage() }
                }
                .accessibilityIdentifier("photoViewer.retry")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 20)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let actionError {
                ErrorCodeView(error: actionError)
                    .frame(maxWidth: 320)
            }

            HStack(spacing: 10) {
                if let image {
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Photo", image: Image(uiImage: image))
                    ) {
                        footerLabel("Save", systemImage: "square.and.arrow.down", color: .white)
                    }
                    .accessibilityIdentifier("photoViewer.save")
                }

                if onChanged != nil {
                    Button {
                        actionError = nil
                        showReplaceSource = true
                    } label: {
                        footerLabel("Replace", systemImage: "arrow.triangle.2.circlepath", color: .white)
                    }
                    .accessibilityIdentifier("photoViewer.replace")
                    .buttonStyle(.plain)
                    .disabled(isWorking)

                    Button {
                        actionError = nil
                        showDeleteConfirmation = true
                    } label: {
                        footerLabel("Delete", systemImage: "trash", color: Color(red: 1.0, green: 0.42, blue: 0.39))
                    }
                    .accessibilityIdentifier("photoViewer.delete")
                    .accessibilityLabel("Delete photo")
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }

            if isWorking {
                ProgressView().tint(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }

    private func footerLabel(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    @MainActor
    private func loadImage() async {
        if let cached = PhotoImageCache.shared.image(for: photo.url) {
            image = cached
            return
        }
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let data = try await client.fetchPhotoData(url: photo.url, accessToken: session.accessToken)
            guard let decoded = UIImage(data: data) else {
                throw PlainError(message: "The photo came back from the Scan Service but could not be decoded.")
            }
            PhotoImageCache.shared.store(decoded, for: photo.url)
            image = decoded
        } catch is CancellationError {
        } catch {
            loadError = AppError(site: .photoLoad, underlying: error)
        }
    }

    @MainActor
    private func deletePhoto() async {
        guard !isWorking, let onChanged else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await client.deletePhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                photoId: photo.photoId
            )
            PhotoImageCache.shared.remove(for: photo.url)
            VuuroToast.shared.show(vuuroLocalized("Photo removed"))
            onChanged(updated)
            onClose()
        } catch is CancellationError {
        } catch {
            actionError = AppError(site: .photoDelete, underlying: error)
        }
    }

    @MainActor
    private func replacePhoto(with data: Data) async {
        guard !isWorking, let onChanged else { return }
        isWorking = true
        defer { isWorking = false }
        let added: FloorPlan
        do {
            added = try await PhotoAttachmentUploader.add(
                data,
                session: session,
                roomId: photo.roomId,
                caption: photo.caption,
                client: client
            )
        } catch is CancellationError {
            return
        } catch {
            actionError = AppError(site: .photoUpload, underlying: error)
            return
        }
        do {
            let updated = try await client.deletePhoto(
                sessionId: session.id,
                accessToken: session.accessToken,
                photoId: photo.photoId
            )
            PhotoImageCache.shared.remove(for: photo.url)
            VuuroToast.shared.show(vuuroLocalized("Photo replaced"))
            onChanged(updated)
            onClose()
        } catch {
            onChanged(added)
            actionError = AppError(
                site: .photoDelete,
                underlying: PlainError(message: vuuroLocalized("The new photo was added, but the old one couldn't be removed. Delete the old photo by hand.") + " " + error.localizedDescription)
            )
        }
    }
}

struct NoteEditSheet: View {
    let session: ScanSessionResponse
    let note: FloorPlan.Note
    let onSaved: (FloorPlan) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var tags: Set<InspectionTag>
    @State private var isSaving = false
    @State private var saveError: AppError?
    @FocusState private var focused: Bool

    private let client = ScanServiceClient()
    private let originalTags: Set<InspectionTag>

    init(session: ScanSessionResponse, note: FloorPlan.Note, onSaved: @escaping (FloorPlan) -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.note = note
        self.onSaved = onSaved
        self.onCancel = onCancel
        let existing = Set((note.tags ?? []).compactMap { InspectionTag(rawValue: $0) })
        self.originalTags = existing
        _text = State(initialValue: note.text)
        _tags = State(initialValue: existing)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && !isSaving && (trimmed != note.text || tags != originalTags)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .accessibilityIdentifier("noteEdit.text")
                    .focused($focused)
                    .font(.system(size: 15))
                    .frame(minHeight: 140)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(VuuroColor.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(VuuroColor.borderMed, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                InspectionTagPicker(selected: $tags)
                if let saveError {
                    ErrorCodeView(error: saveError)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(VuuroColor.bgApp)
            .navigationTitle("Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("noteEdit.cancel")
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .accessibilityIdentifier("noteEdit.save")
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let updated = try await client.updateNote(
                sessionId: session.id,
                accessToken: session.accessToken,
                noteId: note.noteId,
                text: trimmed,
                tags: tags == originalTags ? nil : Array(tags)
            )
            VuuroToast.shared.show(vuuroLocalized("Note saved"))
            onSaved(updated)
        } catch is CancellationError {
        } catch {
            saveError = AppError(site: .noteUpdate, underlying: error)
        }
    }
}
