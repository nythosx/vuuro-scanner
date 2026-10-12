import RoomPlan
import simd

enum RoomSizeGuard {
    static let practicalLimitMeters: Float = 9.0

    static func exceedsPracticalLimit(_ room: CapturedRoom) -> Bool {
        for floor in room.floors {
            let corners = floor.polygonCorners.map { floor.transform * simd_float4($0, 1) }
            guard corners.count >= 3 else { continue }
            let points = corners.map { SIMD2<Float>($0.x, $0.z) }
            let (width, height) = orientedExtents(of: points)
            if width > practicalLimitMeters || height > practicalLimitMeters {
                return true
            }
        }
        return false
    }

    private static func orientedExtents(of points: [SIMD2<Float>]) -> (width: Float, height: Float) {
        let count = Float(points.count)
        let mean = points.reduce(SIMD2<Float>(0, 0), +) / count

        var covXX: Float = 0, covXY: Float = 0, covYY: Float = 0
        for point in points {
            let d = point - mean
            covXX += d.x * d.x
            covXY += d.x * d.y
            covYY += d.y * d.y
        }
        covXX /= count
        covXY /= count
        covYY /= count

        let angle = 0.5 * atan2(2 * covXY, covXX - covYY)
        let cosA = cos(angle)
        let sinA = sin(angle)

        var minU = Float.greatestFiniteMagnitude, maxU = -Float.greatestFiniteMagnitude
        var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
        for point in points {
            let u = point.x * cosA + point.y * sinA
            let v = -point.x * sinA + point.y * cosA
            minU = min(minU, u)
            maxU = max(maxU, u)
            minV = min(minV, v)
            maxV = max(maxV, v)
        }
        return (maxU - minU, maxV - minV)
    }
}
