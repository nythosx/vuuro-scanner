import Foundation
import simd

enum DollhouseMode: String, CaseIterable, Identifiable {
    case dollhouse
    case cutaway

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dollhouse: return "Dollhouse"
        case .cutaway: return "Cutaway"
        }
    }
}

struct DollhouseBuildConfiguration {
    var mode: DollhouseMode = .cutaway
    var showFurniture: Bool = true
    var performanceMode: Bool = false
}

enum DollhouseMeshBuilderError: Error, LocalizedError {
    case noRooms
    case emptyGeometry

    var errorDescription: String? {
        switch self {
        case .noRooms: return "This scan has no rooms to show in 3D."
        case .emptyGeometry: return "The captured rooms produced no usable 3D geometry."
        }
    }
}

enum DollhouseConstants {
    static let defaultHeightM: Float = 2.4
    static let cutawayHeightM: Float = 1.2
    static let exteriorWallThicknessM: Float = 0.30
    static let interiorWallThicknessM: Float = 0.12
    static let maxOpeningWallDistanceM: Float = 0.6
    static let minRoomAreaM2: Float = 0.25
    static let largePlanRoomThreshold = 12
    static let sectionVerticalGapM: Float = 1.5
    static let doorHeightM: Float = 2.05
    static let windowHeightM: Float = 1.2
    static let windowSillM: Float = 0.9
    static let otherOpeningHeightM: Float = 1.0
    static let frameDepthM: Float = 0.06
}

enum DollhousePalette {
    static func floorColor(for roomTypeValue: String?) -> SIMD4<Float> {
        switch roomTypeValue {
        case "living_room", "dining_room", "office":
            return SIMD4(0.98, 0.89, 0.78, 1.0)
        case "bedroom", "guest_room":
            return SIMD4(0.95, 0.85, 0.65, 1.0)
        case "kitchen", "bathroom", "laundry_room":
            return SIMD4(0.87, 0.95, 1.0, 1.0)
        case "hallway":
            return SIMD4(0.93, 0.96, 0.82, 1.0)
        case "garage", "storage_room", "basement", "attic":
            return SIMD4(0.91, 0.89, 0.87, 1.0)
        default:
            return SIMD4(0.98, 0.98, 0.98, 1.0)
        }
    }

    static func furnitureColor(for category: String) -> SIMD4<Float> {
        switch category.lowercased() {
        case "bed": return SIMD4(0.56, 0.61, 0.70, 1.0)
        case "sofa", "chair": return SIMD4(0.83, 0.83, 0.83, 1.0)
        case "table", "desk": return SIMD4(1.0, 1.0, 1.0, 1.0)
        case "sink", "toilet", "bathtub", "washerdryer", "washer_dryer": return SIMD4(0.83, 0.83, 0.83, 1.0)
        case "stove", "oven", "refrigerator", "dishwasher", "storage": return SIMD4(0.71, 0.71, 0.71, 1.0)
        case "television", "fireplace": return SIMD4(0.36, 0.36, 0.36, 1.0)
        default: return SIMD4(0.75, 0.75, 0.75, 1.0)
        }
    }
}

struct DollhouseMeshBuilder {

