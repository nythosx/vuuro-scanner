
#if DEBUG
import Foundation

enum FakeCaptureGenerator {
    typealias Surface = RoomPlanCaptureExport.SurfaceExport

    private struct Rect {
        let x0: Double
        let z0: Double
        let x1: Double
        let z1: Double

        var width: Double { x1 - x0 }
        var depth: Double { z1 - z0 }
    }

    private struct Item {
        let category: String
        let size: [Double]
    }

    private struct PlannedRoom {
        var outline: [[Double]]
        var doors: [Surface]
        var windows: [Surface]
        var objects: [Surface]
        var roomType: String?
    }

    private struct Placement {
        let angle: Double
        let dx: Double
        let dz: Double
        let seed: Double

        func jittered(_ point: [Double]) -> [Double] {
            let x = (point[0] * 1000).rounded() / 1000
            let z = (point[1] * 1000).rounded() / 1000
            return [x + noise(x, z, 12.9898), z + noise(x, z, 78.233)]
        }

        func noise(_ x: Double, _ z: Double, _ salt: Double) -> Double {
            let value = sin(x * salt + z * (salt / 3.1) + seed) * 43758.5453
            return (value - value.rounded(.down) - 0.5) * 0.05
        }

        func apply(x: Double, z: Double) -> (Double, Double) {
            let c = cos(angle)
            let s = sin(angle)
            return (x * c - z * s + dx, x * s + z * c + dz)
        }
    }

    private struct Drift {
        let angle: Double
        let dx: Double
        let dz: Double
        let cx: Double
        let cz: Double

        static let none = Drift(angle: 0, dx: 0, dz: 0, cx: 0, cz: 0)

        static func random(around outline: [[Double]]) -> Drift {
            let count = Double(max(outline.count, 1))
            return Drift(
                angle: Double.random(in: -1.5...1.5) * Double.pi / 180,
                dx: Double.random(in: -0.12...0.12),
                dz: Double.random(in: -0.12...0.12),
                cx: outline.reduce(0.0) { $0 + $1[0] } / count,
                cz: outline.reduce(0.0) { $0 + $1[1] } / count
            )
        }

        func apply(x: Double, z: Double) -> (Double, Double) {
            let c = cos(angle)
            let s = sin(angle)
            let lx = x - cx
            let lz = z - cz
            return (lx * c - lz * s + cx + dx, lx * s + lz * c + cz + dz)
        }
    }

    private static let doorHeight = 2.05
    private static let doorWidth = 0.85

    static func random() -> RoomPlanCaptureExport {
        let width = Double.random(in: 2.8...6.5)
        let depth = Double.random(in: 2.6...5.5)
        let type = ["living_room", "kitchen", "bedroom", "bathroom", "dining_room"].randomElement() ?? "bedroom"
        let height = Double.random(in: 2.45...2.75)
        let full = Rect(x0: 0, z0: 0, x1: width, z1: depth)

        var outline = rectOutline(full)
        var furnishArea = full
        var windows = [verticalOpening("window", x: 0, from: 0.4, to: depth - 0.4, openingWidth: min(1.4, depth - 1.0), bottom: 0.9, top: 2.1)]
        switch Int.random(in: 0...3) {
        case 1 where width > 3.6 && depth > 3.4:
            let notchW = Double.random(in: 1.0...(width / 2.6))
            let notchD = Double.random(in: 0.9...(depth / 2.6))
            outline = [[0, 0], [width - notchW, 0], [width - notchW, notchD], [width, notchD], [width, depth], [0, depth]]
            furnishArea = Rect(x0: 0, z0: notchD, x1: width, z1: depth)
        case 2 where width > 3.0 && depth > 3.0:
            let cut = Double.random(in: 0.7...1.1)
            outline = [[0, 0], [width - cut, 0], [width, cut], [width, depth], [0, depth]]
        case 3 where width > 3.2:
            let bayStart = width * 0.3
            let bayEnd = bayStart + min(2.0, width * 0.45)
            let bayDepth = Double.random(in: 0.5...0.8)
            outline = [[0, 0], [bayStart, 0], [bayStart, -bayDepth], [bayEnd, -bayDepth], [bayEnd, 0], [width, 0], [width, depth], [0, depth]]
            windows.append(horizontalOpening("window", z: -bayDepth, from: bayStart + 0.2, to: bayEnd - 0.2, openingWidth: min(1.4, bayEnd - bayStart - 0.4), bottom: 0.9, top: 2.2))
        default:
            break
        }

        let room = PlannedRoom(
            outline: outline,
            doors: [horizontalOpening("door", z: depth, from: 0.3, to: min(width, 2.2) - 0.3, openingWidth: doorWidth, bottom: 0, top: doorHeight)],
            windows: windows,
            objects: furnish(type, in: furnishArea),
            roomType: type
        )
        let placement = Placement(angle: 0, dx: 0, dz: 0, seed: Double.random(in: 0...1000))
        var result = finalize(room, height: height, placement: placement)
        result.structureOriginM = nil
        return result
    }

