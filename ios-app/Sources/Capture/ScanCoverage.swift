import ARKit
import Combine
import Foundation
import QuartzCore
import simd

struct CoverageCell: Hashable, Sendable {
    let x: Int32
    let z: Int32
}

struct ScanCoverageFace {
    let center: SIMD3<Float>
    let normalY: Float
    let classification: UInt8
}

struct ScanCoverageWall: Equatable, Sendable {
    let start: SIMD2<Float>
    let end: SIMD2<Float>

    var lengthM: Float { simd_distance(start, end) }

    init(start: SIMD2<Float>, end: SIMD2<Float>) {
        self.start = start
        self.end = end
    }

    init?(transform: simd_float4x4, widthM: Float) {
        let center = SIMD2<Float>(transform.columns.3.x, transform.columns.3.z)
        let axis = SIMD2<Float>(transform.columns.0.x, transform.columns.0.z)
        guard widthM.isFinite, widthM > 0, simd_length(axis) > 0.01,
              abs(center.x) < ScanCoverageGrid.maxCoordinateM, abs(center.y) < ScanCoverageGrid.maxCoordinateM else { return nil }
        let half = simd_normalize(axis) * (widthM / 2)
        self.init(start: center - half, end: center + half)
    }
}

struct ScanCoverageStair: Equatable, Sendable {
    let center: SIMD2<Float>
    let axis: SIMD2<Float>
    let halfLength: Float
    let halfDepth: Float

    init(center: SIMD2<Float>, axis: SIMD2<Float>, lengthM: Float, depthM: Float) {
        self.center = center
        self.axis = simd_length(axis) > 0 ? simd_normalize(axis) : SIMD2<Float>(1, 0)
        halfLength = lengthM / 2
        halfDepth = depthM / 2
    }

    init?(transform: simd_float4x4, dimensions: simd_float3) {
        let center = SIMD2<Float>(transform.columns.3.x, transform.columns.3.z)
        let axis = SIMD2<Float>(transform.columns.0.x, transform.columns.0.z)
        guard dimensions.x.isFinite, dimensions.z.isFinite, dimensions.x > 0.05, dimensions.z > 0.05,
              dimensions.x < ScanCoverageGrid.maxWallLengthM, dimensions.z < ScanCoverageGrid.maxWallLengthM,
              simd_length(axis) > 0.01,
              abs(center.x) < ScanCoverageGrid.maxCoordinateM, abs(center.y) < ScanCoverageGrid.maxCoordinateM else { return nil }
        self.init(center: center, axis: axis, lengthM: dimensions.x, depthM: dimensions.z)
    }

    var areaM2: Double { Double(4 * halfLength * halfDepth) }

    func contains(_ point: SIMD2<Float>) -> Bool {
        let offset = point - center
        let side = SIMD2<Float>(-axis.y, axis.x)
        let pad = ScanCoverageGrid.cellM / 2
        return abs(simd_dot(offset, axis)) <= halfLength + pad && abs(simd_dot(offset, side)) <= halfDepth + pad
    }

    func cells() -> Set<CoverageCell> {
        let reach = (halfLength * halfLength + halfDepth * halfDepth).squareRoot() + ScanCoverageGrid.cellM
        let low = ScanCoverageGrid.cell(center - SIMD2<Float>(reach, reach))
        let high = ScanCoverageGrid.cell(center + SIMD2<Float>(reach, reach))
        var result: Set<CoverageCell> = []
        for x in low.x...high.x {
            for z in low.z...high.z {
                let cell = CoverageCell(x: x, z: z)
                if contains(ScanCoverageGrid.center(cell)) { result.insert(cell) }
            }
        }
        return result
    }
}

struct ScanCoverageFloorHintWatch: Sendable {
    static let stuckAfterS: TimeInterval = 10
    static let sameTargetM: Float = 1.0
    static let shrinkCells = 2

    private(set) var skipped: [SIMD2<Float>] = []
    private var target: SIMD2<Float>?
    private var cells = 0
    private var since: TimeInterval = 0

    mutating func update(_ hint: ScanCoverageHint?, at time: TimeInterval) -> Bool {
        guard let hint, hint.target == .floor else {
            target = nil
            return false
        }
        if let target, simd_distance(target, hint.center) <= Self.sameTargetM, hint.cells > cells - Self.shrinkCells {
            guard time - since >= Self.stuckAfterS else { return false }
            skipped.append(hint.center)
            self.target = nil
            return true
        }
        target = hint.center
        cells = hint.cells
        since = time
        return false
    }
}

struct ScanCoverageWallStrip: Equatable, Sendable {
    let start: SIMD2<Float>
    let end: SIMD2<Float>
    let seen: Bool
}

