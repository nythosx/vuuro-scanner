import SwiftUI
import UIKit

struct RoomGridSection: View {
    let rooms: [FloorPlan.Room]
    let sessionId: String
    let accessToken: String
    let unit: MeasurementUnit
    var refreshKey: String = ""
    let identifierPrefix: String
    let imageActionLabel: LocalizedStringKey
    let imageActionIdentifier: String
    let isFetchingPDF: Bool
    let onOpen: (UIImage) -> Void
    let onImageAction: () -> Void
    let onViewPDF: () -> Void

    @State private var thumbnails: [String: UIImage] = [:]
    @State private var failedIds: Set<String> = []

    private let client = ScanServiceClient()

    static func shows(for rooms: [FloorPlan.Room]) -> Bool {
        rooms.count > 1 && rooms.filter { $0.structureOriginM != nil }.count < 2
    }

    private var loadKey: String {
        let roomsKey = rooms.map { room in
            [room.roomId, room.label, room.roomType?.confirmed ?? "", room.floor ?? ""].joined(separator: ":")
        }
        return roomsKey.joined(separator: "|") + unit.rawValue + refreshKey
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rooms")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)
                Spacer(minLength: 0)
                VuuroBadge("\(rooms.count) room\(rooms.count == 1 ? "" : "s")", style: .info)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(rooms.enumerated()), id: \.element.roomId) { index, room in
                    roomCard(room: room, index: index + 1)
                }
            }

            HStack(spacing: 8) {
                Button {
                    onImageAction()
                } label: {
                    Text(imageActionLabel)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier(imageActionIdentifier)
                .buttonStyle(.vuuroOutlineSmall)

                Button {
                    onViewPDF()
                } label: {
                    if isFetchingPDF {
                        ProgressView().tint(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("View PDF")
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix).viewPDF")
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
        .task(id: loadKey) {
            thumbnails = [:]
            failedIds = []
            await loadThumbnails()
        }
    }

    private func roomCard(room: FloorPlan.Room, index: Int) -> some View {
        Button {
            if let image = thumbnails[room.roomId] {
                onOpen(image)
            } else if failedIds.contains(room.roomId) {
                failedIds.remove(room.roomId)
                Task { await loadThumbnails() }
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(VuuroColor.bgInset)

                    if let image = thumbnails[room.roomId] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if failedIds.contains(room.roomId) {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18))
                                .foregroundStyle(VuuroColor.textTertiary)
                            Text("Tap to retry")
                                .font(.system(size: 10))
                                .foregroundStyle(VuuroColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().tint(VuuroColor.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Text("\(index)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(VuuroColor.accent, in: Circle())
                        .padding(8)
                }
                .frame(height: 110)

                VStack(spacing: 2) {
                    Text(displayName(room))
                        .font(.system(size: 13, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(VuuroColor.textPrimary)
                        .lineLimit(1)
                    if let floor = room.floor, !floor.isEmpty {
                        Text(floor)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(VuuroColor.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(VuuroColor.bgInset.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix).roomGrid.\(room.roomId)")
    }

    private func displayName(_ room: FloorPlan.Room) -> String {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty, confirmed != "other" {
            return RoomTypeClassifier.displayName(for: confirmed)
        }
        return room.label
    }

    @MainActor
    private func loadThumbnails() async {
        for room in rooms where thumbnails[room.roomId] == nil && !failedIds.contains(room.roomId) {
            if Task.isCancelled { return }
            do {
                let data = try await client.fetchFloorPlanImage(
                    sessionId: sessionId,
                    accessToken: accessToken,
                    unit: unit,
                    roomId: room.roomId
                )
                if let image = UIImage(data: data) {
                    thumbnails[room.roomId] = image
                } else {
                    failedIds.insert(room.roomId)
                }
            } catch is CancellationError {
                return
            } catch {
                failedIds.insert(room.roomId)
                DiagnosticsLog.shared.record("Room grid thumbnail failed for \(room.roomId): \(error.localizedDescription)", category: .error)
            }
        }
    }
}
