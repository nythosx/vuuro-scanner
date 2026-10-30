import CoreGraphics
import Foundation
import simd

enum PhotoTourStrings {
    static var start: String { vuuroLocalized("Point the camera at a wall to start.") }
    static var ready: String { vuuroLocalized("You can finish. Tap Finish when ready.") }
    static var lastWall: String { vuuroLocalized("Aim at the last uncovered wall, marked in red.") }
    static func wallsLeft(_ n: Int) -> String {
        String(format: vuuroLocalized("Aim at the red walls on the minimap \u{2014} %d left."), n)
    }
    static func finishAnywayWalls(_ n: Int) -> String {
        n == 1
            ? vuuroLocalized("1 wall hasn't been photographed. The tour will be missing that view.")
            : String(format: vuuroLocalized("%d walls haven't been photographed. The tour will be missing those views."), n)
    }
    static var finishAnywayOk: String { vuuroLocalized("You can finish anyway, or keep scanning for a better tour.") }
    static var photoCapBanner: String { vuuroLocalized("Photo limit reached. Tap Finish to save the photos.") }
}

struct RoomPhotoCoverage: Equatable {
    static let minimumWallLengthM = 0.5
    static let collinearAngleDeg = 10.0
    static let collinearOffsetM = 0.3
    static let readyWallCoverage = 0.8
    static let shortWallM = 1.0
    static let readyPositionCoverage = 0.5
    static let standableMarginM = 1.0
    static let walkReachRadiusM = 1.0
    static let maxWalkJumpM = 3.0

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

    private(set) var photoCells: Set<Cell>
    private(set) var walkedCells: Set<Cell>
    private(set) var photographedWalls: Set<Int>
    private(set) var recordedPositions: [SIMD2<Double>]
    let walkableCells: Set<Cell>
    private(set) var reachedCells: Set<Cell>
    private(set) var walkedPositions: [SIMD2<Double>]
    private var walkSegmentEnded = false

    init(outline: [CGPoint], cellSizeM: Double = 1.0, roomHeadingDeg: Double? = nil) {
        let points = outline.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        self.outline = points
        self.cellSizeM = cellSizeM
        self.roomHeadingDeg = roomHeadingDeg
        self.photoCells = []
        self.walkedCells = []
        self.photographedWalls = []
        self.recordedPositions = []
        self.reachedCells = []
        self.walkedPositions = []

        guard points.count >= 3 else {
            self.gridOrigin = SIMD2<Double>(0, 0)
            self.gridWidth = 0
            self.gridDepth = 0
            self.inRoomCells = []
            self.walkableCells = []
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
        let core = cells.filter { cell in
            let center = SIMD2<Double>(minX + (Double(cell.x) + 0.5) * cellSizeM, minZ + (Double(cell.z) + 0.5) * cellSizeM)
            return Self.distanceToOutline(points, center) >= Self.standableMarginM
        }
        self.walkableCells = core.isEmpty ? cells : core

        var area2 = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area2 += a.x * b.y - b.x * a.y
        }
        let sign: Double = area2 >= 0 ? 1.0 : -1.0
        self.walls = Self.logicalWalls(points, sign: sign)
    }

    static func logicalWalls(_ points: [SIMD2<Double>], sign: Double) -> [Wall] {
        var edges: [(index: Int, a: SIMD2<Double>, b: SIMD2<Double>)] = []
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            if simd_length(b - a) >= 1e-6 {
                edges.append((index: i, a: a, b: b))
            }
        }
        let long = edges.filter { simd_length($0.b - $0.a) >= minimumWallLengthM }
        let usable = long.isEmpty ? edges : long
        guard !usable.isEmpty else { return [] }

        func continues(_ first: (index: Int, a: SIMD2<Double>, b: SIMD2<Double>), _ next: (index: Int, a: SIMD2<Double>, b: SIMD2<Double>)) -> Bool {
            let d1 = simd_normalize(first.b - first.a)
            let d2 = simd_normalize(next.b - next.a)
            guard simd_dot(d1, d2) >= cos(collinearAngleDeg * .pi / 180.0) else { return false }
            let offset = next.a - first.a
            let perpendicular = abs(offset.x * d1.y - offset.y * d1.x)
            return perpendicular <= collinearOffsetM
        }

        var start = 0
        if usable.count > 1 {
            for k in usable.indices where !continues(usable[(k - 1 + usable.count) % usable.count], usable[k]) {
                start = k
                break
            }
        }

        var groups: [[(index: Int, a: SIMD2<Double>, b: SIMD2<Double>)]] = []
        for step in 0..<usable.count {
            let edge = usable[(start + step) % usable.count]
            if var last = groups.last, let tail = last.last, continues(tail, edge) {
                last.append(edge)
                groups[groups.count - 1] = last
            } else {
                groups.append([edge])
            }
        }