struct ScanCoverageCorner: Equatable, Sendable {
    let point: SIMD2<Float>
    let seen: Bool
}

struct ScanCoverageHint: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case ahead, left, right, behind
    }

    enum Target: Equatable, Sendable {
        case floor, corner, wall
    }

    var target: Target = .floor
    let direction: Direction
    let distanceM: Float
    let center: SIMD2<Float>
    var cells = 0
}

struct ScanCoverageSnapshot: Equatable, Sendable {
    var floor: Set<CoverageCell> = []
    var wall: Set<CoverageCell> = []
    var furniture: Set<CoverageCell> = []
    var missing: Set<CoverageCell> = []
    var stairs: Set<CoverageCell> = []
    var wallStrips: [ScanCoverageWallStrip] = []
    var corners: [ScanCoverageCorner] = []
    var ceilingSeen = false
    var floorPercent: Double?
    var path: [SIMD2<Float>] = []
    var camera: SIMD2<Float>?
    var cameraForward: SIMD2<Float>?
    var hint: ScanCoverageHint?

    var isEmpty: Bool {
        floor.isEmpty && wall.isEmpty && furniture.isEmpty && missing.isEmpty
    }

    var wallPercent: Double? {
        var total: Float = 0
        var seen: Float = 0
        for strip in wallStrips {
            let length = simd_distance(strip.start, strip.end)
            total += length
            if strip.seen { seen += length }
        }
        guard total > 0 else { return nil }
        return Double(seen / total * 100)
    }

    var wallMissingM: Double {
        Double(wallStrips.filter { !$0.seen }.reduce(Float(0)) { $0 + simd_distance($1.start, $1.end) })
    }

    var cornersSeen: Int { corners.filter(\.seen).count }

    var floorSeenM2: Double { Double(floor.union(furniture).count) * ScanCoverageGrid.cellAreaM2 }
    var floorMissingM2: Double { Double(missing.count) * ScanCoverageGrid.cellAreaM2 }
}

struct ScanCoverageGrid: Sendable {
    static let cellM: Float = 0.25
    static let cellAreaM2 = Double(cellM * cellM)
    static let upNormalMin: Float = 0.85
    static let unclassifiedFloorToleranceM: Float = 0.15
    static let hintMinCells = 4
    static let maxCoordinateM: Float = 10_000
    static let fallbackFloorMinCells = 20
    static let fallbackCeilingAboveFloorM: Float = 1.8
    static let wallStripM: Float = 0.5
    static let wallMatchRadiusCells: Int32 = 1
    static let maxWallLengthM: Float = 100
    static let cornerJoinM: Float = 0.35
    static let cornerMatchRadiusCells: Int32 = 1
    static let stripSeenFraction = 0.5
    static let cornerMinTurnCos: Float = 0.866
    static let sameFloorToleranceM: Float = 1.0
    static let roomAreaTrustFraction = 0.8
    static let underCeilingFloorFraction = 0.5
    static let floorHintSkipM: Float = 1.0

    static let wallClass: UInt8 = 1
    static let floorClass: UInt8 = 2
    static let ceilingClass: UInt8 = 3
    static let tableClass: UInt8 = 4
    static let seatClass: UInt8 = 5
    static let windowClass: UInt8 = 6
    static let doorClass: UInt8 = 7

    struct AnchorCells: Equatable, Sendable {
        var floor: Set<CoverageCell> = []
        var wall: Set<CoverageCell> = []
        var furniture: Set<CoverageCell> = []
        var ceiling: Set<CoverageCell> = []
        var flatUnclassified: [CoverageCell: Float] = [:]
        var floorHeightSum: Double = 0
        var floorHeightCount = 0
    }

    struct ContextWall: Equatable, Sendable {
        let cells: Set<CoverageCell>
        let floorY: Float
    }

    private(set) var anchors: [UUID: AnchorCells] = [:]
    var contextWalls: [ContextWall] = []

    var ownWall: Set<CoverageCell> {
        anchors.values.reduce(into: Set<CoverageCell>()) { $0.formUnion($1.wall) }
    }

    func roomContext() -> [ContextWall] {
        let wall = ownWall
        guard !wall.isEmpty, let floorY = floorHeight() else { return contextWalls }
        return contextWalls + [ContextWall(cells: wall, floorY: floorY)]
    }

    func floorHeight() -> Float? {
        var heightSum = 0.0
        var heightCount = 0
        var flat: [CoverageCell: Float] = [:]
        for cells in anchors.values {
            heightSum += cells.floorHeightSum
            heightCount += cells.floorHeightCount
            flat.merge(cells.flatUnclassified) { min($0, $1) }
        }
        return heightCount > 0 ? Float(heightSum / Double(heightCount)) : Self.fallbackFloorHeight(Array(flat.values))
    }

