import SwiftUI

struct ScanCoverageMapView: View {
    @ObservedObject var tracker: ScanCoverageTracker
    var size: CGFloat = 96
    static let panelWidth: CGFloat = 108

    @AppStorage("scanCoverage.mapShown.v1") private var mapShown = true

    var body: some View {
        if tracker.hasMesh {
            if mapShown {
                VStack(alignment: .trailing, spacing: 4) {
                    toggleButton
                    content(tracker.snapshot)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("capture.coverageMap")
                }
                .frame(width: size)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                toggleButton
                    .padding(.horizontal, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var toggleButton: some View {
        Button {
            mapShown.toggle()
        } label: {
            Label(mapShown ? vuuroLocalized("Hide map") : vuuroLocalized("Map"), systemImage: mapShown ? "eye.slash" : "map")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture.coverageMapToggle")
    }

    private func content(_ snapshot: ScanCoverageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, canvasSize in
                Self.draw(snapshot, in: &context, size: canvasSize)
            }
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                legend(VuuroColor.lime, vuuroLocalized("Seen"))
                legend(VuuroColor.accent, vuuroLocalized("Missing"))
            }
            Text(Self.percentText(snapshot))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.ceilingSeen, !snapshot.floor.isEmpty {
                Text(vuuroLocalized("Point up once so floor gaps show"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VuuroColor.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let walls = Self.wallText(snapshot) {
                Text(walls)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let corners = Self.cornerText(snapshot) {
                Text(corners)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let hint = snapshot.hint {
                Text(Self.hintText(hint))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VuuroColor.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: size, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    static func percentText(_ snapshot: ScanCoverageSnapshot) -> String {
        if snapshot.floor.isEmpty { return vuuroLocalized("Floor: point at the floor") }
        guard let percent = snapshot.floorPercent else {
            return String(format: vuuroLocalized("Floor %.1f m² seen"), snapshot.floorSeenM2)
        }
        return String(format: vuuroLocalized("Floor %lld%% seen"), Int(percent.rounded()))
    }

    static func wallText(_ snapshot: ScanCoverageSnapshot) -> String? {
        guard let percent = snapshot.wallPercent else { return nil }
        return String(format: vuuroLocalized("Walls %lld%% seen"), Int(percent.rounded()))
    }

    static func cornerText(_ snapshot: ScanCoverageSnapshot) -> String? {
        guard !snapshot.corners.isEmpty else { return nil }
        return String(format: vuuroLocalized("Corners %lld of %lld seen"), snapshot.cornersSeen, snapshot.corners.count)
    }

    static func hintText(_ hint: ScanCoverageHint) -> String {
        let distance = String(format: "%.1f m", hint.distanceM)
        if hint.target == .wall {
            switch hint.direction {
            case .ahead: return String(format: vuuroLocalized("Wall not seen ahead, %@"), distance)
            case .left: return String(format: vuuroLocalized("Wall not seen to your left, %@"), distance)
            case .right: return String(format: vuuroLocalized("Wall not seen to your right, %@"), distance)
            case .behind: return String(format: vuuroLocalized("Wall not seen behind you, %@"), distance)
            }
        }
        if hint.target == .corner {
            switch hint.direction {
            case .ahead: return String(format: vuuroLocalized("Corner not seen ahead, %@"), distance)
            case .left: return String(format: vuuroLocalized("Corner not seen to your left, %@"), distance)
            case .right: return String(format: vuuroLocalized("Corner not seen to your right, %@"), distance)
            case .behind: return String(format: vuuroLocalized("Corner not seen behind you, %@"), distance)
            }
        }
        switch hint.direction {
        case .ahead: return String(format: vuuroLocalized("Floor missing ahead, %@"), distance)
        case .left: return String(format: vuuroLocalized("Floor missing to your left, %@"), distance)
        case .right: return String(format: vuuroLocalized("Floor missing to your right, %@"), distance)
        case .behind: return String(format: vuuroLocalized("Floor missing behind you, %@"), distance)
        }
    }

    static func draw(_ snapshot: ScanCoverageSnapshot, in context: inout GraphicsContext, size: CGSize) {
        let all = snapshot.floor.union(snapshot.wall).union(snapshot.furniture).union(snapshot.missing)
        guard !all.isEmpty || !snapshot.wallStrips.isEmpty else { return }
        let cell = ScanCoverageGrid.cellM
        var minX = Float.infinity, maxX = -Float.infinity, minZ = Float.infinity, maxZ = -Float.infinity
        for item in all {
            let x = Float(item.x) * cell
            let z = Float(item.z) * cell
            minX = min(minX, x)
            maxX = max(maxX, x + cell)
            minZ = min(minZ, z)
            maxZ = max(maxZ, z + cell)
        }
        for strip in snapshot.wallStrips {
            for end in [strip.start, strip.end] {
                minX = min(minX, end.x)
                maxX = max(maxX, end.x)
                minZ = min(minZ, end.y)
                maxZ = max(maxZ, end.y)
            }
        }
        if let camera = snapshot.camera {
            minX = min(minX, camera.x)
            maxX = max(maxX, camera.x)
            minZ = min(minZ, camera.y)
            maxZ = max(maxZ, camera.y)
        }
        let inset: CGFloat = 6
        let spanX = CGFloat(max(maxX - minX, 1))
        let spanZ = CGFloat(max(maxZ - minZ, 1))
        let scale = min((size.width - inset * 2) / spanX, (size.height - inset * 2) / spanZ)
        let offsetX = (size.width - spanX * scale) / 2
        let offsetZ = (size.height - spanZ * scale) / 2
        func point(_ x: Float, _ z: Float) -> CGPoint {
            CGPoint(x: offsetX + CGFloat(x - minX) * scale, y: offsetZ + CGFloat(z - minZ) * scale)
        }
        func fill(_ cells: Set<CoverageCell>, _ color: Color) {
            var path = Path()
            let side = CGFloat(cell) * scale
            for item in cells {
                let origin = point(Float(item.x) * cell, Float(item.z) * cell)
                path.addRect(CGRect(x: origin.x, y: origin.y, width: side + 0.5, height: side + 0.5))
            }
            context.fill(path, with: .color(color))
        }
        fill(snapshot.floor, VuuroColor.lime.opacity(0.55))
        fill(snapshot.furniture, Color.gray.opacity(0.7))
        fill(snapshot.missing, VuuroColor.accent.opacity(0.85))
        fill(snapshot.wall, Color.white.opacity(snapshot.wallStrips.isEmpty ? 0.9 : 0.35))
        var seenWalls = Path()
        var missingWalls = Path()
        for strip in snapshot.wallStrips {
            if strip.seen {
                seenWalls.move(to: point(strip.start.x, strip.start.y))
                seenWalls.addLine(to: point(strip.end.x, strip.end.y))
            } else {
                missingWalls.move(to: point(strip.start.x, strip.start.y))
                missingWalls.addLine(to: point(strip.end.x, strip.end.y))
            }
        }
        context.stroke(seenWalls, with: .color(VuuroColor.lime), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt))
        context.stroke(missingWalls, with: .color(VuuroColor.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, dash: [3, 2]))
        for corner in snapshot.corners {
            let center = point(corner.point.x, corner.point.y)
            let dot = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
            if corner.seen {
                context.fill(dot, with: .color(VuuroColor.lime))
            } else {
                context.fill(dot, with: .color(VuuroColor.accent))
                context.stroke(dot, with: .color(.white), lineWidth: 1)
            }
        }
        if snapshot.path.count > 1 {
            var line = Path()
            line.move(to: point(snapshot.path[0].x, snapshot.path[0].y))
            for step in snapshot.path.dropFirst() {
                line.addLine(to: point(step.x, step.y))
            }
            context.stroke(line, with: .color(Color.cyan.opacity(0.9)), lineWidth: 1.5)
        }
        if let hint = snapshot.hint {
            let center = point(hint.center.x, hint.center.y)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(VuuroColor.accent), lineWidth: 2)
        }
        if let camera = snapshot.camera {
            let center = point(camera.x, camera.y)
            if let forward = snapshot.cameraForward {
                var arrow = Path()
                arrow.move(to: center)
                arrow.addLine(to: CGPoint(x: center.x + CGFloat(forward.x) * 12, y: center.y + CGFloat(forward.y) * 12))
                context.stroke(arrow, with: .color(.white), lineWidth: 2)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(.white))
        }
    }
}
