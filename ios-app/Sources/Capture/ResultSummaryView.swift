import QuickLook
import SwiftUI
import UIKit

struct ResultSummaryView: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let onDone: () -> Void

    @State private var floorPlanImage: UIImage?
    @State private var isLoadingImage = false
    @State private var imageFailed = false
    @State private var shareImageURL: URL?
    @State private var pdfURL: URL?
    @State private var showImagePreview = false
    @State private var showPDFPreview = false
    @State private var isFetchingPDF = false
    @State private var showForgetConfirmation = false
    @State private var appError: AppError?
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue

    private var exportUnit: MeasurementUnit {
        MeasurementUnit(rawValue: exportUnitRaw) ?? .metric
    }

    private let client = ScanServiceClient()

    private var totalAreaM2: Double {
        floorPlan.rooms.reduce(0.0) { $0 + $1.floorAreaM2 }
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Scan result",
                leading: { VuuroNavSpacer() },
                trailing: {
                    Button("Done", action: onDone)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VuuroColor.accent)
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summaryHero
                    floorPlanCard
                    ForEach(floorPlan.rooms, id: \.roomId) { room in
                        RoomResultCard(
                            room: room,
                            showsRibbon: false,
                            isFused: floorPlan.rooms.count > 1,
                            photos: floorPlan.photos.filter { $0.roomId == room.roomId },
                            notes: floorPlan.notes.filter { $0.roomId == room.roomId },
                            session: session
                        )
                    }

                    if !floorPlan.photos.filter({ $0.roomId == nil }).isEmpty
                        || !floorPlan.notes.filter({ $0.roomId == nil }).isEmpty {
                        unitAttachmentsCard
                    }

                    accessLogLink
                    actionButtons

                    if let appError {
                        ErrorCodeView(error: appError)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer().frame(height: 24)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
        .task { await loadImage() }
        .fullScreenCover(isPresented: $showImagePreview) {
            if let shareImageURL,
               let imageData = try? Data(contentsOf: shareImageURL),
               let image = UIImage(data: imageData) {
                ImagePreviewView(image: image) {
                    showImagePreview = false
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Couldn't load the image.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("Close") {
                            showImagePreview = false
                        }
                        .buttonStyle(.vuuroPrimary)
                        .frame(maxWidth: 200)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showPDFPreview) {
            if let pdfURL {
                QuickLookPreview(url: pdfURL) {
                    showPDFPreview = false
                }
                .ignoresSafeArea()
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("Couldn't load the PDF.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("Close") {
                            showPDFPreview = false
                        }
                        .buttonStyle(.vuuroPrimary)
                        .frame(maxWidth: 200)
                    }
                }
            }
        }
        .alert("Forget this scan?", isPresented: $showForgetConfirmation) {
            Button("Forget", role: .destructive) {
                ScanHistoryStore.shared.remove(sessionId: session.id)
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local record on this device. Server data isn't affected.")
        }
    }

    private var summaryHero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(VuuroColor.lime.opacity(0.20))
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(VuuroColor.goodText)
            }
            .frame(width: 64, height: 64)

            Text(floorPlan.rooms.count == 1 ? "Room captured" : "Unit captured")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(VuuroColor.textPrimary)

            Text(summarySubtitle)
                .font(.system(size: 15))
                .foregroundStyle(VuuroColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private var summarySubtitle: String {
        let count = floorPlan.rooms.count
        let roomsText = "\(count) room\(count == 1 ? "" : "s")"
        let areaText = String(format: "%.1f m² total", totalAreaM2)
        return "\(roomsText) · \(areaText)"
    }

    private var floorPlanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Floor plan")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)
                Spacer()
                VuuroBadge("\(floorPlan.rooms.count) room\(floorPlan.rooms.count == 1 ? "" : "s")", style: .info)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VuuroColor.bgInset)

                if isLoadingImage {
                    ProgressView().tint(VuuroColor.accent)
                } else if let floorPlanImage {
                    Image(uiImage: floorPlanImage)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else if imageFailed {
                    schematicPlaceholder
                } else {
                    ProgressView().tint(VuuroColor.accent)
                }
            }
            .frame(height: 220)
            .contentShape(Rectangle())
            .onTapGesture {
                guard floorPlanImage != nil else { return }
                Task { await fetchAndPreviewImage() }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await fetchAndPreviewImage() }
                } label: {
                    Text("View image")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vuuroOutlineSmall)

                Button {
                    Task { await fetchAndPreviewPDF() }
                } label: {
                    if isFetchingPDF {
                        ProgressView().tint(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("View PDF")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.vuuroOutlineSmall)
                .disabled(isFetchingPDF)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var schematicPlaceholder: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(floorPlan.rooms, id: \.roomId) { room in
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(VuuroColor.accent.opacity(0.06))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(VuuroColor.accent.opacity(0.55), lineWidth: 2)
                    Text(room.label)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(VuuroColor.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
                .frame(height: 68)
            }
        }
        .padding(12)
    }

    private var unitAttachmentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whole unit")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(VuuroColor.textSecondary)
            RoomAttachmentsList(
                session: session,
                photos: floorPlan.photos.filter { $0.roomId == nil },
                notes: floorPlan.notes.filter { $0.roomId == nil }
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

    private var accessLogLink: some View {
        NavigationLink {
            AccessLogView(sessionId: session.id, accessToken: session.accessToken)
        } label: {
            HStack {
                Text("Access log")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(VuuroColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VuuroColor.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
            .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button("Save & return home") {
                VuuroToast.shared.show("Scan saved to history")
                onDone()
            }
            .buttonStyle(.vuuroPrimary)

            Button("Delete this scan", role: .destructive) {
                showForgetConfirmation = true
            }
            .buttonStyle(.vuuroGhostSmall)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @MainActor
    private func loadImage() async {
        guard floorPlanImage == nil, !isLoadingImage else { return }
        isLoadingImage = true
        defer { isLoadingImage = false }

        if let cached = FloorPlanImageCache.shared.cachedData(sessionId: session.id, unit: exportUnit),
           let decoded = UIImage(data: cached) {
            floorPlanImage = decoded
            return
        }

        let data = await FloorPlanImageCache.shared.prefetch(
            sessionId: session.id,
            accessToken: session.accessToken,
            unit: exportUnit,
            client: client
        ).value

        guard let data, let image = UIImage(data: data) else {
            imageFailed = true
            return
        }
        floorPlanImage = image
    }

    @MainActor
    private func fetchAndPreviewImage() async {
        if let cachedURL = cachedFileURL(suffix: "png"), FileManager.default.fileExists(atPath: cachedURL.path) {
            shareImageURL = cachedURL
            showImagePreview = true
            return
        }
        do {
            let data = try await client.fetchFloorPlanImage(
                sessionId: session.id,
                accessToken: session.accessToken,
                unit: exportUnit
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floorplan-\(session.id).png")
            try data.write(to: url, options: .atomic)
            shareImageURL = url
            showImagePreview = true
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .historyImageDownload, underlying: error)
        }
    }

    @MainActor
    private func fetchAndPreviewPDF() async {
        guard !isFetchingPDF else { return }
        isFetchingPDF = true
        defer { isFetchingPDF = false }

        if let existing = pdfURL, FileManager.default.fileExists(atPath: existing.path) {
            showPDFPreview = true
            return
        }

        do {
            let data = try await client.fetchFloorPlanPDF(
                sessionId: session.id,
                accessToken: session.accessToken,
                unit: exportUnit
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("floorplan-\(session.id).pdf")
            try data.write(to: url, options: .atomic)
            pdfURL = url
            showPDFPreview = true
        } catch is CancellationError {
        } catch {
            appError = AppError(site: .resultPDFLoad, underlying: error)
        }
    }

    private func cachedFileURL(suffix: String) -> URL? {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floorplan-\(session.id).\(suffix)")
    }
}