    func contextWall(floorY: Float?) -> Set<CoverageCell> {
        guard let floorY else { return [] }
        return contextWalls
            .filter { abs($0.floorY - floorY) <= Self.sameFloorToleranceM }
            .reduce(into: Set<CoverageCell>()) { $0.formUnion($1.cells) }
    }

    static func cell(_ point: SIMD2<Float>) -> CoverageCell {
        CoverageCell(x: Int32((point.x / cellM).rounded(.down)), z: Int32((point.y / cellM).rounded(.down)))
    }

    static func center(_ cell: CoverageCell) -> SIMD2<Float> {
        SIMD2<Float>((Float(cell.x) + 0.5) * cellM, (Float(cell.z) + 0.5) * cellM)
    }

    static func cells(from faces: [ScanCoverageFace]) -> AnchorCells {
        var result = AnchorCells()
        for face in faces {
            guard face.center.y.isFinite, abs(face.center.x) < maxCoordinateM, abs(face.center.z) < maxCoordinateM else { continue }
            let key = Self.cell(SIMD2<Float>(face.center.x, face.center.z))
            switch face.classification {
            case floorClass:
                result.floor.insert(key)
                result.floorHeightSum += Double(face.center.y)
                result.floorHeightCount += 1
            case wallClass, windowClass, doorClass:
                result.wall.insert(key)
            case tableClass, seatClass:
                result.furniture.insert(key)
            case ceilingClass:
                result.ceiling.insert(key)
            default:
                if abs(face.normalY) >= upNormalMin {
                    result.flatUnclassified[key] = min(result.flatUnclassified[key] ?? .infinity, face.center.y)
                }
            }
        }
        return result
    }

    mutating func set(_ id: UUID, cells: AnchorCells) {
        anchors[id] = cells
    }

    mutating func keepOnly(_ ids: Set<UUID>) {
        anchors = anchors.filter { ids.contains($0.key) }
    }

    static func strips(for walls: [ScanCoverageWall], meshWall: Set<CoverageCell>) -> [ScanCoverageWallStrip] {
        var result: [ScanCoverageWallStrip] = []
        for wall in walls {
            let length = wall.lengthM
            guard length.isFinite, length > 0.01, length < maxWallLengthM else { continue }
            let count = max(1, Int((length / wallStripM).rounded(.up)))
            for index in 0..<count {
                let a = wall.start + (wall.end - wall.start) * (Float(index) / Float(count))
                let b = wall.start + (wall.end - wall.start) * (Float(index + 1) / Float(count))
                result.append(ScanCoverageWallStrip(start: a, end: b, seen: touches(meshWall, from: a, to: b)))
            }
        }
        return result
    }

    static func corners(for walls: [ScanCoverageWall], meshWall: Set<CoverageCell>) -> [ScanCoverageCorner] {
        var groups: [(sum: SIMD2<Float>, count: Int, walls: Set<Int>, directions: [SIMD2<Float>])] = []
        for (wallIndex, wall) in walls.enumerated() {
            let length = wall.lengthM
            guard length.isFinite, length > 0.01, length < maxWallLengthM else { continue }
            let direction = (wall.end - wall.start) / length
            for end in [wall.start, wall.end] {
                var nearest: (index: Int, distance: Float)?
                for (index, group) in groups.enumerated() where !group.walls.contains(wallIndex) {
                    let distance = simd_distance(group.sum / Float(group.count), end)
                    if distance <= cornerJoinM, distance < (nearest?.distance ?? .infinity) {
                        nearest = (index: index, distance: distance)
                    }
                }
                if let index = nearest?.index {
                    groups[index].sum += end
                    groups[index].count += 1
                    groups[index].walls.insert(wallIndex)
                    groups[index].directions.append(direction)
                } else {
                    groups.append((sum: end, count: 1, walls: [wallIndex], directions: [direction]))
                }
            }
        }
        return groups.filter { group in
            guard group.count >= 2 else { return false }
            for i in 0..<group.directions.count {
                for j in (i + 1)..<group.directions.count where abs(simd_dot(group.directions[i], group.directions[j])) < cornerMinTurnCos {
                    return true
                }
            }
            return false
        }.map { group in
            let point = group.sum / Float(group.count)
            return ScanCoverageCorner(point: point, seen: near(meshWall, point, radius: cornerMatchRadiusCells))
        }
    }

    static func near(_ cells: Set<CoverageCell>, _ point: SIMD2<Float>, radius: Int32) -> Bool {
        let base = cell(point)
        for dx in -radius...radius {
            for dz in -radius...radius where cells.contains(CoverageCell(x: base.x + dx, z: base.z + dz)) {
                return true
            }
        }
        return false
    }