    static func unit(roomCount: Int) -> [RoomPlanCaptureExport] {
        let count = min(max(roomCount, 2), 8)
        let hasHallway = count >= 4
        let sideRooms = hasHallway ? count - 1 : count
        let topCount = (sideRooms + 1) / 2
        let bottomCount = sideRooms / 2

        let totalWidth = Double(topCount) * Double.random(in: 3.2...4.4)
        let topDepth = Double.random(in: 3.4...4.8)
        let hallDepth = hasHallway ? Double.random(in: 1.1...1.5) : 0
        let bottomDepth = Double.random(in: 3.0...4.2)
        let hallZ0 = topDepth
        let bottomZ0 = topDepth + hallDepth
        let totalDepth = bottomZ0 + (bottomCount > 0 ? bottomDepth : 0)
        let height = Double.random(in: 2.5...2.7)

        var types = ["kitchen", "bedroom", "bathroom", "bedroom", "dining_room", "bedroom", "bathroom"].shuffled()
        types.insert("living_room", at: 0)
        var typeIndex = 0
        func nextType() -> String {
            defer { typeIndex += 1 }
            return types[typeIndex % types.count]
        }

        var rooms: [PlannedRoom] = []

        let topRects = partition(x0: 0, x1: totalWidth, z0: 0, z1: topDepth, count: topCount)
        for (index, rect) in topRects.enumerated() {
            let type = nextType()
            var outline = rectOutline(rect)
            var windows = exteriorWindows(z: 0, x0: rect.x0, x1: rect.x1, type: type)
            if type == "living_room" && rect.width > 3.2 && Double.random(in: 0...1) < 0.7 {
                let bayStart = rect.x0 + rect.width * 0.25
                let bayEnd = bayStart + min(2.2, rect.width * 0.5)
                let bayDepth = Double.random(in: 0.5...0.8)
                outline = [[rect.x0, 0], [bayStart, 0], [bayStart, -bayDepth], [bayEnd, -bayDepth], [bayEnd, 0], [rect.x1, 0], [rect.x1, rect.z1], [rect.x0, rect.z1]]
                windows = [horizontalOpening("window", z: -bayDepth, from: bayStart + 0.2, to: bayEnd - 0.2, openingWidth: min(1.6, bayEnd - bayStart - 0.4), bottom: 0.8, top: 2.2)]
            } else if index == topRects.count - 1 && topCount > 1 && rect.width > 2.8 && Bool.random() {
                let cut = Double.random(in: 0.8...1.2)
                outline = [[rect.x0, 0], [rect.x1 - cut, 0], [rect.x1, cut], [rect.x1, rect.z1], [rect.x0, rect.z1]]
                windows = exteriorWindows(z: 0, x0: rect.x0, x1: rect.x1 - cut, type: type)
            }
            rooms.append(PlannedRoom(
                outline: outline,
                doors: [horizontalOpening("door", z: rect.z1, from: rect.x0 + 0.3, to: rect.x1 - 0.3, openingWidth: doorWidth, bottom: 0, top: doorHeight)],
                windows: windows,
                objects: furnish(type, in: rect, startOnFarWall: false),
                roomType: type
            ))
        }

        let bottomRects = bottomCount > 0 ? partition(x0: 0, x1: totalWidth, z0: bottomZ0, z1: totalDepth, count: bottomCount) : []
        var closet: (x0: Double, x1: Double, depth: Double, roomIndex: Int)?
        if hasHallway {
            for (index, rect) in bottomRects.enumerated() where closet == nil && rect.width > 3.0 && rect.depth > 3.0 {
                let width = Double.random(in: 0.9...1.2)
                let start = rect.x0 + Double.random(in: 0.3...0.6)
                closet = (start, start + width, Double.random(in: 0.6...0.9), index)
            }
        }

        if hasHallway {
            let hall = Rect(x0: 0, z0: hallZ0, x1: totalWidth, z1: bottomZ0)
            var outline = rectOutline(hall)
            var hallObjects = [object(Item(category: "storage", size: [1.0, 2.1, 0.45]), x: totalWidth - 0.6, z: hall.z1 - 0.25, yaw: 0)]
            if let closet {
                outline = [[0, hall.z0], [totalWidth, hall.z0], [totalWidth, hall.z1], [closet.x1, hall.z1], [closet.x1, hall.z1 + closet.depth], [closet.x0, hall.z1 + closet.depth], [closet.x0, hall.z1], [0, hall.z1]]
                hallObjects = [object(Item(category: "storage", size: [closet.x1 - closet.x0 - 0.1, 2.1, closet.depth - 0.1]), x: (closet.x0 + closet.x1) / 2, z: hall.z1 + closet.depth / 2, yaw: 0)]
            }
            let frontDoor = verticalOpening("door", x: 0, from: hall.z0, to: hall.z1, openingWidth: min(0.95, hall.depth - 0.2), bottom: 0, top: doorHeight)
            rooms.append(PlannedRoom(outline: outline, doors: [frontDoor], windows: [], objects: hallObjects, roomType: nil))
        }

        for (index, rect) in bottomRects.enumerated() {
            let type = nextType()
            var outline = rectOutline(rect)
            var furnishArea = rect
            var doorFrom = rect.x0 + 0.3
            if let closet, closet.roomIndex == index {
                outline = [[rect.x0, rect.z0], [closet.x0, rect.z0], [closet.x0, rect.z0 + closet.depth], [closet.x1, rect.z0 + closet.depth], [closet.x1, rect.z0], [rect.x1, rect.z0], [rect.x1, rect.z1], [rect.x0, rect.z1]]
                furnishArea = Rect(x0: rect.x0, z0: rect.z0 + closet.depth, x1: rect.x1, z1: rect.z1)
                doorFrom = closet.x1 + 0.2
            }
            rooms.append(PlannedRoom(
                outline: outline,
                doors: [horizontalOpening("door", z: rect.z0, from: doorFrom, to: rect.x1 - 0.3, openingWidth: doorWidth, bottom: 0, top: doorHeight)],
                windows: exteriorWindows(z: totalDepth, x0: rect.x0, x1: rect.x1, type: type),
                objects: furnish(type, in: furnishArea),
                roomType: type
            ))
        }

        let placement = Placement(
            angle: Double.random(in: -15...15) * Double.pi / 180,
            dx: Double.random(in: -3...3),
            dz: Double.random(in: -3...3),
            seed: Double.random(in: 0...1000)
        )
        return rooms.map { finalize($0, height: height, placement: placement, drift: Drift.random(around: $0.outline)) }
    }

