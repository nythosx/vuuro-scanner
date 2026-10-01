import CoreGraphics
import Foundation

enum GroupPlacementMath {
    static func rotate(
        point: CGPoint,
        around pivot: CGPoint,
        byDegrees degrees: Double
    ) -> CGPoint {
        let theta = degrees * .pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        let dx = Double(point.x - pivot.x)
        let dy = Double(point.y - pivot.y)
        return CGPoint(
            x: pivot.x + CGFloat(dx * cosT - dy * sinT),
            y: pivot.y + CGFloat(dx * sinT + dy * cosT)
        )
    }

    static func toServerTransform(
        pivot: CGPoint,
        rotationDegrees: Double,
        translationM: CGPoint
    ) -> (rotationDeg: Double, translationM: [Double]) {
        let theta = rotationDegrees * .pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        let px = Double(pivot.x)
        let py = Double(pivot.y)
        let tx = Double(translationM.x) + px - (px * cosT - py * sinT)
        let tz = Double(translationM.y) + py - (px * sinT + py * cosT)
        return (rotationDegrees, [tx, tz])
    }

    static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }
}