    static func touches(_ cells: Set<CoverageCell>, from a: SIMD2<Float>, to b: SIMD2<Float>) -> Bool {
        guard !cells.isEmpty else { return false }
        let samples = max(2, Int((simd_distance(a, b) / cellM).rounded(.up)) + 1)
        var hits = 0
        for index in 0..<samples where near(cells, a + (b - a) * (Float(index) / Float(samples - 1)), radius: wallMatchRadiusCells) {
            hits += 1
        }
        return Double(hits) >= Double(samples) * stripSeenFraction
    }

    func snapshot(cameraTransform: simd_float4x4?, path: [SIMD2<Float>], walls: [ScanCoverageWall] = [], roomAreaM2: Double? = nil, stairs: [ScanCoverageStair] = [], skipFloorNear: [SIMD2<Float>] = []) -> ScanCoverageSnapshot {
        var snapshot = ScanCoverageSnapshot()
        var ceiling: Set<CoverageCell> = []
        var heightSum = 0.0
        var heightCount = 0
        for cells in anchors.values {
            snapshot.floor.formUnion(cells.floor)
            snapshot.wall.formUnion(cells.wall)
            snapshot.furniture.formUnion(cells.furniture)
            ceiling.formUnion(cells.ceiling)
            heightSum += cells.floorHeightSum
            heightCount += cells.floorHeightCount
        }
        var flat: [CoverageCell: Float] = [:]
        for cells in anchors.values {
            flat.merge(cells.flatUnclassified) { min($0, $1) }
        }
        let classifiedFloor = heightCount > 0
        let floorY: Float? = classifiedFloor ? Float(heightSum / Double(heightCount)) : Self.fallbackFloorHeight(Array(flat.values))
        if let floorY {
            for (cell, y) in flat {
                if abs(y - floorY) <= Self.unclassifiedFloorToleranceM {
                    snapshot.floor.insert(cell)
                } else if y - floorY >= Self.fallbackCeilingAboveFloorM {
                    ceiling.insert(cell)
                }
            }
        }
        snapshot.ceilingSeen = !ceiling.isEmpty
        let earlierWall = contextWall(floorY: floorY)
        snapshot.stairs = stairs.reduce(into: Set<CoverageCell>()) { $0.formUnion($1.cells()) }
        snapshot.missing = ceiling.subtracting(snapshot.floor).subtracting(snapshot.wall).subtracting(snapshot.furniture).subtracting(earlierWall).subtracting(snapshot.stairs)
        let stairsM2 = stairs.reduce(0) { $0 + $1.areaM2 }
        let floorUnderCeiling = ceiling.subtracting(snapshot.wall).subtracting(earlierWall).subtracting(snapshot.stairs)
        snapshot.floorPercent = Self.floorPercent(
            seenCells: snapshot.floor.union(snapshot.furniture).subtracting(snapshot.stairs).count,
            missingCells: snapshot.missing.count,
            ceilingSeen: snapshot.ceilingSeen,
            roomAreaM2: roomAreaM2.map { $0 - stairsM2 },
            seenUnderCeilingCells: floorUnderCeiling.intersection(snapshot.floor.union(snapshot.furniture)).count,
            floorUnderCeilingCells: floorUnderCeiling.count
        )
        let matchWall = snapshot.wall.union(earlierWall)
        snapshot.wallStrips = Self.strips(for: walls, meshWall: matchWall)
        snapshot.corners = Self.corners(for: walls, meshWall: matchWall)
        snapshot.path = path
        if let cameraTransform {
            let cameraPose = Self.pose(cameraTransform)
            snapshot.camera = cameraPose.position
            snapshot.cameraForward = cameraPose.forward
            snapshot.hint = Self.bestHint(snapshot, skipFloorNear: skipFloorNear)
        }
        return snapshot
    }

    static func bestHint(_ snapshot: ScanCoverageSnapshot, skipFloorNear: [SIMD2<Float>]) -> ScanCoverageHint? {
        guard let camera = snapshot.camera else { return nil }
        return hint(missing: snapshot.missing, camera: camera, forward: snapshot.cameraForward, skipNear: skipFloorNear)
            ?? cornerHint(snapshot.corners, camera: camera, forward: snapshot.cameraForward)
            ?? wallHint(snapshot.wallStrips, camera: camera, forward: snapshot.cameraForward)
    }

    static func pose(_ transform: simd_float4x4) -> (position: SIMD2<Float>, forward: SIMD2<Float>?) {
        let position = SIMD2<Float>(transform.columns.3.x, transform.columns.3.z)
        let back = SIMD2<Float>(transform.columns.2.x, transform.columns.2.z)
        return (position, simd_length(back) > 0.01 ? -simd_normalize(back) : nil)
    }

