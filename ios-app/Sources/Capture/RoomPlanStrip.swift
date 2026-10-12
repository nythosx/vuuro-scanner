import SwiftUI
import UIKit

struct RoomPlanStrip: View {
    let rooms: [FloorPlan.Room]
    let sessionId: String
    let accessToken: String
    let unit: MeasurementUnit
    let onOpen: (UIImage) -> Void

    @State private var thumbnails: [String: UIImage] = [:]
    @State private var failedIds: Set<String> = []
    @State private var visibleIndex = 0

    private let client = ScanServiceClient()
    private let thumbWidth: CGFloat = 104
    private let spacing: CGFloat = 10

    private var loadKey: String {
        rooms.map(\.roomId).joined(separator: "|") + unit.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rooms")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(VuuroColor.textSecondary)
            HStack(spacing: 6) {
                if rooms.count > 3 {
                    arrowButton("chevron.left", identifier: "result.roomStrip.previous") {
                        visibleIndex = max(0, visibleIndex - 2)
                    }
                    .disabled(visibleIndex == 0)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: spacing) {
                            ForEach(Array(rooms.enumerated()), id: \.element.roomId) { index, room in
                                thumbnail(room)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: visibleIndex) { _, newValue in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newValue, anchor: .leading)
                        }
                    }
                }
                if rooms.count > 3 {
                    arrowButton("chevron.right", identifier: "result.roomStrip.next") {
                        visibleIndex = min(rooms.count - 1, visibleIndex + 2)
                    }
                    .disabled(visibleIndex >= rooms.count - 1)
                }
            }
        }
        .task(id: loadKey) { await loadThumbnails() }
    }

    private func arrowButton(_ systemName: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(VuuroColor.textPrimary)
                .frame(width: 28, height: 28)
                .background(VuuroColor.bgInset, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func thumbnail(_ room: FloorPlan.Room) -> some View {
        Button {
            if let image = thumbnails[room.roomId] {
                onOpen(image)
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(VuuroColor.bgInset)
                    if let image = thumbnails[room.roomId] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else if failedIds.contains(room.roomId) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(VuuroColor.textTertiary)
                    } else {
                        ProgressView().tint(VuuroColor.accent)
                    }
                }
                .frame(width: thumbWidth, height: 78)
                Text(displayName(room))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.textPrimary)
                    .lineLimit(1)
                    .frame(width: thumbWidth)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.roomStrip.\(room.roomId)")
    }

    private func displayName(_ room: FloorPlan.Room) -> String {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty, confirmed != "other" {
            return RoomTypeClassifier.displayName(for: confirmed)
        }
        return room.label
    }

    @MainActor
    private func loadThumbnails() async {
        for room in rooms where thumbnails[room.roomId] == nil {
            if Task.isCancelled { return }
            do {
                let data = try await client.fetchFloorPlanImage(
                    sessionId: sessionId,
                    accessToken: accessToken,
                    unit: unit,
                    roomId: room.roomId
                )
                if let image = await ImageDecoding.decoded(data) {
                    thumbnails[room.roomId] = image
                } else {
                    failedIds.insert(room.roomId)
                }
            } catch is CancellationError {
                return
            } catch {
                failedIds.insert(room.roomId)
                DiagnosticsLog.shared.record("Room plan thumbnail failed for \(room.roomId): \(error.localizedDescription)", category: .error)
            }
        }
    }
}
