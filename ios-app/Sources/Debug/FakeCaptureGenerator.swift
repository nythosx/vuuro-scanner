
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

    private static let doorHeight = 2.05
    private static let doorWidth = 0.85

    static func random() -> RoomPlanCaptureExport {
        let width = Double.random(in: 2.8...6.5)
        let depth = Double.random(in: 2.6...5.5)
        let type = ["living_room", "kitchen", "bedroom", "bathroom", "dining_room"].randomElement() ?? "bedroom"
        let height = Double.random(in: 2.45...2.75)
        let full = Rect(x0: 0, z0: 0, x1: width, z1: depth)

        var outline = rectCorners(full)
        var furnishArea = full
        if width > 3.6 && depth > 3.4 && Bool.random() {
            let notchW = Double.random(in: 1.0...(width / 2.6))
            let notchD = Double.random(in: 0.9...(depth / 2.6))
            outline = [
                [0, 0, 0],
                [width - notchW, 0, 0],
                [width - notchW, 0, notchD],
                [width, 0, notchD],
                [width, 0, depth],
                [0, 0, depth],
            ]
            furnishArea = Rect(x0: 0, z0: notchD, x1: width, z1: depth)
        }

        let doors = [horizontalOpening("door", z: depth, from: 0.3, to: min(width, 2.2) - 0.3, openingWidth: doorWidth, bottom: 0, top: doorHeight)]
        let windows = [verticalOpening("window", x: 0, from: 0.4, to: depth - 0.4, openingWidth: min(1.4, depth - 1.0), bottom: 0.9, top: 2.1)]
        return export(
            outline: outline,
            height: height,
            doors: doors,
            windows: windows,
            objects: furnish(type, in: furnishArea),
            roomType: type,
            origin: nil
        )
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
        let bottomDepth = Double.random(in: 2.8...4.2)
        let hallZ0 = topDepth
        let bottomZ0 = topDepth + hallDepth
        let totalDepth = bottomZ0 + (bottomCount > 0 ? bottomDepth : 0)
        let height = Double.random(in: 2.5...2.7)
        let offsetX = Double.random(in: -3...3)
        let offsetZ = Double.random(in: -3...3)

        var types = ["kitchen", "bedroom", "bathroom", "bedroom", "dining_room", "bedroom", "bathroom"].shuffled()
        types.insert("living_room", at: 0)
        var typeIndex = 0
        func nextType() -> String {
            defer { typeIndex += 1 }
            return types[typeIndex % types.count]
        }

        var exports: [RoomPlanCaptureExport] = []

        for rect in partition(x0: 0, x1: totalWidth, z0: 0, z1: topDepth, count: topCount) {
            let type = nextType()
            let doorZ = rect.z1
            let doors = [horizontalOpening("door", z: doorZ, from: rect.x0 + 0.3, to: rect.x1 - 0.3, openingWidth: doorWidth, bottom: 0, top: doorHeight)]
            let windows = exteriorWindows(z: 0, rect: rect, type: type)
            exports.append(export(
                outline: rectCorners(rect),
                height: height,
                doors: doors,
                windows: windows,
                objects: furnish(type, in: rect, startOnFarWall: false),
                roomType: type,
                origin: nil
            ))
        }

        if hasHallway {
            let hall = Rect(x0: 0, z0: hallZ0, x1: totalWidth, z1: bottomZ0)
            let frontDoor = verticalOpening("door", x: 0, from: hall.z0, to: hall.z1, openingWidth: min(0.95, hall.depth - 0.2), bottom: 0, top: doorHeight)
            let storage = Item(category: "storage", size: [1.0, 2.1, 0.45])
            let hallObjects = [object(storage, x: totalWidth - 0.6, z: hall.z1 - 0.25, yaw: 0)]
            exports.append(export(
                outline: rectCorners(hall),
                height: height,
                doors: [frontDoor],
                windows: [],
                objects: hallObjects,
                roomType: nil,
                origin: nil
            ))
        }

        if bottomCount > 0 {
            for rect in partition(x0: 0, x1: totalWidth, z0: bottomZ0, z1: totalDepth, count: bottomCount) {
                let type = nextType()
                let doors = [horizontalOpening("door", z: rect.z0, from: rect.x0 + 0.3, to: rect.x1 - 0.3, openingWidth: doorWidth, bottom: 0, top: doorHeight)]
                let windows = exteriorWindows(z: totalDepth, rect: rect, type: type)
                exports.append(export(
                    outline: rectCorners(rect),
                    height: height,
                    doors: doors,
                    windows: windows,
                    objects: furnish(type, in: rect),
                    roomType: type,
                    origin: nil
                ))
            }
        }

        return exports.map { shifted($0, dx: offsetX, dz: offsetZ) }
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

    private static func exteriorWindows(z: Double, rect: Rect, type: String) -> [Surface] {
        if type == "bathroom" {
            return [horizontalOpening("window", z: z, from: rect.x0 + 0.3, to: rect.x1 - 0.3, openingWidth: 0.6, bottom: 1.5, top: 2.1)]
        }
        if rect.width > 3.6 {
            let middle = (rect.x0 + rect.x1) / 2
            return [
                horizontalOpening("window", z: z, from: rect.x0 + 0.4, to: middle - 0.2, openingWidth: 1.2, bottom: 0.9, top: 2.2),
                horizontalOpening("window", z: z, from: middle + 0.2, to: rect.x1 - 0.4, openingWidth: 1.2, bottom: 0.9, top: 2.2),
            ]
        }
        return [horizontalOpening("window", z: z, from: rect.x0 + 0.4, to: rect.x1 - 0.4, openingWidth: min(1.5, rect.width - 1.0), bottom: 0.9, top: 2.2)]
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

    private static func rectCorners(_ rect: Rect) -> [[Double]] {
        [[rect.x0, 0, rect.z0], [rect.x1, 0, rect.z0], [rect.x1, 0, rect.z1], [rect.x0, 0, rect.z1]]
    }

    private static func export(outline: [[Double]], height: Double, doors: [Surface], windows: [Surface], objects: [Surface], roomType: String?, origin: [Double]?) -> RoomPlanCaptureExport {
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
            doors: doors,
            windows: windows,
            openings: [],
            objects: objects
        )
        if let roomType {
            result.roomType = RoomPlanCaptureExport.RoomTypeExport(guess: roomType, guessSource: "object_heuristic", confirmed: roomType)
        }
        result.structureOriginM = origin
        return result
    }

    private static func shifted(_ export: RoomPlanCaptureExport, dx: Double, dz: Double) -> RoomPlanCaptureExport {
        func move(_ surfaces: [Surface]) -> [Surface] {
            surfaces.map { surface in
                var copy = surface
                copy.polygonCorners = surface.polygonCorners?.map { [$0[0] + dx, $0[1], $0[2] + dz] }
                copy.position = surface.position.map { [$0[0] + dx, $0[1], $0[2] + dz] }
                return copy
            }
        }
        var result = RoomPlanCaptureExport(
            story: export.story,
            floors: move(export.floors),
            walls: move(export.walls),
            doors: move(export.doors),
            windows: move(export.windows),
            openings: move(export.openings),
            objects: move(export.objects)
        )
        result.roomType = export.roomType
        let corners = result.floors.compactMap { $0.polygonCorners }.flatMap { $0 }
        if let minX = corners.map({ $0[0] }).min(), let minZ = corners.map({ $0[2] }).min() {
            result.structureOriginM = [minX, minZ]
        }
        return result
    }

    private static func randomConfidence() -> String {
        ["high", "high", "medium", "low"].randomElement() ?? "high"
    }
}
#endif