    static func moved(_ snapshot: ScanCoverageSnapshot, to transform: simd_float4x4) -> ScanCoverageSnapshot {
        var result = snapshot
        let cameraPose = Self.pose(transform)
        result.camera = cameraPose.position
        result.cameraForward = cameraPose.forward
        if let hint = snapshot.hint {
            if let forward = cameraPose.forward {
                result.hint = ScanCoverageHint(target: hint.target, direction: direction(to: hint.center, camera: cameraPose.position, forward: forward), distanceM: simd_distance(hint.center, cameraPose.position), center: hint.center, cells: hint.cells)
            } else {
                result.hint = nil
            }
        }
        return result
    }

    static func floorPercent(seenCells: Int, missingCells: Int, ceilingSeen: Bool, roomAreaM2: Double?, seenUnderCeilingCells: Int = 0, floorUnderCeilingCells: Int = 0) -> Double? {
        let underCeiling = ceilingSeen ? Double(seenCells + missingCells) : 0
        let area = roomAreaM2 ?? 0
        let room = area.isFinite && area > 0 ? area / cellAreaM2 : 0
        let total = underCeiling > 0 && underCeiling >= room * roomAreaTrustFraction ? underCeiling : max(underCeiling, room)
        guard total > 0 else { return nil }
        var percent = min(100, Double(seenCells) / total * 100)
        if ceilingSeen, floorUnderCeilingCells > 0, Double(floorUnderCeilingCells) >= room * underCeilingFloorFraction {
            let scanned = Double(min(seenUnderCeilingCells, floorUnderCeilingCells)) / Double(floorUnderCeilingCells) * 100
            percent = max(percent, scanned)
        }
        return percent
    }

    static func fallbackFloorHeight(_ heights: [Float]) -> Float? {
        guard heights.count >= fallbackFloorMinCells else { return nil }
        let sorted = heights.sorted()
        return sorted[sorted.count * 5 / 100]
    }

    static func largestCluster(_ cells: Set<CoverageCell>) -> [CoverageCell] {
        clusters(cells).first ?? []
    }

    static func clusters(_ cells: Set<CoverageCell>) -> [[CoverageCell]] {
        var remaining = cells
        var found: [(cells: [CoverageCell], first: CoverageCell)] = []
        while let start = remaining.first {
            remaining.remove(start)
            var cluster = [start]
            var index = 0
            while index < cluster.count {
                let current = cluster[index]
                index += 1
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let next = CoverageCell(x: current.x + Int32(dx), z: current.z + Int32(dz))
                    if remaining.remove(next) != nil {
                        cluster.append(next)
                    }
                }
            }
            let first = cluster.min(by: lessCell) ?? start
            found.append((cells: cluster, first: first))
        }
        return found
            .sorted { $0.cells.count != $1.cells.count ? $0.cells.count > $1.cells.count : lessCell($0.first, $1.first) }
            .map { $0.cells }
    }

    static func lessCell(_ a: CoverageCell, _ b: CoverageCell) -> Bool {
        a.x != b.x ? a.x < b.x : a.z < b.z
    }

    static func direction(to target: SIMD2<Float>, camera: SIMD2<Float>, forward: SIMD2<Float>) -> ScanCoverageHint.Direction {
        let right = SIMD2<Float>(-forward.y, forward.x)
        let toTarget = target - camera
        let ahead = simd_dot(toTarget, forward)
        let side = simd_dot(toTarget, right)
        if ahead >= abs(side) { return .ahead }
        if -ahead >= abs(side) { return .behind }
        return side > 0 ? .right : .left
    }

    static func cornerHint(_ corners: [ScanCoverageCorner], camera: SIMD2<Float>, forward: SIMD2<Float>?) -> ScanCoverageHint? {
        guard let forward,
              let target = corners.filter({ !$0.seen }).min(by: { simd_distance($0.point, camera) < simd_distance($1.point, camera) }) else { return nil }
        return ScanCoverageHint(target: .corner, direction: direction(to: target.point, camera: camera, forward: forward), distanceM: simd_distance(target.point, camera), center: target.point)
    }

    static func wallHint(_ strips: [ScanCoverageWallStrip], camera: SIMD2<Float>, forward: SIMD2<Float>?) -> ScanCoverageHint? {
        guard let forward else { return nil }
        let targets = strips.filter { !$0.seen }.map { ($0.start + $0.end) / 2 }
        guard let target = targets.min(by: { simd_distance($0, camera) < simd_distance($1, camera) }) else { return nil }
        return ScanCoverageHint(target: .wall, direction: direction(to: target, camera: camera, forward: forward), distanceM: simd_distance(target, camera), center: target)
    }

    static func hint(missing: Set<CoverageCell>, camera: SIMD2<Float>, forward: SIMD2<Float>?, skipNear: [SIMD2<Float>] = []) -> ScanCoverageHint? {
        guard let forward, missing.count >= hintMinCells else { return nil }
        for cluster in clusters(missing) {
            guard cluster.count >= hintMinCells else { return nil }
            let target = cluster.reduce(SIMD2<Float>(0, 0)) { $0 + center($1) } / Float(cluster.count)
            if skipNear.contains(where: { simd_distance($0, target) <= floorHintSkipM }) { continue }
            return ScanCoverageHint(direction: direction(to: target, camera: camera, forward: forward), distanceM: simd_distance(target, camera), center: target, cells: cluster.count)
        }
        return nil
    }
}