    private static func partition(x0: Double, x1: Double, z0: Double, z1: Double, count: Int) -> [Rect] {
        let weights = (0..<count).map { _ in Double.random(in: 0.8...1.3) }
        let total = weights.reduce(0, +)
        var rects: [Rect] = []
        var cursor = x0
        for (index, weight) in weights.enumerated() {
            let end = index == count - 1 ? x1 : cursor + (x1 - x0) * weight / total
            rects.append(Rect(x0: cursor, z0: z0, x1: end, z1: z1))
            cursor = end
        }
        return rects
    }

    private static func exteriorWindows(z: Double, x0: Double, x1: Double, type: String) -> [Surface] {
        let width = x1 - x0
        if type == "bathroom" {
            return [horizontalOpening("window", z: z, from: x0 + 0.3, to: x1 - 0.3, openingWidth: 0.6, bottom: 1.5, top: 2.1)]
        }
        if width > 3.6 {
            let middle = (x0 + x1) / 2
            return [
                horizontalOpening("window", z: z, from: x0 + 0.4, to: middle - 0.2, openingWidth: 1.2, bottom: 0.9, top: 2.2),
                horizontalOpening("window", z: z, from: middle + 0.2, to: x1 - 0.4, openingWidth: 1.2, bottom: 0.9, top: 2.2),
            ]
        }
        return [horizontalOpening("window", z: z, from: x0 + 0.4, to: x1 - 0.4, openingWidth: max(0.6, min(1.5, width - 1.0)), bottom: 0.9, top: 2.2)]
    }

