import SwiftUI

struct RoomSplitSheet: View {
    let session: ScanSessionResponse
    let room: FloorPlan.Room
    let onSaved: (FloorPlan, ScanServiceClient.RoomSplitMode) -> Void
    let onCancel: () -> Void

    @State private var start: CGPoint
    @State private var end: CGPoint
    @State private var keepPoint: CGPoint?
    @State private var mode: ScanServiceClient.RoomSplitMode = .split
    @State private var isSaving = false
    @State private var error: AppError?

    private let client = ScanServiceClient()
    private let outline: [CGPoint]
    private let dominantAngle: Double

    init(session: ScanSessionResponse, room: FloorPlan.Room, onSaved: @escaping (FloorPlan, ScanServiceClient.RoomSplitMode) -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.room = room
        self.onSaved = onSaved
        self.onCancel = onCancel
        let points = room.outlineM.compactMap { pair -> CGPoint? in
            guard pair.count >= 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
        outline = points
        dominantAngle = RoomSplitGeometry.dominantAngle(points)
        let line = RoomSplitGeometry.initialLine(points)
        _start = State(initialValue: line.0)
        _end = State(initialValue: line.1)
        if case .success(let initialParts) = RoomSplitGeometry.cut(outline: points, openEdges: Set(room.openEdges), from: line.0, to: line.1) {
            let larger = initialParts[0].areaM2 >= initialParts[1].areaM2 ? initialParts[0] : initialParts[1]
            _keepPoint = State(initialValue: RoomSplitGeometry.interiorPoint(larger.points))
        }
    }

    private func objectsIn(_ part: RoomSplitGeometry.Part) -> Int {
        room.objects.filter { object in
            !object.excluded && object.positionM.count >= 2
                && RoomSplitGeometry.contains(part.points, CGPoint(x: object.positionM[0], y: object.positionM[1]))
        }.count
    }

    private var roomName: String {
        room.roomType?.confirmed.map { RoomTypeClassifier.displayName(for: $0) } ?? room.label
    }

    private var result: Result<[RoomSplitGeometry.Part], RoomSplitGeometry.CutError> {
        RoomSplitGeometry.cut(outline: outline, openEdges: Set(room.openEdges), from: start, to: end)
    }

    private var parts: [RoomSplitGeometry.Part]? {
        if case .success(let parts) = result { return parts }
        return nil
    }

    private func keptIndex(_ parts: [RoomSplitGeometry.Part]) -> Int {
        if let keepPoint, let index = parts.firstIndex(where: { RoomSplitGeometry.contains($0.points, keepPoint) }) {
            return index
        }
        return parts[0].areaM2 >= parts[1].areaM2 ? 0 : 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(format: vuuroLocalized("Drag the two handles so the line runs across the opening where %@ should end. Tap the part that keeps the name."), roomName))
                        .font(.system(size: 13))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    canvas
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Picker("", selection: $mode) {
                        Text("Split into two rooms").tag(ScanServiceClient.RoomSplitMode.split)
                        Text("Trim off the other part").tag(ScanServiceClient.RoomSplitMode.trim)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("roomSplit.mode")

                    statusText

                    if let error {
                        ErrorCodeView(error: error)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Split or trim room")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .accessibilityIdentifier("roomSplit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(mode == .split ? LocalizedStringKey("Split") : LocalizedStringKey("Trim")) {
                            Task { await save() }
                        }
                        .fontWeight(.semibold)
                        .tint(mode == .trim ? VuuroColor.danger : VuuroColor.accent)
                        .disabled(parts == nil)
                        .accessibilityIdentifier("roomSplit.apply")
                    }
                }
            }
        }
    }

    private func statusMessage(kept: RoomSplitGeometry.Part, other: RoomSplitGeometry.Part) -> String {
        if mode == .split {
            return String(format: vuuroLocalized("%@ keeps %.1f m². The other %.1f m² becomes a new room."), roomName, kept.areaM2, other.areaM2)
        }
        var message = String(format: vuuroLocalized("%@ keeps %.1f m². The other %.1f m² is removed from the plan."), roomName, kept.areaM2, other.areaM2)
        let removedItems = objectsIn(other)
        if removedItems > 0 {
            message += " " + String(format: vuuroLocalized("%ld detected item(s) there are removed too. Notes and photos stay with %@."), removedItems, roomName)
        }
        return message
    }

    @ViewBuilder
    private var statusText: some View {
        switch result {
        case .success(let parts):
            let keptAt = keptIndex(parts)
            let kept = parts[keptAt]
            let other = parts[1 - keptAt]
            Text(statusMessage(kept: kept, other: other))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VuuroColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let cutError):
            Text(cutError.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VuuroColor.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let mapping = Mapping(outline: outline, size: proxy.size)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, mapping: mapping)
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard let parts else { return }
                        let tapped = mapping.toMetres(value.location)
                        if parts.contains(where: { RoomSplitGeometry.contains($0.points, tapped) }) {
                            keepPoint = tapped
                        }
                    }
                )

                handle(at: mapping.toView(start), identifier: "roomSplit.handleStart", label: vuuroLocalized("Start of the cut line")) { location in
                    start = RoomSplitGeometry.snapped(mapping.toMetres(location), around: end, dominantAngle: dominantAngle)
                }
                handle(at: mapping.toView(end), identifier: "roomSplit.handleEnd", label: vuuroLocalized("End of the cut line")) { location in
                    end = RoomSplitGeometry.snapped(mapping.toMetres(location), around: start, dominantAngle: dominantAngle)
                }
            }
            .coordinateSpace(name: Self.canvasSpace)
        }
    }

    private static let canvasSpace = "roomSplitCanvas"

    private func handle(at point: CGPoint, identifier: String, label: String, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(VuuroColor.accent)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
                    .onChanged { value in onDrag(value.location) }
            )
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .position(point)
    }

    private func draw(in context: inout GraphicsContext, mapping: Mapping) {
        if let parts {
            let keptAt = keptIndex(parts)
            for (index, part) in parts.enumerated() {
                let isKept = index == keptAt
                let fill: Color = isKept ? VuuroColor.accent.opacity(0.22) : (mode == .trim ? VuuroColor.danger.opacity(0.14) : VuuroColor.textTertiary.opacity(0.18))
                context.fill(path(part.points, mapping: mapping), with: .color(fill))
                let center = mapping.toView(RoomSplitGeometry.interiorPoint(part.points))
                let title = isKept ? roomName : (mode == .trim ? vuuroLocalized("Removed") : vuuroLocalized("New room"))
                context.draw(
                    Text("\(title)\n\(String(format: "%.1f m²", part.areaM2))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isKept ? VuuroColor.textPrimary : VuuroColor.textSecondary),
                    at: center
                )
            }
        } else {
            context.fill(path(outline, mapping: mapping), with: .color(VuuroColor.bgCard))
        }

        let openEdges = Set(room.openEdges)
        for index in outline.indices {
            var edge = Path()
            edge.move(to: mapping.toView(outline[index]))
            edge.addLine(to: mapping.toView(outline[(index + 1) % outline.count]))
            if openEdges.contains(index) {
                context.stroke(edge, with: .color(VuuroColor.textTertiary), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                context.stroke(edge, with: .color(VuuroColor.textPrimary), style: StrokeStyle(lineWidth: 4, lineCap: .square))
            }
        }

        var cut = Path()
        cut.move(to: mapping.toView(start))
        cut.addLine(to: mapping.toView(end))
        context.stroke(
            cut,
            with: .color(parts == nil ? VuuroColor.danger : VuuroColor.accent),
            style: StrokeStyle(lineWidth: 2.5, dash: parts == nil ? [3, 4] : [8, 5])
        )
    }

    private func path(_ points: [CGPoint], mapping: Mapping) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: mapping.toView(first))
        for point in points.dropFirst() {
            path.addLine(to: mapping.toView(point))
        }
        path.closeSubpath()
        return path
    }

    @MainActor
    private func save() async {
        guard let parts, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        error = nil
        let keep = RoomSplitGeometry.interiorPoint(parts[keptIndex(parts)].points)
        do {
            let updated = try await client.splitRoom(
                sessionId: session.id,
                accessToken: session.accessToken,
                roomId: room.roomId,
                line: [[Double(start.x), Double(start.y)], [Double(end.x), Double(end.y)]],
                keepPoint: [Double(keep.x), Double(keep.y)],
                mode: mode
            )
            onSaved(updated, mode)
        } catch is CancellationError {
        } catch {
            self.error = AppError(site: .roomSplit, underlying: error)
        }
    }

    private struct Mapping {
        let scale: CGFloat
        let offset: CGPoint
        let minX: CGFloat
        let minY: CGFloat

        init(outline: [CGPoint], size: CGSize) {
            let margin: CGFloat = 1.2
            let minX = (outline.map(\.x).min() ?? 0) - margin
            let maxX = (outline.map(\.x).max() ?? 1) + margin
            let minY = (outline.map(\.y).min() ?? 0) - margin
            let maxY = (outline.map(\.y).max() ?? 1) + margin
            let scale = min(size.width / max(maxX - minX, 0.1), size.height / max(maxY - minY, 0.1))
            self.scale = scale
            self.minX = minX
            self.minY = minY
            offset = CGPoint(
                x: (size.width - (maxX - minX) * scale) / 2,
                y: (size.height - (maxY - minY) * scale) / 2
            )
        }

        func toView(_ point: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + (point.x - minX) * scale, y: offset.y + (point.y - minY) * scale)
        }

        func toMetres(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - offset.x) / scale + minX, y: (point.y - offset.y) / scale + minY)
        }
    }
}
