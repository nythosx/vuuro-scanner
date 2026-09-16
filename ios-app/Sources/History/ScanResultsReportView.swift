
import SwiftUI

struct ScanResultsReportView: View {
    let entry: ScanHistoryEntry

    @State private var floorPlan: FloorPlan?
    @State private var isLoading = true
    @State private var appError: AppError?
    @State private var floorPlanImage: UIImage?
    @State private var isFetchingImage = false
    @State private var imageLoadFailed = false
    @State private var floorPlanImageURL: URL?
    @State private var floorPlanPDFURL: URL?
    @State private var isFetchingPDF = false
    @State private var fullScreenPreviewURL: URL?
    @State private var showFullScreenPreview = false
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private var session: ScanSessionResponse { entry.asResumableSession() }

    private let client = ScanServiceClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VuuroMetrics.contentSpacing) {
                header

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if let floorPlan {
                    if floorPlan.rooms.isEmpty {
                        Text("No rooms captured for this scan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .vuuroCard()
                    } else {
                        ForEach(floorPlan.rooms, id: \.roomId) { room in
                            RoomResultCard(
                                room: room,
                                showsRibbon: false,
                                photos: floorPlan.photos.filter { $0.roomId == room.roomId },
                                notes: floorPlan.notes.filter { $0.roomId == room.roomId },
                                session: session
                            )
                        }
                    }

                    let unitPhotos = floorPlan.photos.filter { $0.roomId == nil }
                    let unitNotes = floorPlan.notes.filter { $0.roomId == nil }
                    if !unitPhotos.isEmpty || !unitNotes.isEmpty {
                        VStack(alignment: .leading, spacing: VuuroMetrics.contentSpacing) {
                            Text("Whole unit — notes & photos")
                                .font(VuuroFont.body(13, weight: .bold))
                                .foregroundStyle(VuuroColor.textSecondary)
                                .textCase(.uppercase)
                            RoomAttachmentsList(session: session, photos: unitPhotos, notes: unitNotes)
                        }
                        .padding()
                        .vuuroCard()
                    }
                }

                floorPlanSection

                NavigationLink("Access log") {
                    AccessLogView(sessionId: entry.sessionId, accessToken: entry.accessToken)
                }
                .font(VuuroFont.body(15, weight: .semibold))
                .foregroundStyle(VuuroColor.textPrimary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .vuuroCard()

                if let appError {
                    ErrorCodeView(error: appError)
                }
            }
            .padding()
        }
        .background(VuuroColor.surfaceMuted)
        .navigationTitle(entry.nickname?.isEmpty == false ? entry.nickname! : "\(entry.propertyId) — \(entry.unitId)")
        .fullScreenCover(isPresented: $showFullScreenPreview) {
            if let fullScreenPreviewURL {
                QuickLookPreview(url: fullScreenPreviewURL)
                    .ignoresSafeArea()
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.purpose.displayName)
                    .font(VuuroFont.body(12, weight: .bold))
                    .foregroundStyle(VuuroColor.primary)
                    .textCase(.uppercase)
                Spacer()
                VuuroBadge("Completed scan", systemImage: "checkmark.seal.fill", style: .good)
            }
            Text("\(entry.propertyId) — \(entry.unitId)")
                .font(VuuroFont.display(20))
                .foregroundStyle(VuuroColor.textPrimary)
            Text(entry.createdAt, format: Date.FormatStyle(date: .long, time: .shortened))
                .font(VuuroFont.body(13))
                .foregroundStyle(VuuroColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .vuuroCard()
    }

    @ViewBuilder
    private var floorPlanSection: some View {
        VStack(alignment: .leading, spacing: VuuroMetrics.contentSpacing) {
            Text("Floor plan")
                .font(VuuroFont.body(13, weight: .bold))
                .foregroundStyle(VuuroColor.textSecondary)
                .textCase(.uppercase)

            if isFetchingImage {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Rendering floor plan…")
                        .font(VuuroFont.body(12.5))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if let floorPlanImage {
                Image(uiImage: floorPlanImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: VuuroMetrics.cardRadius, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let floorPlanImageURL {
                            fullScreenPreviewURL = floorPlanImageURL
                            showFullScreenPreview = true
                        }
                    }
                Text("Tap to view full screen")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let floorPlanImageURL {
                    ShareLink(item: floorPlanImageURL) {
                        Label("Save image", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.vuuroSecondary)
                }
            } else if imageLoadFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't render the floor plan preview.")
                        .font(VuuroFont.body(13, weight: .semibold))
                        .foregroundStyle(VuuroColor.warningText)
                    Button {
                        Task { await loadImage() }
                    } label: {
                        Text("Try again")
                    }
                    .buttonStyle(.vuuroSecondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        if floorPlanPDFURL == nil { await loadPDF() }
                        if let floorPlanPDFURL {
                            fullScreenPreviewURL = floorPlanPDFURL
                            showFullScreenPreview = true
                        }
                    }
                } label: {
                    if isFetchingPDF {
                        ProgressView()
                    } else {
                        Text("View PDF")
                    }
                }
                .buttonStyle(.vuuroSecondary)
                .disabled(isFetchingPDF)

                if let floorPlanPDFURL {
                    ShareLink(item: floorPlanPDFURL) {
                        Label("Save PDF", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.vuuroSecondary)
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
        let sessionFetch = Task { @MainActor in
            do {
                floorPlan = try await client.fetchSession(sessionId: entry.sessionId, accessToken: entry.accessToken)
                appError = nil
            } catch {
                appError = AppError(site: .historySessionFetch, underlying: error)
            }
        }
        let imageFetch = Task { @MainActor in
            await loadImage()
        }
        await sessionFetch.value
        await imageFetch.value
    }

    @MainActor
    private func loadImage() async {
        imageLoadFailed = false
        let alreadyCached = FloorPlanImageCache.shared.cachedData(sessionId: entry.sessionId, unit: exportUnit) != nil
        isFetchingImage = !alreadyCached
        defer { isFetchingImage = false }
        guard let data = await FloorPlanImageCache.shared.prefetch(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, client: client).value else {
            appError = AppError(site: .resultImageLoad, underlying: FloorPlanImageCache.shared.lastError(sessionId: entry.sessionId, unit: exportUnit))
            imageLoadFailed = true
            return
        }
        applyFloorPlanImageData(data)
    }

    @MainActor
    private func applyFloorPlanImageData(_ data: Data) {
        guard let image = UIImage(data: data) else {
            appError = AppError(site: .resultImageDecode, underlying: nil)
            imageLoadFailed = true
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).png")
        do {
            try data.write(to: url)
        } catch {
            appError = AppError(site: .resultImageLoad, underlying: error)
            imageLoadFailed = true
            return
        }
        floorPlanImage = image
        floorPlanImageURL = url
    }

    @MainActor
    private func loadPDF() async {
        isFetchingPDF = true
        defer { isFetchingPDF = false }
        do {
            let data = try await client.fetchFloorPlanPDF(sessionId: entry.sessionId, accessToken: entry.accessToken, unit: exportUnit, label: entry.nickname)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("floorplan-\(entry.sessionId).pdf")
            try data.write(to: url)
            floorPlanPDFURL = url
            appError = nil
        } catch {
            appError = AppError(site: .resultPDFLoad, underlying: error)
        }
    }
}
