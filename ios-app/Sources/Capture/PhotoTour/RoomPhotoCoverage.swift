import CoreGraphics
import Foundation
import simd

struct RoomPhotoCoverage: Equatable {
    struct Cell: Hashable {
        let x: Int
        let z: Int
    }

    struct Wall: Hashable {
        let index: Int
        let a: SIMD2<Double>
        let b: SIMD2<Double>
        let inwardNormal: SIMD2<Double>
        let midpoint: SIMD2<Double>
    }

    let outline: [SIMD2<Double>]
    let cellSizeM: Double
    let roomHeadingDeg: Double?
    let gridOrigin: SIMD2<Double>
    let gridWidth: Int
    let gridDepth: Int
    let inRoomCells: Set<Cell>
    let walls: [Wall]

    private(set) var coveredCells: Set<Cell>
    private(set) var coveredWalls: Set<Int>
    private(set) var recordedPositions: [SIMD2<Double>]

    init(outline: [CGPoint], cellSizeM: Double = 1.0, roomHeadingDeg: Double? = nil) {
        let points = outline.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        self.outline = points
        self.cellSizeM = cellSizeM
        self.roomHeadingDeg = roomHeadingDeg
        self.coveredCells = []
        self.coveredWalls = []
        self.recordedPositions = []

        guard points.count >= 3 else {
            self.gridOrigin = SIMD2<Double>(0, 0)
            self.gridWidth = 0
            self.gridDepth = 0
            self.inRoomCells = []
            self.walls = []
            return
        }

        let xs = points.map { $0.x }
        let zs = points.map { $0.y }
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minZ = zs.min() ?? 0
        let maxZ = zs.max() ?? 0
        self.gridOrigin = SIMD2<Double>(minX, minZ)
        self.gridWidth = max(1, Int(ceil((maxX - minX) / cellSizeM)))
        self.gridDepth = max(1, Int(ceil((maxZ - minZ) / cellSizeM)))

        var cells: Set<Cell> = []
        for ix in 0..<self.gridWidth {
            for iz in 0..<self.gridDepth {
                let cx = minX + (Double(ix) + 0.5) * cellSizeM
                let cz = minZ + (Double(iz) + 0.5) * cellSizeM
                if Self.pointInside(points, SIMD2<Double>(cx, cz)) {
                    cells.insert(Cell(x: ix, z: iz))
                }
            }
        }
        self.inRoomCells = cells

        var area2 = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area2 += a.x * b.y - b.x * a.y
        }
        let sign: Double = area2 >= 0 ? 1.0 : -1.0

        var wallList: [Wall] = []
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            let dx = b.x - a.x
            let dz = b.y - a.y
            let length = (dx * dx + dz * dz).squareRoot()
            if length < 1e-6 { continue }
            let inward = SIMD2<Double>(-dz / length * sign, dx / length * sign)
            wallList.append(Wall(
                index: i,
                a: a,
                b: b,
                inwardNormal: inward,
                midpoint: SIMD2<Double>((a.x + b.x) / 2, (a.y + b.y) / 2)
            ))
        }
        self.walls = wallList
    }

    mutating func record(positionM: CGPoint, cameraHeadingDeg: Double) {
        let pos = SIMD2<Double>(Double(positionM.x), Double(positionM.y))
        if let cell = cellFor(pos) {
            coveredCells.insert(cell)
        }
        let direction = directionVector(cameraHeadingDeg: cameraHeadingDeg)
        if let wallIndex = Self.rayHitWall(origin: pos, direction: direction, walls: walls) {
            coveredWalls.insert(wallIndex)
        }
        recordedPositions.append(pos)
    }

    mutating func reset() {
        coveredCells.removeAll()
        coveredWalls.removeAll()
        recordedPositions.removeAll()
    }

    var positionCoverage: Double {
        guard !inRoomCells.isEmpty else { return 0 }
        return Double(coveredCells.count) / Double(inRoomCells.count)
    }

    var wallCoverage: Double {
        guard !walls.isEmpty else { return 0 }
        return Double(coveredWalls.count) / Double(walls.count)
    }

    var overallCoverage: Double {
        guard !inRoomCells.isEmpty || !walls.isEmpty else { return 0 }
        return 0.5 * positionCoverage + 0.5 * wallCoverage
    }

    var isReadyToFinish: Bool {
        positionCoverage >= 0.7 && wallCoverage >= 0.9
    }

    var uncoveredWalls: [Wall] {
        walls.filter { !coveredWalls.contains($0.index) }
    }

    var nextAction: String? {
        if recordedPositions.isEmpty {
            return "Point the camera at a wall to start."
        }
        if isReadyToFinish {
            return "You can finish. Tap Finish when ready."
        }
        let uncovered = uncoveredWalls
        if !uncovered.isEmpty {
            if uncovered.count == 1 {
                return "Aim at the last uncovered wall, marked in red."
            }
            return "Aim at the red walls on the minimap \u{2014} \(uncovered.count) left."
        }
        if positionCoverage < 0.7 {
            return "Walk into the grey areas on the minimap to cover them."
        }
        return nil
    }

    func directionVector(cameraHeadingDeg: Double) -> SIMD2<Double> {
        let room = roomHeadingDeg ?? 0.0
        let theta = (room - cameraHeadingDeg) * .pi / 180.0
        return SIMD2<Double>(sin(theta), cos(theta))
    }

    func cellFor(_ point: SIMD2<Double>) -> Cell? {
        let x = Int(floor((point.x - gridOrigin.x) / cellSizeM))
        let z = Int(floor((point.y - gridOrigin.y) / cellSizeM))
        guard x >= 0, x < gridWidth, z >= 0, z < gridDepth else { return nil }
        let cell = Cell(x: x, z: z)
        return inRoomCells.contains(cell) ? cell : nil
    }

    static func pointInside(_ points: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let pi = points[i]
            let pj = points[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func rayHitWall(origin: SIMD2<Double>, direction: SIMD2<Double>, walls: [Wall]) -> Int? {
        var bestT = Double.infinity
        var bestIndex: Int? = nil
        for wall in walls {
            let seg = wall.b - wall.a
            let denom = direction.x * seg.y - seg.x * direction.y
            if abs(denom) < 1e-9 { continue }
            let diff = wall.a - origin
            let t = (diff.x * seg.y - diff.y * seg.x) / denom
            let s = (diff.x * direction.y - diff.y * direction.x) / denom
            if t > 1e-9 && s >= -1e-9 && s <= 1 + 1e-9 && t < bestT {
                bestT = t
                bestIndex = wall.index
            }
        }
        return bestIndex
    }
}