struct LidarLiveCoverage: Codable, Equatable {
    var cellM: Double
    var floorSeenM2: Double
    var floorMissingM2: Double
    var floorPercent: Double?
    var wallCells: Int
    var furnitureCells: Int
    var wallSeenPercent: Double?
    var wallMissingM: Double?
    var cornersSeen: Int?
    var cornersTotal: Int?
    var ceilingSeen: Bool?

    enum CodingKeys: String, CodingKey {
        case cellM = "cell_m"
        case floorSeenM2 = "floor_seen_m2"
        case floorMissingM2 = "floor_missing_under_ceiling_m2"
        case floorPercent = "floor_percent"
        case wallCells = "wall_cells"
        case furnitureCells = "furniture_cells"
        case wallSeenPercent = "wall_seen_percent"
        case wallMissingM = "wall_missing_m"
        case cornersSeen = "corners_seen"
        case cornersTotal = "corners_total"
        case ceilingSeen = "ceiling_seen"
    }

    init(_ snapshot: ScanCoverageSnapshot) {
        cellM = Double(ScanCoverageGrid.cellM)
        floorSeenM2 = snapshot.floorSeenM2
        floorMissingM2 = snapshot.floorMissingM2
        floorPercent = snapshot.floorPercent
        wallCells = snapshot.wall.count
        furnitureCells = snapshot.furniture.count
        wallSeenPercent = snapshot.wallPercent
        wallMissingM = snapshot.wallStrips.isEmpty ? nil : snapshot.wallMissingM
        cornersSeen = snapshot.corners.isEmpty ? nil : snapshot.cornersSeen
        cornersTotal = snapshot.corners.isEmpty ? nil : snapshot.corners.count
        ceilingSeen = snapshot.ceilingSeen
    }
}

struct ScanCoverageMeshCopy: Sendable {
    var transform: simd_float4x4
    var vertices: Data
    var vertexStride: Int
    var vertexCount: Int
    var indices: Data
    var bytesPerIndex: Int
    var faceCount: Int
    var classes: Data
    var classStride: Int
    var classCount: Int

