import SwiftUI

struct CoverageMinimap: View {
    let outline: [CGPoint]
    let coverage: RoomPhotoCoverage
    let currentPosition: CGPoint?
    let currentHeadingDeg: Double?
    var compact: Bool = false
    var positionReliable: Bool = true
    var chromeless: Bool = false
    var coveredWallColor: Color = VuuroColor.textPrimary
    var standSpots: [CGPoint] = []
    var suggestedSpot: CGPoint? = nil

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let mapping = Mapping(outline: outline, size: size)
                draw(in: &context, mapping: mapping)
            }
        }
        .background(chromeless ? Color.clear : VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(chromeless ? Color.clear : VuuroColor.borderMed, lineWidth: 1)
        )
        .accessibilityIdentifier("coverage.minimap")
        .accessibilityLabel(String(
            format: vuuroLocalized("Coverage map. %d%% of the room walked, %d%% of walls photographed."),
            Int(coverage.walkablePositionCoverage * 100),
            Int(coverage.wallCoverage * 100)
        ))
    }

    private func cellRect(_ cell: RoomPhotoCoverage.Cell, mapping: Mapping) -> CGRect {
        let cellMinX = coverage.gridOrigin.x + Double(cell.x) * coverage.cellSizeM
        let cellMinZ = coverage.gridOrigin.y + Double(cell.z) * coverage.cellSizeM
        let topLeft = mapping.toView(CGPoint(x: cellMinX, y: cellMinZ))
        let bottomRight = mapping.toView(CGPoint(
            x: cellMinX + coverage.cellSizeM,
            y: cellMinZ + coverage.cellSizeM
        ))
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    private func draw(in context: inout GraphicsContext, mapping: Mapping) {
        let coveredCells = coverage.seenCells
        for cell in coverage.notWalkableCells {
            CoverageMinimap.drawHatch(in: context, rect: cellRect(cell, mapping: mapping), spacing: compact ? 3 : 5)
        }
        for cell in coverage.minimapCells {
            let rect = cellRect(cell, mapping: mapping)
            let isCovered = coveredCells.contains(cell)
            let colour = isCovered
                ? VuuroColor.lime.opacity(0.35)
                : VuuroColor.textTertiary.opacity(0.10)
            context.fill(Path(rect), with: .color(colour))
        }

        if outline.count >= 3 {
            var outlinePath = Path()
            outlinePath.move(to: mapping.toView(outline[0]))
            for point in outline.dropFirst() {
                outlinePath.addLine(to: mapping.toView(point))
            }
            outlinePath.closeSubpath()
            context.stroke(
                outlinePath,
                with: .color(VuuroColor.textTertiary.opacity(0.6)),
                style: StrokeStyle(lineWidth: compact ? 1 : 1.5, lineJoin: .round)
            )
        }

        for wall in coverage.walls {
            var path = Path()
            path.move(to: mapping.toView(CGPoint(x: wall.a.x, y: wall.a.y)))
            path.addLine(to: mapping.toView(CGPoint(x: wall.b.x, y: wall.b.y)))
            if coverage.coveredWalls.contains(wall.index) {
                context.stroke(
                    path,
                    with: .color(coveredWallColor),
                    style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round)
                )
            } else {
                context.stroke(
                    path,
                    with: .color(VuuroColor.danger),
                    style: StrokeStyle(lineWidth: compact ? 1.5 : 2.5, lineCap: .round, dash: compact ? [3, 2] : [5, 4])
                )
            }
        }

        for spot in standSpots {
            let view = mapping.toView(spot)
            let radius: CGFloat = compact ? 2.5 : 4
            context.fill(
                Path(ellipseIn: CGRect(x: view.x - radius, y: view.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(VuuroColor.lime)
            )
        }
        if let suggested = suggestedSpot {
            let view = mapping.toView(suggested)
            let radius: CGFloat = compact ? 5 : 9
            context.stroke(
                Path(ellipseIn: CGRect(x: view.x - radius, y: view.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(VuuroColor.lime),
                style: StrokeStyle(lineWidth: compact ? 1.5 : 2, dash: [3, 2])
            )
        }
        if let position = currentPosition {
            let posView = mapping.toView(position)
            let dotRadius: CGFloat = compact ? 3 : 5
            let dotRect = CGRect(x: posView.x - dotRadius, y: posView.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            let dotColour = positionReliable ? VuuroColor.accent : VuuroColor.accent.opacity(0.35)
            context.fill(Path(ellipseIn: dotRect), with: .color(dotColour))

            if let heading = currentHeadingDeg {
                let direction = coverage.directionVector(cameraHeadingDeg: heading)
                let arrowLength: CGFloat = compact ? 10 : 22
                let arrowEnd = CGPoint(
                    x: posView.x + direction.x * arrowLength,
                    y: posView.y + direction.y * arrowLength
                )
                var arrow = Path()
                arrow.move(to: posView)
                arrow.addLine(to: arrowEnd)
                context.stroke(
                    arrow,
                    with: .color(dotColour),
                    style: StrokeStyle(lineWidth: compact ? 1.5 : 2.5, lineCap: .round)
                )
            }
        }
    }

    static func drawHatch(in context: GraphicsContext, rect: CGRect, spacing: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        var layer = context
        layer.clip(to: Path(rect))
        var stripes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        layer.stroke(stripes, with: .color(VuuroColor.textTertiary.opacity(0.35)), lineWidth: 0.75)
    }

    private struct Mapping {
        let scale: CGFloat
        let offset: CGPoint
        let minX: CGFloat
        let minY: CGFloat

        init(outline: [CGPoint], size: CGSize) {
            let margin: CGFloat = 0.5
            let minX = (outline.map { $0.x }.min() ?? 0) - margin
            let maxX = (outline.map { $0.x }.max() ?? 1) + margin
            let minY = (outline.map { $0.y }.min() ?? 0) - margin
            let maxY = (outline.map { $0.y }.max() ?? 1) + margin
            let w = max(maxX - minX, 0.1)
            let h = max(maxY - minY, 0.1)
            let scale = min(size.width / w, size.height / h)
            self.scale = scale
            self.minX = minX
            self.minY = minY
            self.offset = CGPoint(
                x: (size.width - w * scale) / 2,
                y: (size.height - h * scale) / 2
            )
        }

        func toView(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: offset.x + (point.x - minX) * scale,
                y: offset.y + (point.y - minY) * scale
            )
        }
    }
}

struct CoverageMinimapLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(Text("Walked")) {
                RoundedRectangle(cornerRadius: 2).fill(VuuroColor.lime.opacity(0.35))
            }
            item(Text("Not walked yet")) {
                RoundedRectangle(cornerRadius: 2).fill(VuuroColor.textTertiary.opacity(0.25))
            }
            item(Text("Near a wall, no need to walk")) {
                Canvas { context, size in
                    CoverageMinimap.drawHatch(in: context, rect: CGRect(origin: .zero, size: size), spacing: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coverage.minimapLegend")
    }

    private func item<Swatch: View>(_ label: Text, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 5) {
            swatch()
                .frame(width: 12, height: 12)
            label
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