    static func build(rooms: [FloorPlan.Room], configuration: DollhouseBuildConfiguration = DollhouseBuildConfiguration()) throws -> DollhouseScene {
        guard !rooms.isEmpty else { throw DollhouseMeshBuilderError.noRooms }

        let largePlan = rooms.count > DollhouseConstants.largePlanRoomThreshold
        var effectiveConfiguration = configuration
        if largePlan && configuration.performanceMode {
            effectiveConfiguration.showFurniture = false
        }

        var meshes: [DollhouseMesh] = []
        var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var hasGeometry = false
        var usedEstimatedHeight = false

        let sections = makeFloorSections(rooms: rooms)
        var sectionOffsetZ: Float = 0.0
        var sectionSummaries: [DollhouseFloorSection] = []

        for (sectionIndex, section) in sections.enumerated() {
            let sectionOrigin = SIMD3<Float>(0.0, 0.0, sectionOffsetZ - localMinZ(of: section.rooms))
            var sectionMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var sectionMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

            for room in section.rooms {
                let result = buildRoom(room: room, configuration: effectiveConfiguration, sectionOrigin: sectionOrigin)
                if result.estimatedHeight { usedEstimatedHeight = true }
                for mesh in result.meshes where !mesh.isEmpty {
                    meshes.append(mesh)
                    hasGeometry = true
                    for vertex in mesh.vertices {
                        sectionMin = simd_min(sectionMin, vertex.position)
                        sectionMax = simd_max(sectionMax, vertex.position)
                        boundsMin = simd_min(boundsMin, vertex.position)
                        boundsMax = simd_max(boundsMax, vertex.position)
                    }
                }
            }

            sectionSummaries.append(DollhouseFloorSection(
                id: "section-\(sectionIndex)",
                title: section.title,
                roomIds: section.rooms.map(\.roomId),
                originOffset: sectionOrigin
            ))

            if sectionMin.x.isFinite && sectionMax.x.isFinite {
                sectionOffsetZ += (sectionMax.z - sectionMin.z) + DollhouseConstants.sectionVerticalGapM
            }
        }

        guard hasGeometry else { throw DollhouseMeshBuilderError.emptyGeometry }

        return DollhouseScene(
            meshes: meshes,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            roomCount: rooms.count,
            floorSections: sectionSummaries,
            usedEstimatedHeight: usedEstimatedHeight
        )
    }

    private static func localMinZ(of rooms: [FloorPlan.Room]) -> Float {
        var minZ = Float.greatestFiniteMagnitude
        for room in rooms {
            let originZ = Float(room.structureOriginM?.dropFirst().first ?? 0)
            for point in room.outlineM where point.count >= 2 {
                minZ = min(minZ, originZ + Float(point[1]))
            }
        }
        return minZ.isFinite ? minZ : 0
    }

    private struct Section {
        let title: String
        let rooms: [FloorPlan.Room]
    }