    private static func items(for type: String) -> (wall: [Item], center: [Item]) {
        switch type {
        case "living_room":
            return (
                [Item(category: "sofa", size: [2.1, 0.85, 0.9]), Item(category: "television", size: [1.3, 0.7, 0.35]), Item(category: "storage", size: [1.2, 0.9, 0.45])],
                [Item(category: "table", size: [1.1, 0.45, 0.6])]
            )
        case "kitchen":
            return (
                [Item(category: "refrigerator", size: [0.7, 1.85, 0.7]), Item(category: "sink", size: [0.8, 0.9, 0.6]), Item(category: "stove", size: [0.6, 0.9, 0.6]), Item(category: "dishwasher", size: [0.6, 0.85, 0.6]), Item(category: "oven", size: [0.6, 0.9, 0.6])],
                [Item(category: "table", size: [1.0, 0.75, 0.8])]
            )
        case "bedroom":
            return (
                [Item(category: "bed", size: [1.6, 0.55, 2.0]), Item(category: "storage", size: [1.4, 2.1, 0.6])],
                []
            )
        case "bathroom":
            return (
                [Item(category: "bathtub", size: [1.7, 0.6, 0.75]), Item(category: "toilet", size: [0.4, 0.8, 0.7]), Item(category: "sink", size: [0.6, 0.85, 0.5]), Item(category: "washerDryer", size: [0.6, 0.85, 0.6])],
                []
            )
        case "dining_room":
            return (
                [Item(category: "storage", size: [1.6, 0.9, 0.45]), Item(category: "chair", size: [0.5, 0.9, 0.5])],
                [Item(category: "table", size: [1.8, 0.75, 0.9])]
            )
        default:
            return ([Item(category: "storage", size: [1.0, 2.0, 0.5])], [])
        }
    }

    private static func furnish(_ type: String, in rect: Rect, startOnFarWall: Bool = true) -> [Surface] {
        let plan = items(for: type)
        var result: [Surface] = []
        var cursor = rect.x0 + 0.15
        var onFarWall = startOnFarWall
        var switched = false
        for item in plan.wall {
            let width = item.size[0]
            let depth = item.size[2]
            if cursor + width > rect.x1 - 0.15 {
                guard !switched else { break }
                switched = true
                onFarWall.toggle()
                cursor = rect.x0 + 0.15
                if cursor + width > rect.x1 - 0.15 { break }
            }
            if depth + 0.8 > rect.depth { continue }
            let x = cursor + width / 2
            let z = onFarWall ? rect.z1 - depth / 2 - 0.05 : rect.z0 + depth / 2 + 0.05
            result.append(object(item, x: x, z: z, yaw: onFarWall ? 0 : 180))
            cursor += width + 0.2
        }
        for item in plan.center where item.size[0] + 1.2 < rect.width && item.size[2] + 1.6 < rect.depth {
            result.append(object(item, x: (rect.x0 + rect.x1) / 2, z: (rect.z0 + rect.z1) / 2, yaw: 0))
        }
        return result
    }

    private static func object(_ item: Item, x: Double, z: Double, yaw: Double) -> Surface {
        var surface = Surface(
            identifier: UUID().uuidString,
            category: item.category,
            confidence: randomConfidence(),
            dimensions: item.size,
            position: [x, item.size[1] / 2, z]
        )
        surface.yawDeg = yaw
        return surface
    }

    private static func horizontalOpening(_ category: String, z: Double, from: Double, to: Double, openingWidth: Double, bottom: Double, top: Double) -> Surface {
        let span = max(to - from, openingWidth)
        let start = from + Double.random(in: 0...max(span - openingWidth, 0))
        let end = start + openingWidth
        return Surface(
            identifier: UUID().uuidString,
            category: category,
            confidence: randomConfidence(),
            dimensions: [openingWidth, top - bottom, 0.1],
            polygonCorners: [[start, bottom, z], [end, bottom, z], [end, top, z], [start, top, z]]
        )
    }

    private static func verticalOpening(_ category: String, x: Double, from: Double, to: Double, openingWidth: Double, bottom: Double, top: Double) -> Surface {
        let span = max(to - from, openingWidth)
        let start = from + Double.random(in: 0...max(span - openingWidth, 0))
        let end = start + openingWidth
        return Surface(
            identifier: UUID().uuidString,
            category: category,
            confidence: randomConfidence(),
            dimensions: [openingWidth, top - bottom, 0.1],
            polygonCorners: [[x, bottom, start], [x, bottom, end], [x, top, end], [x, top, start]]
        )
    }

