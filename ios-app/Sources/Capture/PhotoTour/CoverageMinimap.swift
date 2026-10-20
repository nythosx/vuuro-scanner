import SwiftUI

struct CoverageMinimap: View {
    let outline: [CGPoint]
    let coverage: RoomPhotoCoverage
    let currentPosition: CGPoint?
    let currentHeadingDeg: Double?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let mapping = Mapping(outline: outline, size: size)
                draw(in: &context, mapping: mapping)
            }
        }
        .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VuuroColor.borderMed, lineWidth: 1)
        )
        .accessibilityIdentifier("coverage.minimap")
        .accessibilityLabel(String(
            format: vuuroLocalized("Coverage map. %d%% of the room walked, %d%% of walls photographed."),
            Int(coverage.positionCoverage * 100),
            Int(coverage.wallCoverage * 100)
        ))
    }

    private func draw(in context: inout GraphicsContext, mapping: Mapping) {
        for cell in coverage.inRoomCells {
            let cellMinX = coverage.gridOrigin.x + Double(cell.x) * coverage.cellSizeM
            let cellMinZ = coverage.gridOrigin.y + Double(cell.z) * coverage.cellSizeM
            let topLeft = mapping.toView(CGPoint(x: cellMinX, y: cellMinZ))
            let bottomRight = mapping.toView(CGPoint(
                x: cellMinX + coverage.cellSizeM,
                y: cellMinZ + coverage.cellSizeM
            ))
            let rect = CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            )
            let isCovered = coverage.coveredCells.contains(cell)
            let colour = isCovered
                ? VuuroColor.lime.opacity(0.35)
                : VuuroColor.textTertiary.opacity(0.10)
            context.fill(Path(rect), with: .color(colour))
        }

        for wall in coverage.walls {
            var path = Path()
            path.move(to: mapping.toView(CGPoint(x: wall.a.x, y: wall.a.y)))
            path.addLine(to: mapping.toView(CGPoint(x: wall.b.x, y: wall.b.y)))
            if coverage.coveredWalls.contains(wall.index) {
                context.stroke(
                    path,
                    with: .color(VuuroColor.textPrimary),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
            } else {
                context.stroke(
                    path,
                    with: .color(VuuroColor.danger),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4])
                )
            }
        }

        if let position = currentPosition {
            let posView = mapping.toView(position)
            let dotRect = CGRect(x: posView.x - 5, y: posView.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dotRect), with: .color(VuuroColor.accent))

            if let heading = currentHeadingDeg {
                let direction = coverage.directionVector(cameraHeadingDeg: heading)
                let arrowEnd = CGPoint(
                    x: posView.x + direction.x * 22,
                    y: posView.y + direction.y * 22
                )
                var arrow = Path()
                arrow.move(to: posView)
                arrow.addLine(to: arrowEnd)
                context.stroke(
                    arrow,
                    with: .color(VuuroColor.accent),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
            }
        }
    }

    private struct Mapping {
        let scale: CGFloat
        let offset: CGPoint
        let minX: CGFloat
        let minY: CGFloat

        init(outline: [CGPoint], size: CGSize) {
            let margin: CGFloat = 12
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
