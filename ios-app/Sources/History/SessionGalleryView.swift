import SwiftUI

struct SessionGalleryView: View {
    let entry: ScanHistoryEntry
    var onEdit: ((ScanHistoryEntry, FloorPlan) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var floorPlan: FloorPlan?
    @State private var isLoading = true
    @State private var appError: AppError?
    @State private var floorPlanPreviewImage: UIImage?
    @State private var isLoadingFloorPlanPreview = false
    @State private var floorPlanPreviewFailed = false
    @State private var removingPhotoIds: Set<String> = []
    @State private var removingNoteIds: Set<String> = []
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private var session: ScanSessionResponse {
        entry.asResumableSession()
    }

    private let client = ScanServiceClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VuuroMetrics.contentSpacing) {
                floorPlanPreviewSection

                if !isLoading, let floorPlan, !floorPlan.rooms.isEmpty {
                    Text("Notes and photos below are per-room evidence — condition, damage, or anything worth flagging for whoever reviews this unit next. Note text and attached photos both print on the PDF export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if let floorPlan {
                    if floorPlan.rooms.isEmpty {
                        Text("No rooms captured yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(floorPlan.rooms, id: \.roomId) { room in
                            roomCard(room: room, floorPlan: floorPlan)
                        }
                    }
                }

                if let appError {
                    ErrorCodeView(error: appError)
                }
            }
            .padding()
        }
        .background(VuuroColor.surfaceMuted)
        .navigationTitle(entry.nickname?.isEmpty == false ? entry.nickname! : "\(entry.propertyId) — \(entry.unitId)")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
                .accessibilityIdentifier("gallery.done")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VuuroColor.accent)
            }
            if let onEdit, let floorPlan {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") {
                        dismiss()
                        onEdit(entry, floorPlan)
                    }
                    .accessibilityIdentifier("gallery.edit")
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var floorPlanPreviewSection: some View {
        Group {
            if let floorPlanPreviewImage {
                Image(uiImage: floorPlanPreviewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius, style: .continuous))
            } else if isLoadingFloorPlanPreview {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Rendering your floor plan…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if floorPlanPreviewFailed {
                Text("Couldn't render the floor plan preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func roomCard(room: FloorPlan.Room, floorPlan: FloorPlan) -> some View {
        let notes = floorPlan.notes.filter { $0.roomId == room.roomId }
        let photos = floorPlan.photos.filter { $0.roomId == room.roomId }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(room.label)
                    .font(VuuroFont.display(17))
                    .foregroundStyle(VuuroColor.textPrimary)
                Spacer()
                if let typeText = room.roomType?.confirmed.map({ RoomTypeClassifier.displayName(for: $0) }) {
                    VuuroBadge(typeText, style: .info)
                }
            }

            if notes.isEmpty && photos.isEmpty {
                Text("No notes or photos on this room yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(notes, id: \.noteId) { note in
                HStack(alignment: .top, spacing: 8) {
                    (Text("Note: ").font(.caption.weight(.semibold)) + Text(note.text).font(.caption))
                        .foregroundStyle(VuuroColor.textPrimary)
                    Spacer()
                    Button {
                        Task { await removeNote(noteId: note.noteId) }
                    } label: {
                        if removingNoteIds.contains(note.noteId) {
                            ProgressView()
                        } else {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("gallery.deleteNote.\(note.noteId)")
                    .buttonStyle(.plain)
                    .disabled(removingNoteIds.contains(note.noteId))
                }
            }

            ForEach(photos, id: \.photoId) { photo in
                HStack(alignment: .top, spacing: 12) {
                    AttachedPhotoThumbnail(session: session, url: photo.url)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo attached:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VuuroColor.textPrimary)
                        if !photo.caption.isEmpty {
                            Text(photo.caption).font(.caption2)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await removePhoto(photoId: photo.photoId) }
                    } label: {
                        if removingPhotoIds.contains(photo.photoId) {
                            ProgressView()
                        } else {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("gallery.deletePhoto.\(photo.photoId)")
                    .buttonStyle(.plain)
                    .disabled(removingPhotoIds.contains(photo.photoId))
                }
            }
        }
        .padding()
        .vuuroCard()
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            floorPlan = try await client.fetchSession(sessionId: entry.sessionId, accessToken: entry.accessToken)
            appError = nil
        } catch is CancellationError {
            DiagnosticsLog.shared.record(
                "Session gallery fetch cancelled for \(entry.sessionId)",
                category: .info
            )
        } catch {
            appError = AppError(site: .historySessionFetch, underlying: error)
        }
        await loadFloorPlanPreview()
    }

    @MainActor
    private func loadFloorPlanPreview() async {
        isLoadingFloorPlanPreview = true
        let data = await FloorPlanImageCache.shared.prefetch(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, client: client).value
        isLoadingFloorPlanPreview = false
        if let data, let image = UIImage(data: data) {
            floorPlanPreviewImage = image
        } else {
            floorPlanPreviewFailed = true
        }
    }

    @MainActor
    private func removePhoto(photoId: String) async {
        guard !removingPhotoIds.contains(photoId) else { return }
        removingPhotoIds.insert(photoId)
        defer { removingPhotoIds.remove(photoId) }
        do {
            floorPlan = try await client.deletePhoto(sessionId: entry.sessionId, accessToken: entry.accessToken, photoId: photoId)
            appError = nil
            VuuroToast.shared.show(String(localized: "Photo removed"))
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .photoDelete, underlying: error)
        }
    }

    @MainActor
    private func removeNote(noteId: String) async {
        guard !removingNoteIds.contains(noteId) else { return }
        removingNoteIds.insert(noteId)
        defer { removingNoteIds.remove(noteId) }
        do {
            floorPlan = try await client.deleteNote(sessionId: entry.sessionId, accessToken: entry.accessToken, noteId: noteId)
            appError = nil
            VuuroToast.shared.show(String(localized: "Note removed"))
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .noteDelete, underlying: error)
        }
    }
}