    private static func rectOutline(_ rect: Rect) -> [[Double]] {
        [[rect.x0, rect.z0], [rect.x1, rect.z0], [rect.x1, rect.z1], [rect.x0, rect.z1]]
    }

    private static let halfWallThickness = 0.06

    private static func inset(_ polygon: [[Double]], by distance: Double) -> [[Double]] {
        let count = polygon.count
        guard count >= 3 else { return polygon }
        var twiceArea = 0.0
        for index in 0..<count {
            let a = polygon[index]
            let b = polygon[(index + 1) % count]
            twiceArea += a[0] * b[1] - b[0] * a[1]
        }
        let sign: Double = twiceArea > 0 ? 1 : -1
        var starts: [[Double]] = []
        var directions: [[Double]] = []
        for index in 0..<count {
            let a = polygon[index]
            let b = polygon[(index + 1) % count]
            let ex = b[0] - a[0]
            let ez = b[1] - a[1]
            let length = max((ex * ex + ez * ez).squareRoot(), 1e-9)
            let nx = -ez / length * sign
            let nz = ex / length * sign
            starts.append([a[0] + nx * distance, a[1] + nz * distance])
            directions.append([ex, ez])
        }
        var result: [[Double]] = []
        for index in 0..<count {
            let previous = (index + count - 1) % count
            let p1 = starts[previous]
            let d1 = directions[previous]
            let p2 = starts[index]
            let d2 = directions[index]
            let denominator = d1[0] * d2[1] - d1[1] * d2[0]
            if abs(denominator) < 1e-9 {
                result.append(p2)
                continue
            }
            let t = ((p2[0] - p1[0]) * d2[1] - (p2[1] - p1[1]) * d2[0]) / denominator
            result.append([p1[0] + d1[0] * t, p1[1] + d1[1] * t])
        }
        return result
    }

    private static func finalize(_ room: PlannedRoom, height: Double, placement: Placement, drift: Drift = .none) -> RoomPlanCaptureExport {
        func place(x: Double, z: Double) -> (Double, Double) {
            let drifted = drift.apply(x: x, z: z)
            return placement.apply(x: drifted.0, z: drifted.1)
        }
        let outline: [[Double]] = inset(room.outline, by: halfWallThickness).map { point in
            let jittered = placement.jittered(point)
            let moved = place(x: jittered[0], z: jittered[1])
            return [moved.0, 0, moved.1]
        }
        func move(_ surfaces: [Surface]) -> [Surface] {
            surfaces.map { surface in
                var copy = surface
                copy.polygonCorners = surface.polygonCorners?.map { corner in
                    let moved = place(x: corner[0], z: corner[2])
                    return [moved.0, corner[1], moved.1]
                }
                if let position = surface.position {
                    let moved = place(x: position[0], z: position[2])
                    copy.position = [moved.0, position[1], moved.1]
                }
                if let yaw = surface.yawDeg {
                    let turned = yaw + (placement.angle + drift.angle) * 180 / Double.pi
                    copy.yawDeg = (turned.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                }
                return copy
            }
        }

        let floor = Surface(
            identifier: UUID().uuidString,
            category: "floor",
            confidence: randomConfidence(),
            dimensions: [0, height, 0],
            polygonCorners: outline
        )
        var walls: [Surface] = []
        for index in outline.indices {
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            let length = ((b[0] - a[0]) * (b[0] - a[0]) + (b[2] - a[2]) * (b[2] - a[2])).squareRoot()
            walls.append(Surface(
                identifier: UUID().uuidString,
                category: "wall",
                confidence: randomConfidence(),
                dimensions: [length, height, 0.1],
                polygonCorners: [[a[0], 0, a[2]], [b[0], 0, b[2]], [b[0], height, b[2]], [a[0], height, a[2]]]
            ))
        }
        var result = RoomPlanCaptureExport(
            story: 0,
            floors: [floor],
            walls: walls,
            doors: move(room.doors),
            windows: move(room.windows),
            openings: [],
            objects: move(room.objects)
        )
        if let roomType = room.roomType {
            result.roomType = RoomPlanCaptureExport.RoomTypeExport(guess: roomType, guessSource: "object_heuristic", confirmed: roomType)
        }
        if let minX = outline.map({ $0[0] }).min(), let minZ = outline.map({ $0[2] }).min() {
            result.structureOriginM = [minX, minZ]
        }
        return result
    }

    private static func randomConfidence() -> String {
        ["high", "high", "medium", "low"].randomElement() ?? "high"
    }
}
#endif