        return groups.map { group in
            let a = group[0].a
            let b = group[group.count - 1].b
            let direction = simd_length(b - a) > 1e-6 ? simd_normalize(b - a) : simd_normalize(group[0].b - group[0].a)
            let inward = SIMD2<Double>(-direction.y * sign, direction.x * sign)
            return Wall(
                index: group[0].index,
                a: a,
                b: b,
                inwardNormal: inward,
                midpoint: (a + b) / 2
            )
        }
    }

    mutating func record(positionM: CGPoint, cameraHeadingDeg: Double) {
        let pos = SIMD2<Double>(Double(positionM.x), Double(positionM.y))
        if let cell = cellFor(pos) {
            photoCells.insert(cell)
        }
        let direction = directionVector(cameraHeadingDeg: cameraHeadingDeg)
        if let wallIndex = Self.rayHitWall(origin: pos, direction: direction, walls: walls) {
            photographedWalls.insert(wallIndex)
        }
        recordedPositions.append(pos)
    }

    mutating func recordWalk(positionM: CGPoint) {
        let pos = SIMD2<Double>(Double(positionM.x), Double(positionM.y))
        var path = [pos]
        if !walkSegmentEnded, let previous = walkedPositions.last, simd_length(pos - previous) <= Self.maxWalkJumpM {
            path = samplesAlong(from: previous, to: pos)
            for cell in cellsAlong(from: previous, to: pos) {
                walkedCells.insert(cell)
            }
        }
        if let cell = cellFor(pos) {
            walkedCells.insert(cell)
        }
        for point in path {
            markReached(around: point)
        }
        walkedPositions.append(pos)
        walkSegmentEnded = false
    }

    mutating func endWalkSegment() {
        walkSegmentEnded = true
    }

    var coveredCells: Set<Cell> {
        photoCells.union(walkedCells)
    }

    mutating func reset() {
        photoCells.removeAll()
        photographedWalls.removeAll()
        recordedPositions.removeAll()
    }

    private func samplesAlong(from a: SIMD2<Double>, to b: SIMD2<Double>) -> [SIMD2<Double>] {
        let length = simd_length(b - a)
        let step = max(cellSizeM * 0.5, 0.1)
        let steps = max(1, Int(ceil(length / step)))
        return (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return a + (b - a) * t
        }
    }

    private func cellsAlong(from a: SIMD2<Double>, to b: SIMD2<Double>) -> Set<Cell> {
        Set(samplesAlong(from: a, to: b).compactMap { cellFor($0) })
    }

    private mutating func markReached(around pos: SIMD2<Double>) {
        let r = Self.walkReachRadiusM
        let rSq = r * r
        guard gridWidth > 0, gridDepth > 0 else { return }
        let ixMin = max(0, Int(floor((pos.x - r - gridOrigin.x) / cellSizeM)))
        let ixMax = min(gridWidth - 1, Int(floor((pos.x + r - gridOrigin.x) / cellSizeM)))
        let izMin = max(0, Int(floor((pos.y - r - gridOrigin.y) / cellSizeM)))
        let izMax = min(gridDepth - 1, Int(floor((pos.y + r - gridOrigin.y) / cellSizeM)))
        guard ixMin <= ixMax, izMin <= izMax else { return }
        for ix in ixMin...ixMax {
            for iz in izMin...izMax {
                let cell = Cell(x: ix, z: iz)
                guard inRoomCells.contains(cell) else { continue }
                let cx = gridOrigin.x + (Double(ix) + 0.5) * cellSizeM
                let cz = gridOrigin.y + (Double(iz) + 0.5) * cellSizeM
                let dx = cx - pos.x
                let dz = cz - pos.y
                if dx * dx + dz * dz <= rSq {
                    reachedCells.insert(cell)
                }
            }
        }
    }

    var minimapCells: Set<Cell> {
        walkableCells
    }

    var notWalkableCells: Set<Cell> {
        inRoomCells.subtracting(walkableCells)
    }

    var seenCells: Set<Cell> {
        coveredCells.union(reachedCells)
    }

    var walkablePositionCoverage: Double {
        guard !walkableCells.isEmpty else { return 0 }
        return Double(seenCells.intersection(walkableCells).count) / Double(walkableCells.count)
    }

    static func distanceToOutline(_ points: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var best = Double.infinity
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            let ab = b - a
            let lengthSq = simd_length_squared(ab)
            let t = lengthSq > 1e-12 ? min(1, max(0, simd_dot(p - a, ab) / lengthSq)) : 0
            best = min(best, simd_length(p - (a + ab * t)))
        }
        return best
    }

    var positionCoverage: Double {
        guard !inRoomCells.isEmpty else { return 0 }
        return Double(coveredCells.count) / Double(inRoomCells.count)
    }

    var coveredWalls: Set<Int> {
        var covered = photographedWalls
        guard walls.count > 2 else { return covered }
        for (k, wall) in walls.enumerated() where !covered.contains(wall.index) {
            guard simd_length(wall.b - wall.a) < Self.shortWallM else { continue }
            let previous = walls[(k - 1 + walls.count) % walls.count].index
            let next = walls[(k + 1) % walls.count].index
            if photographedWalls.contains(previous) || photographedWalls.contains(next) {
                covered.insert(wall.index)
            }
        }
        return covered
    }

    var wallCoverage: Double {
        guard !walls.isEmpty else { return 0 }
        return Double(coveredWalls.count) / Double(walls.count)
    }

    var overallCoverage: Double {
        wallCoverage
    }

    var isReadyToFinish: Bool {
        wallCoverage >= Self.readyWallCoverage
    }

    var uncoveredWalls: [Wall] {
        walls.filter { !coveredWalls.contains($0.index) }
    }

    enum NextGate: Equatable {
        case start
        case ready
        case walls(remaining: Int)
    }

    struct NextAction: Equatable {
        let gate: NextGate
        let message: String
    }

    var nextActionStructured: NextAction? {
        if recordedPositions.isEmpty && walkedPositions.isEmpty {
            return NextAction(gate: .start, message: PhotoTourStrings.start)
        }
        if isReadyToFinish {
            return NextAction(gate: .ready, message: PhotoTourStrings.ready)
        }
        let uncovered = uncoveredWalls
        if !uncovered.isEmpty {
            if uncovered.count == 1 {
                return NextAction(gate: .walls(remaining: 1), message: PhotoTourStrings.lastWall)
            }
            return NextAction(gate: .walls(remaining: uncovered.count), message: PhotoTourStrings.wallsLeft(uncovered.count))
        }
        return nil
    }

    var nextAction: String? {
        nextActionStructured?.message
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