    private static func makeFloorSections(rooms: [FloorPlan.Room]) -> [Section] {
        var floorOrder: [String] = []
        var floorTitles: [String: String] = [:]
        var floorBuckets: [String: [FloorPlan.Room]] = [:]
        for room in rooms {
            let rawName = (room.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawName.lowercased()
            if floorBuckets[key] == nil {
                floorOrder.append(key)
                floorTitles[key] = rawName
            }
            floorBuckets[key, default: []].append(room)
        }
        let sortedFloorKeys = floorOrder.enumerated().sorted { lhs, rhs in
            let left = floorTitles[lhs.element] ?? ""
            let right = floorTitles[rhs.element] ?? ""
            if left.isEmpty != right.isEmpty { return right.isEmpty }
            if !left.isEmpty {
                let leftRank = floorRank(left)
                let rightRank = floorRank(right)
                if leftRank != rightRank { return leftRank > rightRank }
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        var sections: [Section] = []
        for floorKey in sortedFloorKeys {
            let floorRooms = floorBuckets[floorKey] ?? []
            let subgroups = subdivideFloor(floorRooms)
            let floorName = floorTitles[floorKey] ?? ""
            if subgroups.count == 1 {
                let title = floorName.isEmpty ? "Floor not set" : floorName
                sections.append(Section(title: title, rooms: subgroups[0]))
                continue
            }
            for (index, subgroup) in subgroups.enumerated() {
                let base = floorName.isEmpty ? "Floor not set" : floorName
                sections.append(Section(title: "\(base) \u{00B7} part \(index + 1)", rooms: subgroup))
            }
        }
        return sections
    }

    private static func subdivideFloor(_ rooms: [FloorPlan.Room]) -> [[FloorPlan.Room]] {
        var order: [String] = []
        var buckets: [String: [FloorPlan.Room]] = [:]
        for room in rooms {
            let key: String
            if let group = room.captureGroupId ?? room.joinedToGroupId {
                key = "group:" + group
            } else if room.structureOriginM != nil {
                key = "fused-ungrouped"
            } else {
                key = "tile:" + room.roomId
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(room)
        }
        return order.map { buckets[$0] ?? [] }
    }

    private static func floorRank(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("attic") || n.contains("zolder") || n.contains("loft") { return 100 }
        if n.contains("basement") || n.contains("kelder") { return -10 }
        if n.contains("ground") || n.contains("begane") || n == "bg" { return 0 }
        if let range = n.range(of: "\\d+", options: .regularExpression), let value = Int(n[range]) { return value }
        if n.contains("first") || n.contains("eerste") { return 1 }
        if n.contains("second") || n.contains("tweede") { return 2 }
        if n.contains("third") || n.contains("derde") { return 3 }
        return 5
    }

    private struct RoomBuildResult {
        let meshes: [DollhouseMesh]
        let estimatedHeight: Bool
    }

    private static func buildRoom(room: FloorPlan.Room, configuration: DollhouseBuildConfiguration, sectionOrigin: SIMD3<Float>) -> RoomBuildResult {
        guard room.outlineM.count >= 3 else { return RoomBuildResult(meshes: [], estimatedHeight: false) }
        let outline = room.outlineM.compactMap { point -> SIMD2<Float>? in
            guard point.count >= 2 else { return nil }
            return SIMD2<Float>(Float(point[0]), Float(point[1]))
        }
        guard outline.count >= 3 else { return RoomBuildResult(meshes: [], estimatedHeight: false) }
        let area = polygonArea(outline)
        guard area >= DollhouseConstants.minRoomAreaM2 else { return RoomBuildResult(meshes: [], estimatedHeight: false) }

        var estimated = false
        let requestedHeight: Float
        if let height = room.heightM, height > 0 {
            requestedHeight = Float(height)
        } else {
            requestedHeight = DollhouseConstants.defaultHeightM
            estimated = true
        }
        let wallHeight: Float = configuration.mode == .cutaway
            ? min(requestedHeight, DollhouseConstants.cutawayHeightM)
            : requestedHeight

        let roomOrigin = SIMD3<Float>(Float(room.structureOriginM?.first ?? 0), 0, Float(room.structureOriginM?.dropFirst().first ?? 0))
        let base = sectionOrigin + roomOrigin

        let roomKey = room.roomId
        let roomPath = DollhouseNodePath(["Scene", "Section", "Room-\(roomKey)"])

        var meshes: [DollhouseMesh] = []

        let typeValue = room.roomType?.confirmed ?? room.roomType?.guess
        let floorColor = DollhousePalette.floorColor(for: typeValue)
        let floorMaterial = DollhouseMaterial.floor(named: "floor-\(roomKey)", color: floorColor)
        let floorMesh = makeFloorMesh(outline: outline, base: base, material: floorMaterial, path: roomPath.appending("Floor"))
        meshes.append(floorMesh)

        let openEdges = Set(room.openEdges)
        let signedArea = outlineSignedArea(outline)
        let isCounterClockwise = signedArea > 0
        for index in outline.indices {
            if openEdges.contains(index) { continue }
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            let direction = b - a
            let length = simd_length(direction)
            if length < 1e-4 { continue }
            let unit = direction / length
            let inwardSign: Float = isCounterClockwise ? 1 : -1
            let inwardNormal2D = SIMD2<Float>(-unit.y * inwardSign, unit.x * inwardSign)
            let mesh = makeWallMesh(a: a, b: b, height: wallHeight, base: base, material: DollhouseMaterial.exteriorWall, path: roomPath.appending("Wall-\(index)"), inwardNormal2D: inwardNormal2D)
            meshes.append(mesh)
        }

        for opening in room.openings {
            guard opening.positionM.count >= 2 else { continue }
            let point = SIMD2<Float>(Float(opening.positionM[0]), Float(opening.positionM[1]))
            guard let (wallA, wallB, distance) = nearestWall(to: point, outline: outline, openEdges: openEdges) else { continue }
            if distance > DollhouseConstants.maxOpeningWallDistanceM { continue }
            let width = max(0.4, min(6.0, openingWidth(opening)))
            let material: DollhouseMaterial
            let heightValue: Float
            let sill: Float
            switch opening.category {
            case "door":
                material = DollhouseMaterial.door
                heightValue = DollhouseConstants.doorHeightM
                sill = 0
            case "window":
                material = DollhouseMaterial.window
                heightValue = min(DollhouseConstants.windowHeightM, max(0.5, requestedHeight - DollhouseConstants.windowSillM))
                sill = DollhouseConstants.windowSillM
            default:
                material = DollhouseMaterial.otherOpening
                heightValue = DollhouseConstants.otherOpeningHeightM
                sill = 0
            }
            if let mesh = makeOpeningFrame(wallA: wallA, wallB: wallB, openingPosition: point, width: width, height: heightValue, sill: sill, base: base, material: material, path: roomPath.appending("Opening-\(opening.openingId)")) {
                meshes.append(mesh)
            }
        }

        if configuration.showFurniture {
            for object in room.objects where !object.excluded {
                guard object.positionM.count >= 2, object.dimensionsM.count >= 3 else { continue }
                let dims = SIMD3<Float>(Float(object.dimensionsM[0]), Float(object.dimensionsM[1]), Float(object.dimensionsM[2]))
                guard dims.x > 0, dims.y > 0, dims.z > 0 else { continue }
                let position = SIMD2<Float>(Float(object.positionM[0]), Float(object.positionM[1]))
                let yaw = Float(object.yawDeg ?? 0) * .pi / 180.0
                let color = DollhousePalette.furnitureColor(for: object.category)
                let material = DollhouseMaterial.furniture(named: "furniture-\(object.category)", color: color)
                let mesh = makeBox(center: SIMD3<Float>(position.x, dims.y / 2, position.y), size: dims, yaw: yaw, base: base, material: material, path: roomPath.appending("Object-\(object.objectId)"))
                meshes.append(mesh)
            }
        }

        return RoomBuildResult(meshes: meshes, estimatedHeight: estimated)
    }

    private static func openingWidth(_ opening: FloorPlan.Opening) -> Float {
        if let widthM = opening.widthM, widthM >= 0.2, widthM <= 6.0 {
            return Float(widthM)
        }
        switch opening.category {
        case "door": return 0.9
        case "window": return 1.2
        default: return 0.8
        }
    }

    private static func nearestWall(to point: SIMD2<Float>, outline: [SIMD2<Float>], openEdges: Set<Int>) -> (SIMD2<Float>, SIMD2<Float>, Float)? {
        var best: (SIMD2<Float>, SIMD2<Float>, Float)?
        for index in outline.indices {
            if openEdges.contains(index) { continue }
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            let distance = distanceToSegment(point, a, b)
            if best == nil || distance < best!.2 {
                best = (a, b, distance)
            }
        }
        return best
    }

    private static func distanceToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        if lengthSquared < 1e-6 { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        let projection = a + ab * t
        return simd_distance(p, projection)
    }

    private static func polygonArea(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private static func makeFloorMesh(outline: [SIMD2<Float>], base: SIMD3<Float>, material: DollhouseMaterial, path: DollhouseNodePath) -> DollhouseMesh {
        let triangles = triangulate(outline)
        var vertices: [DollhouseVertex] = []
        let upNormal = SIMD3<Float>(0, 1, 0)
        for point in outline {
            let position = SIMD3<Float>(point.x + base.x, base.y, point.y + base.z)
            vertices.append(DollhouseVertex(position: position, normal: upNormal))
        }
        guard !triangles.isEmpty else {
            return DollhouseMesh(vertices: vertices, indices: [], material: material, path: path)
        }
        let first = triangles[0]
        let p0 = vertices[first.0].position
        let p1 = vertices[first.1].position
        let p2 = vertices[first.2].position
        let computedNormal = simd_cross(p1 - p0, p2 - p0)
        let flip = computedNormal.y < 0
        var indices: [UInt32] = []
        for triangle in triangles {
            if flip {
                indices.append(UInt32(triangle.0))
                indices.append(UInt32(triangle.2))
                indices.append(UInt32(triangle.1))
            } else {
                indices.append(UInt32(triangle.0))
                indices.append(UInt32(triangle.1))
                indices.append(UInt32(triangle.2))
            }
        }
        return DollhouseMesh(vertices: vertices, indices: indices, material: material, path: path)
    }

    private static func outlineSignedArea(_ outline: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in outline.indices {
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    private static func appendWallFace(
        vertices: inout [DollhouseVertex],
        indices: inout [UInt32],
        corners: [SIMD3<Float>],
        expectedNormal: SIMD3<Float>
    ) {
        guard corners.count == 4 else { return }
        let p0 = corners[0]
        let p1 = corners[1]
        let p2 = corners[2]
        let p3 = corners[3]
        let computed = simd_cross(p1 - p0, p2 - p0)
        let normalized = simd_normalize(expectedNormal)
        let ordered: [SIMD3<Float>]
        if simd_dot(computed, expectedNormal) < 0 {
            ordered = [p0, p3, p2, p1]
        } else {
            ordered = [p0, p1, p2, p3]
        }
        let baseIndex = UInt32(vertices.count)
        for corner in ordered {
            vertices.append(DollhouseVertex(position: corner, normal: normalized))
        }
        indices.append(contentsOf: [baseIndex, baseIndex + 1, baseIndex + 2, baseIndex, baseIndex + 2, baseIndex + 3])
    }

    private static func triangulate(_ polygon: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        guard polygon.count >= 3 else { return [] }
        var indices = Array(0..<polygon.count)
        var triangles: [(Int, Int, Int)] = []
        var signedArea: Float = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            signedArea += a.x * b.y - b.x * a.y
        }
        let ccw = signedArea >= 0
        var guardCount = 0
        while indices.count > 3 && guardCount < 10000 {
            guardCount += 1
            var earFound = false
            for i in 0..<indices.count {
                let iPrev = indices[(i - 1 + indices.count) % indices.count]
                let iCurr = indices[i]
                let iNext = indices[(i + 1) % indices.count]
                let a = polygon[iPrev]
                let b = polygon[iCurr]
                let c = polygon[iNext]
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                if ccw ? cross <= 0 : cross >= 0 { continue }
                var isEar = true
                for j in indices {
                    if j == iPrev || j == iCurr || j == iNext { continue }
                    if pointInTriangle(polygon[j], a, b, c) { isEar = false; break }
                }
                if isEar {
                    triangles.append((iPrev, iCurr, iNext))
                    indices.remove(at: i)
                    earFound = true
                    break
                }
            }
            if !earFound { break }
        }
        if indices.count == 3 {
            triangles.append((indices[0], indices[1], indices[2]))
        }
        return triangles
    }

    private static func pointInTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let d1 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        let d2 = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
        let d3 = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    private static func makeWallMesh(
        a: SIMD2<Float>,
        b: SIMD2<Float>,
        height: Float,
        base: SIMD3<Float>,
        material: DollhouseMaterial,
        path: DollhouseNodePath,
        inwardNormal2D: SIMD2<Float>
    ) -> DollhouseMesh {
        let direction = b - a
        let length = simd_length(direction)
        if length < 1e-4 { return DollhouseMesh(vertices: [], indices: [], material: material, path: path) }
        let unit = direction / length
        let halfThickness = DollhouseConstants.exteriorWallThicknessM / 2
        let innerA = a + inwardNormal2D * halfThickness
        let innerB = b + inwardNormal2D * halfThickness
        let outerA = a - inwardNormal2D * halfThickness
        let outerB = b - inwardNormal2D * halfThickness

        func world(_ p: SIMD2<Float>, _ y: Float) -> SIMD3<Float> {
            SIMD3<Float>(p.x + base.x, base.y + y, p.y + base.z)
        }

        let w0 = world(innerA, 0)
        let w1 = world(innerB, 0)
        let w2 = world(innerB, height)
        let w3 = world(innerA, height)
        let o0 = world(outerA, 0)
        let o1 = world(outerB, 0)
        let o2 = world(outerB, height)
        let o3 = world(outerA, height)

        let inward3D = SIMD3<Float>(inwardNormal2D.x, 0, inwardNormal2D.y)
        let outward3D = -inward3D
        let upNormal = SIMD3<Float>(0, 1, 0)
        let downNormal = SIMD3<Float>(0, -1, 0)
        let alongNormal = SIMD3<Float>(unit.x, 0, unit.y)
        let negAlongNormal = -alongNormal

        var vertices: [DollhouseVertex] = []
        var indices: [UInt32] = []
        appendWallFace(vertices: &vertices, indices: &indices, corners: [w0, w1, w2, w3], expectedNormal: inward3D)
        appendWallFace(vertices: &vertices, indices: &indices, corners: [o0, o1, o2, o3], expectedNormal: outward3D)
        appendWallFace(vertices: &vertices, indices: &indices, corners: [w0, o0, o1, w1], expectedNormal: downNormal)
        appendWallFace(vertices: &vertices, indices: &indices, corners: [w3, w2, o2, o3], expectedNormal: upNormal)
        appendWallFace(vertices: &vertices, indices: &indices, corners: [w0, w3, o3, o0], expectedNormal: negAlongNormal)
        appendWallFace(vertices: &vertices, indices: &indices, corners: [w1, w2, o2, o1], expectedNormal: alongNormal)

        return DollhouseMesh(vertices: vertices, indices: indices, material: material, path: path)
    }

    private static func makeOpeningFrame(
        wallA: SIMD2<Float>,
        wallB: SIMD2<Float>,
        openingPosition: SIMD2<Float>,
        width: Float,
        height: Float,
        sill: Float,
        base: SIMD3<Float>,
        material: DollhouseMaterial,
        path: DollhouseNodePath
    ) -> DollhouseMesh? {
        let direction = wallB - wallA
        let length = simd_length(direction)
        if length < 1e-4 { return nil }
        let unit = direction / length
        let halfWidth = min(width / 2, length / 2 - 0.01)
        guard halfWidth > 0.05 else { return nil }
        let projection = simd_dot(openingPosition - wallA, unit)
        let clamped = max(halfWidth, min(length - halfWidth, projection))
        let centerOnWall = wallA + unit * clamped
        let center3D = SIMD3<Float>(centerOnWall.x + base.x, base.y + sill + height / 2, centerOnWall.y + base.z)
        let yaw = atan2(unit.y, unit.x)
        let size = SIMD3<Float>(halfWidth * 2, height, DollhouseConstants.exteriorWallThicknessM + DollhouseConstants.frameDepthM)
        return makeBox(center: center3D, size: size, yaw: yaw, base: SIMD3<Float>(0, 0, 0), material: material, path: path)
    }

    private static func makeBox(center: SIMD3<Float>, size: SIMD3<Float>, yaw: Float, base: SIMD3<Float>, material: DollhouseMaterial, path: DollhouseNodePath) -> DollhouseMesh {
        let half = size / 2
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let corners: [SIMD3<Float>] = [
            SIMD3(-half.x, -half.y, -half.z),
            SIMD3(half.x, -half.y, -half.z),
            SIMD3(half.x, -half.y, half.z),
            SIMD3(-half.x, -half.y, half.z),
            SIMD3(-half.x, half.y, -half.z),
            SIMD3(half.x, half.y, -half.z),
            SIMD3(half.x, half.y, half.z),
            SIMD3(-half.x, half.y, half.z),
        ]
        func rotate(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let x = point.x * cosYaw - point.z * sinYaw
            let z = point.x * sinYaw + point.z * cosYaw
            return SIMD3<Float>(x + center.x + base.x, point.y + center.y + base.y, z + center.z + base.z)
        }
        var vertices: [DollhouseVertex] = []
        var indices: [UInt32] = []
        let faces: [(Int, Int, Int, Int)] = [
            (0, 1, 2, 3),
            (7, 6, 5, 4),
            (0, 4, 5, 1),
            (1, 5, 6, 2),
            (2, 6, 7, 3),
            (3, 7, 4, 0),
        ]
        for face in faces {
            let p0 = rotate(corners[face.0])
            let p1 = rotate(corners[face.1])
            let p2 = rotate(corners[face.2])
            let p3 = rotate(corners[face.3])
            let normal = simd_normalize(simd_cross(p1 - p0, p2 - p0))
            let baseIndex = UInt32(vertices.count)
            vertices.append(DollhouseVertex(position: p0, normal: normal))
            vertices.append(DollhouseVertex(position: p1, normal: normal))
            vertices.append(DollhouseVertex(position: p2, normal: normal))
            vertices.append(DollhouseVertex(position: p3, normal: normal))
            indices.append(contentsOf: [baseIndex, baseIndex + 1, baseIndex + 2, baseIndex, baseIndex + 2, baseIndex + 3])
        }
        return DollhouseMesh(vertices: vertices, indices: indices, material: material, path: path)
    }
}
