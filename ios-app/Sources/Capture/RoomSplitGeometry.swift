import CoreGraphics
import Foundation

enum RoomSplitGeometry {
    static let minPartAreaM2 = 0.5

    struct Part {
        let points: [CGPoint]
        let openEdges: Set<Int>
        let areaM2: Double
    }

    enum CutError: Error, Equatable {
        case tooShort
        case doesNotCross
        case crossesTooOften
        case runsOutside
        case alongWall
        case partTooSmall(Double)

        var message: String {
            switch self {
            case .tooShort:
                return vuuroLocalized("The line is too short. Drag both ends across the room.")
            case .doesNotCross:
                return vuuroLocalized("Drag both ends outside the room so the line crosses it from wall to wall.")
            case .crossesTooOften:
                return vuuroLocalized("The line crosses the room more than twice. Use a shorter line that cuts off one part only.")
            case .runsOutside:
                return vuuroLocalized("The line runs outside the room. Draw it across the part you want to separate.")
            case .alongWall:
                return vuuroLocalized("The line runs along a wall. Draw it across the room instead.")
            case .partTooSmall(let area):
                return String(format: vuuroLocalized("One side would only be %.2f m². Move the line so both parts are at least 0.5 m²."), area)
            }
        }
    }

    private struct Hit {
        let edge: Int
        let t: Double
        let s: Double
        let point: CGPoint
    }

    static func cut(outline: [CGPoint], openEdges: Set<Int>, from a: CGPoint, to b: CGPoint) -> Result<[Part], CutError> {
        let n = outline.count
        guard n >= 3 else { return .failure(.doesNotCross) }
        let rx = Double(b.x - a.x)
        let rz = Double(b.y - a.y)
        guard (rx * rx + rz * rz).squareRoot() >= 0.05 else { return .failure(.tooShort) }

        var hits: [Hit] = []
        for i in 0..<n {
            let p = outline[i]
            let q = outline[(i + 1) % n]
            let sx = Double(q.x - p.x)
            let sz = Double(q.y - p.y)
            let denominator = rx * sz - rz * sx
            if abs(denominator) < 1e-9 { continue }
            let dx = Double(p.x - a.x)
            let dz = Double(p.y - a.y)
            let s = (dx * sz - dz * sx) / denominator
            let t = (dx * rz - dz * rx) / denominator
            if s < -1e-9 || s > 1 + 1e-9 || t < -1e-9 || t >= 1 - 1e-7 { continue }
            let point = CGPoint(x: Double(p.x) + t * sx, y: Double(p.y) + t * sz)
            if hits.contains(where: { abs($0.point.x - point.x) < 1e-6 && abs($0.point.y - point.y) < 1e-6 }) { continue }
            hits.append(Hit(edge: i, t: max(0, t), s: s, point: point))
        }
        guard hits.count == 2 else {
            return .failure(hits.count < 2 ? .doesNotCross : .crossesTooOften)
        }
        hits.sort { $0.s < $1.s }
        let mid = CGPoint(x: (hits[0].point.x + hits[1].point.x) / 2, y: (hits[0].point.y + hits[1].point.y) / 2)
        guard contains(outline, mid) else { return .failure(.runsOutside) }

        var ring: [CGPoint] = []
        var flags: [Bool] = []
        var hitIndex: [Int: Int] = [:]
        for i in 0..<n {
            ring.append(outline[i])
            flags.append(openEdges.contains(i))
            let onEdge = hits.indices.filter { hits[$0].edge == i }.sorted { hits[$0].t < hits[$1].t }
            for k in onEdge {
                hitIndex[k] = ring.count
                ring.append(hits[k].point)
                flags.append(openEdges.contains(i))
            }
        }

        guard let first = hitIndex[0], let second = hitIndex[1] else { return .failure(.doesNotCross) }
        let m = ring.count
        var parts: [Part] = []
        for (from, to) in [(first, second), (second, first)] {
            var points: [CGPoint] = []
            var partFlags: [Bool] = []
            var k = from
            while true {
                points.append(ring[k])
                if k == to {
                    partFlags.append(true)
                    break
                }
                partFlags.append(flags[k])
                k = (k + 1) % m
            }
            (points, partFlags) = dropDuplicates(points, partFlags)
            guard points.count >= 3 else { return .failure(.alongWall) }
            let area = self.area(points)
            guard area >= minPartAreaM2 else { return .failure(.partTooSmall(area)) }
            let open = Set(partFlags.indices.filter { partFlags[$0] })
            parts.append(Part(points: points, openEdges: open, areaM2: area))
        }
        return .success(parts)
    }

