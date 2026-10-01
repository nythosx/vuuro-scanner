import SwiftUI

struct GroupPlacementView: View {
    let session: ScanSessionResponse
    let floorPlan: FloorPlan
    let groupId: String
    let floor: String?
    let onFinished: (FloorPlan) -> Void
    let onCancel: () -> Void

    @State private var rotationDeg: Double = 0.0
    @State private var offsetM: CGSize = .zero
    @State private var committedOffsetM: CGSize = .zero
    @State private var isSaving = false
    @State private var error: AppError?

    private let client = ScanServiceClient()

    private func sameFloor(_ roomFloor: String?) -> Bool {
        let a = (roomFloor ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let b = (floor ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return a == b
    }

    private var movingRooms: [FloorPlan.Room] {
        floorPlan.rooms.filter { room in
            (room.captureGroupId == groupId || room.joinedToGroupId == groupId)
                && sameFloor(room.floor)
        }
    }

    private var fixedRooms: [FloorPlan.Room] {
        floorPlan.rooms.filter { room in
            room.captureGroupId != groupId
                && room.joinedToGroupId != groupId
                && sameFloor(room.floor)
                && room.structureOriginM != nil
        }
    }

    private var fixedBlocks: [String: [FloorPlan.Room]] {
        Dictionary(grouping: fixedRooms, by: { $0.joinedToGroupId ?? $0.captureGroupId ?? "" })
    }

    private var targetGroupId: String? {
        let candidates = fixedBlocks.filter { !$0.key.isEmpty }
        let largest = candidates.max { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key > rhs.key : lhs.value.count < rhs.value.count
        }
        return largest?.key
    }

    private var pivot: CGPoint {
        var points: [CGPoint] = []
        for room in movingRooms {
            guard let origin = room.structureOriginM, origin.count >= 2 else { continue }
            for p in room.outlineM where p.count >= 2 {
                points.append(CGPoint(x: origin[0] + p[0], y: origin[1] + p[1]))
            }
        }
        return GroupPlacementMath.centroid(of: points)
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Place rooms",
                leading: { VuuroNavButton("Cancel", action: onCancel).accessibilityIdentifier("groupPlacement.cancel") },
                trailing: { VuuroNavSpacer() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(vuuroLocalized("Drag to move. Use the buttons to rotate precisely."))
                        .font(.system(size: 13))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .padding(.horizontal, 20)

                    GeometryReader { proxy in
                        let mapping = makeMapping(size: proxy.size)
                        Canvas { context, _ in
                            draw(in: &context, mapping: mapping)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    offsetM = CGSize(
                                        width: committedOffsetM.width + value.translation.width / mapping.scale,
                                        height: committedOffsetM.height + value.translation.height / mapping.scale
                                    )
                                }
                                .onEnded { _ in committedOffsetM = offsetM }
                        )
                    }
                    .frame(height: 340)
                    .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)

                    HStack(spacing: 8) {
                        rotateButton("-15°", -15)
                        rotateButton("-1°", -1)
                        rotateButton("+1°", 1)
                        rotateButton("+15°", 15)
                        rotateButton("90°", 90)
                    }
                    .padding(.horizontal, 20)

                    HStack(spacing: 8) {
                        nudgeButton("←", dx: -0.05, dy: 0)
                        nudgeButton("→", dx: 0.05, dy: 0)
                        nudgeButton("↑", dx: 0, dy: -0.05)
                        nudgeButton("↓", dx: 0, dy: 0.05)
                    }
                    .padding(.horizontal, 20)

                    if let error {
                        ErrorCodeView(error: error).padding(.horizontal, 20)
                    }

                    HStack(spacing: 10) {
                        Button(vuuroLocalized("Keep as separate section")) {
                            Task { await save(joinTo: nil) }
                        }
                        .accessibilityIdentifier("groupPlacement.detach")
                        .buttonStyle(.vuuroGhostSmall)
                        Button(vuuroLocalized("Save placement")) {
                            Task { await save(joinTo: targetGroupId) }
                        }
                        .accessibilityIdentifier("groupPlacement.save")
                        .buttonStyle(.vuuroPrimary)
                        .disabled(isSaving || targetGroupId == nil)
                    }
                    .padding(.horizontal, 20)

                    Spacer().frame(height: 24)
                }
            }
        }
        .background(VuuroColor.bgApp)
    }

    private struct Mapping {
        let scale: CGFloat
        let offset: CGPoint
        let minX: CGFloat
        let minY: CGFloat

        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + (p.x - minX) * scale, y: offset.y + (p.y - minY) * scale)
        }
    }

    private func makeMapping(size: CGSize) -> Mapping {
        let all = fixedRooms + movingRooms
        var points: [CGPoint] = []
        for room in all {
            guard let origin = room.structureOriginM, origin.count >= 2 else { continue }
            for p in room.outlineM where p.count >= 2 {
                points.append(CGPoint(x: origin[0] + p[0], y: origin[1] + p[1]))
            }
        }
        let margin: CGFloat = 24
        guard !points.isEmpty else {
            return Mapping(scale: 1, offset: CGPoint(x: margin, y: margin), minX: 0, minY: 0)
        }
        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let maxY = points.map(\.y).max() ?? 1
        let w = max(maxX - minX, 0.1)
        let h = max(maxY - minY, 0.1)
        let scale = min((size.width - margin * 2) / w, (size.height - margin * 2) / h)
        return Mapping(scale: scale, offset: CGPoint(x: margin, y: margin), minX: minX, minY: minY)
    }

    private func draw(in context: inout GraphicsContext, mapping: Mapping) {
        for room in fixedRooms {
            drawRoom(room, in: &context, mapping: mapping, fill: Color.gray.opacity(0.25), stroke: .gray, rotated: false)
        }
        for room in movingRooms {
            drawRoom(room, in: &context, mapping: mapping, fill: VuuroColor.accent.opacity(0.25), stroke: VuuroColor.accent, rotated: true)
        }
        let pivotView = mapping.toView(pivot)
        var dot = Path()
        dot.addEllipse(in: CGRect(x: pivotView.x - 3, y: pivotView.y - 3, width: 6, height: 6))
        context.fill(dot, with: .color(.red))
    }

    private func drawRoom(_ room: FloorPlan.Room, in context: inout GraphicsContext, mapping: Mapping, fill: Color, stroke: Color, rotated: Bool) {
        guard let origin = room.structureOriginM, origin.count >= 2 else { return }
        let pts = room.outlineM.compactMap { p -> CGPoint? in
            guard p.count >= 2 else { return nil }
            let world = CGPoint(x: origin[0] + p[0], y: origin[1] + p[1])
            let transformed: CGPoint
            if rotated {
                let r = GroupPlacementMath.rotate(point: world, around: pivot, byDegrees: rotationDeg)
                transformed = CGPoint(x: r.x + offsetM.width, y: r.y + offsetM.height)
            } else {
                transformed = world
            }
            return mapping.toView(transformed)
        }
        var path = Path()
        guard let first = pts.first else { return }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        context.fill(path, with: .color(fill))
        context.stroke(path, with: .color(stroke), lineWidth: 2)
    }

    private func rotateButton(_ label: String, _ delta: Double) -> some View {
        Button(label) { rotationDeg += delta }
            .buttonStyle(.vuuroOutlineSmall)
            .accessibilityIdentifier("groupPlacement.rotate.\(label)")
    }

    private func nudgeButton(_ label: String, dx: Double, dy: Double) -> some View {
        Button(label) {
            offsetM.width += CGFloat(dx)
            offsetM.height += CGFloat(dy)
            committedOffsetM = offsetM
        }
        .buttonStyle(.vuuroOutlineSmall)
        .accessibilityIdentifier("groupPlacement.nudge.\(label)")
    }

    @MainActor
    private func save(joinTo: String?) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let server = GroupPlacementMath.toServerTransform(
            pivot: pivot,
            rotationDegrees: rotationDeg,
            translationM: CGPoint(x: offsetM.width, y: offsetM.height)
        )
        do {
            let updated = try await client.placeGroup(
                sessionId: session.id,
                accessToken: session.accessToken,
                groupId: groupId,
                joinTo: joinTo,
                rotationDeg: server.rotationDeg,
                translationM: server.translationM,
                floor: floor
            )
            onFinished(updated)
        } catch is CancellationError {
        } catch {
            self.error = AppError(site: .groupPlacement, underlying: error)
        }
    }
}
