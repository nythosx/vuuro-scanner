import SwiftUI
import UIKit

struct PlanBlock: Identifiable, Equatable {
    let id: String
    let floor: String?
    let group: String
    let title: String
    let roomCount: Int

    static let noGroup = "none"

    static func blocks(for rooms: [FloorPlan.Room]) -> [PlanBlock] {
        var order: [String] = []
        var floors: [String: String?] = [:]
        var floorKeys: [String: String] = [:]
        var groups: [String: String] = [:]
        var counts: [String: Int] = [:]
        for room in rooms {
            let trimmed = (room.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let floorKey = trimmed.lowercased()
            let group = room.joinedToGroupId ?? room.captureGroupId ?? noGroup
            let key = floorKey + "|" + group
            if counts[key] == nil {
                order.append(key)
                floors[key] = trimmed.isEmpty ? nil : trimmed
                floorKeys[key] = floorKey
                groups[key] = group
            }
            counts[key, default: 0] += 1
        }
        var perFloor: [String: Int] = [:]
        for key in order {
            perFloor[floorKeys[key] ?? "", default: 0] += 1
        }
        var scanNumber: [String: Int] = [:]
        return order.map { key in
            let floorKey = floorKeys[key] ?? ""
            let floor = floors[key] ?? nil
            let group = groups[key] ?? noGroup
            var title = floor ?? vuuroLocalized("Floor not set")
            if (perFloor[floorKey] ?? 0) > 1 {
                if group == noGroup {
                    title += " · " + vuuroLocalized("Rooms scanned one by one")
                } else {
                    let number = (scanNumber[floorKey] ?? 0) + 1
                    scanNumber[floorKey] = number
                    title += " · " + String(format: vuuroLocalized("Scan %lld"), number)
                }
            }
            return PlanBlock(id: key, floor: floor, group: group, title: title, roomCount: counts[key] ?? 0)
        }
    }
}

struct PlanBlocksCarousel: View {
    let blocks: [PlanBlock]
    let sessionId: String
    let accessToken: String
    let unit: MeasurementUnit
    var refreshKey: String = ""
    let identifierPrefix: String
    let onOpen: (UIImage) -> Void

    @State private var images: [String: UIImage] = [:]
    @State private var failedIds: Set<String> = []
    @State private var index = 0
    @State private var autoAdvancing = false
    @State private var userTookOver = false

    private let client = ScanServiceClient()
    private static let autoAdvanceNanoseconds: UInt64 = 5_000_000_000

    private var loadKey: String {
        blocks.map { "\($0.id):\($0.roomCount)" }.joined(separator: ",") + unit.rawValue + refreshKey
    }

    private var current: PlanBlock? {
        blocks.indices.contains(index) ? blocks[index] : blocks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: current?.title ?? "")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(VuuroColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "\(index + 1) / \(blocks.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.textSecondary)
            }

            ZStack {
                TabView(selection: $index) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { offset, block in
                        page(block)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack {
                    arrowButton(systemName: "chevron.left", label: "Previous plan") { step(-1) }
                        .accessibilityIdentifier("\(identifierPrefix).planCarousel.previous")
                    Spacer()
                    arrowButton(systemName: "chevron.right", label: "Next plan") { step(1) }
                        .accessibilityIdentifier("\(identifierPrefix).planCarousel.next")
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 220)
            .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let current {
                Text(String(format: vuuroLocalized("%lld rooms in this plan"), current.roomCount))
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
            }
        }
        .onChange(of: index) { _, _ in
            if autoAdvancing {
                autoAdvancing = false
            } else {
                userTookOver = true
            }
        }
        .task(id: loadKey) {
            images = [:]
            failedIds = []
            if index >= blocks.count {
                index = 0
            }
            await loadImages()
        }
        .task(id: blocks.count) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoAdvanceNanoseconds)
                if Task.isCancelled || userTookOver || blocks.count < 2 {
                    return
                }
                autoAdvancing = true
                withAnimation(.easeInOut(duration: 0.35)) {
                    index = (index + 1) % blocks.count
                }
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).planCarousel")
    }

    private func page(_ block: PlanBlock) -> some View {
        Button {
            if let image = images[block.id] {
                userTookOver = true
                onOpen(image)
            } else if failedIds.contains(block.id) {
                failedIds.remove(block.id)
                Task { await loadImages() }
            }
        } label: {
            ZStack {
                if let image = images[block.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(.vertical, 12)
                        .padding(.horizontal, 40)
                } else if failedIds.contains(block.id) {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18))
                            .foregroundStyle(VuuroColor.textTertiary)
                        Text("Tap to retry")
                            .font(.system(size: 11))
                            .foregroundStyle(VuuroColor.textTertiary)
                    }
                } else {
                    ProgressView().tint(VuuroColor.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: block.title))
    }

    private func arrowButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(VuuroColor.textPrimary)
                .frame(width: 30, height: 30)
                .background(VuuroColor.bgCard.opacity(0.92), in: Circle())
                .shadow(color: VuuroMetrics.cardShadowColor, radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private func step(_ delta: Int) {
        guard !blocks.isEmpty else { return }
        userTookOver = true
        withAnimation(.easeInOut(duration: 0.3)) {
            index = (index + delta + blocks.count) % blocks.count
        }
    }

    @MainActor
    private func loadImages() async {
        for block in blocks where images[block.id] == nil && !failedIds.contains(block.id) {
            if Task.isCancelled { return }
            do {
                let data = try await client.fetchFloorPlanImage(
                    sessionId: sessionId,
                    accessToken: accessToken,
                    unit: unit,
                    floor: block.floor ?? "",
                    group: block.group
                )
                if let image = UIImage(data: data) {
                    images[block.id] = image
                } else {
                    failedIds.insert(block.id)
                }
            } catch is CancellationError {
                return
            } catch {
                failedIds.insert(block.id)
                DiagnosticsLog.shared.record("Plan carousel image failed for \(block.id): \(error.localizedDescription)", category: .error)
            }
        }
    }
}