    func faces() -> [ScanCoverageFace] {
        guard vertexStride >= 12, bytesPerIndex == 2 || bytesPerIndex == 4, vertexCount >= 0, faceCount >= 0,
              vertices.count >= vertexStride * vertexCount,
              indices.count >= faceCount * 3 * bytesPerIndex,
              classStride >= 1, classes.count >= classStride * classCount else { return [] }
        var result: [ScanCoverageFace] = []
        result.reserveCapacity(faceCount)
        vertices.withUnsafeBytes { vertexBytes in
            indices.withUnsafeBytes { indexBytes in
                classes.withUnsafeBytes { classBytes in
                    func point(_ face: Int, _ corner: Int) -> SIMD3<Float>? {
                        let byteOffset = (face * 3 + corner) * bytesPerIndex
                        let index = bytesPerIndex == 4
                            ? Int(indexBytes.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self))
                            : Int(indexBytes.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
                        guard index < vertexCount else { return nil }
                        let base = index * vertexStride
                        let world = transform * SIMD4<Float>(
                            vertexBytes.loadUnaligned(fromByteOffset: base, as: Float.self),
                            vertexBytes.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                            vertexBytes.loadUnaligned(fromByteOffset: base + 8, as: Float.self),
                            1
                        )
                        return SIMD3<Float>(world.x, world.y, world.z)
                    }
                    for face in 0..<faceCount {
                        guard let a = point(face, 0), let b = point(face, 1), let c = point(face, 2) else { continue }
                        let normal = simd_cross(b - a, c - a)
                        let length = simd_length(normal)
                        let normalY = length > 0 ? normal.y / length : 0
                        let classValue: UInt8 = face < classCount ? classBytes.loadUnaligned(fromByteOffset: face * classStride, as: UInt8.self) : 0
                        let center = (a + b + c) / 3
                        result.append(ScanCoverageFace(center: center, normalY: normalY, classification: classValue))
                        let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
                        if longest > ScanCoverageGrid.cellM {
                            for corner in [a, b, c] {
                                result.append(ScanCoverageFace(center: corner + (center - corner) * 0.1, normalY: normalY, classification: classValue))
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}

extension ScanCoverageMeshCopy {
    init?(anchor: ARMeshAnchor) {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        guard vertices.format == .float3, vertices.stride >= 12, faces.indexCountPerPrimitive == 3,
              faces.bytesPerIndex == 4 || faces.bytesPerIndex == 2 else { return nil }
        let vertexBytes = vertices.stride * vertices.count
        let indexBytes = faces.count * 3 * faces.bytesPerIndex
        guard vertices.offset >= 0, vertices.offset + vertexBytes <= vertices.buffer.length,
              indexBytes <= faces.buffer.length else { return nil }
        var classes = Data()
        var classStride = 1
        var classCount = 0
        if let classification = geometry.classification, classification.format == .uchar, classification.componentsPerVector == 1,
           classification.stride >= 1, classification.offset >= 0,
           classification.offset + classification.stride * classification.count <= classification.buffer.length {
            classes = Data(bytes: classification.buffer.contents().advanced(by: classification.offset), count: classification.stride * classification.count)
            classStride = classification.stride
            classCount = classification.count
        }
        self.init(
            transform: anchor.transform,
            vertices: Data(bytes: vertices.buffer.contents().advanced(by: vertices.offset), count: vertexBytes),
            vertexStride: vertices.stride,
            vertexCount: vertices.count,
            indices: Data(bytes: faces.buffer.contents(), count: indexBytes),
            bytesPerIndex: faces.bytesPerIndex,
            faceCount: faces.count,
            classes: classes,
            classStride: classStride,
            classCount: classCount
        )
    }
}

@MainActor
final class ScanCoverageTracker: ObservableObject {
    static let updateIntervalS: TimeInterval = 0.5
    static let maxFacesPerBatch = 150_000
    static let pathSpacingM: Float = 0.25
    static let maxPathPoints = 2000

    @Published private(set) var snapshot = ScanCoverageSnapshot()
    @Published private(set) var hasMesh = false
    private(set) var summary: LidarLiveCoverage?

    private var grid = ScanCoverageGrid()
    private var anchorKeys: [UUID: AnchorKey] = [:]
    private var earlierRoomKeys: [UUID: AnchorKey] = [:]
    private var path: [SIMD2<Float>] = []
    private var walls: [ScanCoverageWall] = []
    private var roomAreaM2: Double?
    private var stairs: [ScanCoverageStair] = []
    private var floorWatch = ScanCoverageFloorHintWatch()
    private var lastUpdateAt: TimeInterval = -.infinity
    private var rotation = 0
    private var generation = 0
    private var isWorking = false
    private var work: Task<Void, Never>?
    private var latestCamera: simd_float4x4?

    struct AnchorKey: Equatable, Sendable {
        let vertices: Int
        let faces: Int
        let positionMM: SIMD3<Int32>

        init(vertices: Int, faces: Int, position: SIMD3<Float>) {
            self.vertices = vertices
            self.faces = faces
            positionMM = SIMD3<Int32>(Self.millimetres(position.x), Self.millimetres(position.y), Self.millimetres(position.z))
        }

        init(_ anchor: ARMeshAnchor) {
            self.init(
                vertices: anchor.geometry.vertices.count,
                faces: anchor.geometry.faces.count,
                position: SIMD3<Float>(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
            )
        }

        static func millimetres(_ value: Float) -> Int32 {
            guard value.isFinite else { return 0 }
            return Int32(max(-1_000_000_000, min(1_000_000_000, (value * 1000).rounded())))
        }
    }

    private struct Job: Sendable {
        let id: UUID
        let key: AnchorKey
        let mesh: ScanCoverageMeshCopy
    }

    private struct Done: Sendable {
        let id: UUID
        let key: AnchorKey
        let cells: ScanCoverageGrid.AnchorCells
    }

    func startRoom() {
        work?.cancel()
        work = nil
        latestCamera = nil
        generation += 1
        earlierRoomKeys.merge(anchorKeys) { _, latest in latest }
        let earlierWalls = grid.roomContext()
        grid = ScanCoverageGrid()
        grid.contextWalls = earlierWalls
        anchorKeys = [:]
        path = []
        walls = []
        roomAreaM2 = nil
        stairs = []
        floorWatch = ScanCoverageFloorHintWatch()
        lastUpdateAt = -.infinity
        rotation = 0
        isWorking = false
        snapshot = ScanCoverageSnapshot()
        hasMesh = false
        summary = nil
    }

    func updateWalls(_ walls: [ScanCoverageWall], stairs: [ScanCoverageStair] = [], roomAreaM2: Double?) {
        self.walls = walls
        self.stairs = stairs
        self.roomAreaM2 = roomAreaM2
    }

    func finishRoom() -> LidarLiveCoverage? {
        work?.cancel()
        work = nil
        generation += 1
        isWorking = false
        guard hasMesh else { return summary }
        let finished = grid.snapshot(cameraTransform: latestCamera, path: path, walls: walls, roomAreaM2: roomAreaM2, stairs: stairs, skipFloorNear: floorWatch.skipped)
        snapshot = finished
        summary = LidarLiveCoverage(finished)
        return summary
    }

    func ingest(frame: ARFrame, meshAnchors: [ARMeshAnchor]) {
        recordPath(frame)
        latestCamera = frame.camera.transform
        guard !isWorking, frame.timestamp - lastUpdateAt >= Self.updateIntervalS else { return }
        lastUpdateAt = frame.timestamp
        var current: [(anchor: ARMeshAnchor, key: AnchorKey)] = []
        for anchor in meshAnchors {
            let key = AnchorKey(anchor)
            if let earlier = earlierRoomKeys[anchor.identifier] {
                if earlier == key { continue }
                earlierRoomKeys.removeValue(forKey: anchor.identifier)
            }
            current.append((anchor: anchor, key: key))
        }
        let ids = Set(current.map(\.anchor.identifier))
        grid.keepOnly(ids)
        anchorKeys = anchorKeys.filter { ids.contains($0.key) }
        guard !current.isEmpty else {
            if hasMesh {
                hasMesh = false
                snapshot = ScanCoverageSnapshot()
            }
            return
        }
        var unseen: [(anchor: ARMeshAnchor, key: AnchorKey)] = []
        var changed: [(anchor: ARMeshAnchor, key: AnchorKey)] = []
        for item in current {
            if anchorKeys[item.anchor.identifier] == nil {
                unseen.append(item)
            } else if anchorKeys[item.anchor.identifier] != item.key {
                changed.append(item)
            }
        }
        if !changed.isEmpty {
            let start = rotation % changed.count
            changed = Array(changed[start...] + changed[..<start])
        }
        var jobs: [Job] = []
        var facesLeft = Self.maxFacesPerBatch
        for item in unseen + changed {
            if !jobs.isEmpty, item.key.faces > facesLeft { break }
            guard let mesh = ScanCoverageMeshCopy(anchor: item.anchor) else {
                grid.set(item.anchor.identifier, cells: ScanCoverageGrid.AnchorCells())
                anchorKeys[item.anchor.identifier] = item.key
                continue
            }
            jobs.append(Job(id: item.anchor.identifier, key: item.key, mesh: mesh))
            facesLeft -= item.key.faces
        }
        let base = grid
        let walls = walls
        let roomAreaM2 = roomAreaM2
        let stairs = stairs
        let skipFloorNear = floorWatch.skipped
        let path = path
        let transform = frame.camera.transform
        let generation = generation
        isWorking = true
        work = Task.detached(priority: .userInitiated) { [weak self] in
            var working = base
            var done: [Done] = []
            for job in jobs {
                if Task.isCancelled { return }
                let cells = ScanCoverageGrid.cells(from: job.mesh.faces())
                working.set(job.id, cells: cells)
                done.append(Done(id: job.id, key: job.key, cells: cells))
            }
            if Task.isCancelled { return }
            let snapshot = working.snapshot(cameraTransform: transform, path: path, walls: walls, roomAreaM2: roomAreaM2, stairs: stairs, skipFloorNear: skipFloorNear)
            await self?.apply(done, snapshot: snapshot, generation: generation)
        }
    }

    private func apply(_ done: [Done], snapshot: ScanCoverageSnapshot, generation: Int) {
        guard generation == self.generation else { return }
        isWorking = false
        work = nil
        for item in done {
            grid.set(item.id, cells: item.cells)
            anchorKeys[item.id] = item.key
        }
        rotation += done.count
        var current = latestCamera.map { ScanCoverageGrid.moved(snapshot, to: $0) } ?? snapshot
        if floorWatch.update(current.hint, at: ProcessInfo.processInfo.systemUptime) {
            current.hint = ScanCoverageGrid.bestHint(current, skipFloorNear: floorWatch.skipped)
        }
        self.snapshot = current
        hasMesh = !current.isEmpty
        summary = hasMesh ? LidarLiveCoverage(current) : summary
    }

    private func recordPath(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let position = SIMD2<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.z)
        if let last = path.last, simd_distance(last, position) < Self.pathSpacingM { return }
        path.append(position)
        if path.count > Self.maxPathPoints {
            path = Self.thinned(path)
        }
    }

    nonisolated static func thinned(_ path: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard let last = path.last else { return path }
        var result = stride(from: 0, to: path.count, by: 2).map { path[$0] }
        if result.last != last { result.append(last) }
        return result
    }
}