    static func contains(_ points: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let pi = points[i]
            let pj = points[j]
            if (pi.y > p.y) != (pj.y > p.y), p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func area(_ points: [CGPoint]) -> Double {
        var sum = 0.0
        for i in points.indices {
            let p = points[i]
            let q = points[(i + 1) % points.count]
            sum += Double(p.x * q.y - q.x * p.y)
        }
        return abs(sum) / 2
    }

    static func interiorPoint(_ points: [CGPoint]) -> CGPoint {
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let centroid = CGPoint(x: cx, y: cy)
        if contains(points, centroid) { return centroid }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        var best: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        let steps = 24
        for i in 1..<steps {
            for j in 1..<steps {
                let candidate = CGPoint(
                    x: minX + (maxX - minX) * CGFloat(i) / CGFloat(steps),
                    y: minY + (maxY - minY) * CGFloat(j) / CGFloat(steps)
                )
                guard contains(points, candidate) else { continue }
                let distance = hypot(candidate.x - cx, candidate.y - cy)
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return best ?? centroid
    }

    static func dominantAngle(_ outline: [CGPoint]) -> Double {
        var longest = 0.0
        var angle = 0.0
        for i in outline.indices {
            let p = outline[i]
            let q = outline[(i + 1) % outline.count]
            let length = Double(hypot(q.x - p.x, q.y - p.y))
            if length > longest {
                longest = length
                angle = atan2(Double(q.y - p.y), Double(q.x - p.x))
            }
        }
        return angle
    }

    static func snapped(_ moving: CGPoint, around fixed: CGPoint, dominantAngle: Double, toleranceDeg: Double = 6) -> CGPoint {
        let dx = Double(moving.x - fixed.x)
        let dy = Double(moving.y - fixed.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.01 else { return moving }
        let angle = atan2(dy, dx)
        for k in 0..<4 {
            let target = dominantAngle + Double(k) * .pi / 2
            var diff = (angle - target).truncatingRemainder(dividingBy: 2 * .pi)
            if diff > .pi { diff -= 2 * .pi }
            if diff < -.pi { diff += 2 * .pi }
            if abs(diff) * 180 / .pi <= toleranceDeg {
                return CGPoint(x: Double(fixed.x) + cos(target) * length, y: Double(fixed.y) + sin(target) * length)
            }
            let opposite = target + .pi
            var diffOpposite = (angle - opposite).truncatingRemainder(dividingBy: 2 * .pi)
            if diffOpposite > .pi { diffOpposite -= 2 * .pi }
            if diffOpposite < -.pi { diffOpposite += 2 * .pi }
            if abs(diffOpposite) * 180 / .pi <= toleranceDeg {
                return CGPoint(x: Double(fixed.x) + cos(opposite) * length, y: Double(fixed.y) + sin(opposite) * length)
            }
        }
        return moving
    }

    static func initialLine(_ outline: [CGPoint]) -> (CGPoint, CGPoint) {
        let minX = outline.map(\.x).min() ?? 0
        let maxX = outline.map(\.x).max() ?? 0
        let minY = outline.map(\.y).min() ?? 0
        let maxY = outline.map(\.y).max() ?? 0
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let across = dominantAngle(outline) + .pi / 2
        let reach = Double(hypot(maxX - minX, maxY - minY)) / 2 + 0.6
        return (
            CGPoint(x: Double(center.x) - cos(across) * reach, y: Double(center.y) - sin(across) * reach),
            CGPoint(x: Double(center.x) + cos(across) * reach, y: Double(center.y) + sin(across) * reach)
        )
    }

    private static func dropDuplicates(_ points: [CGPoint], _ flags: [Bool]) -> ([CGPoint], [Bool]) {
        var points = points
        var flags = flags
        var changed = true
        while changed && points.count > 2 {
            changed = false
            for i in points.indices {
                let next = (i + 1) % points.count
                if abs(points[i].x - points[next].x) < 1e-6 && abs(points[i].y - points[next].y) < 1e-6 {
                    flags[i] = flags[next]
                    points.remove(at: next)
                    flags.remove(at: next)
                    changed = true
                    break
                }
            }
        }
        return (points, flags)
    }
}
