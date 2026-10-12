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
    case tooManyTriangles

    var errorDescription: String? {
        switch self {
        case .noRooms: return "This scan has no rooms to show in 3D."
        case .emptyGeometry: return "The captured rooms produced no usable 3D geometry."
        case .tooManyTriangles: return vuuroLocalized("This 3D model has too many details to export.")
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
    static let maxTriangles = 150_000
    static let sectionVerticalGapM: Float = 1.5
    static let seamOverlapM: Float = 0.015
    static let weldGridM: Float = 0.001
    static let doorHeightM: Float = 2.05
    static let windowHeightM: Float = 1.2
    static let windowSillM: Float = 0.9
    static let otherOpeningHeightM: Float = 1.0
    static let frameDepthM: Float = 0.06
    static let doorFrameInsetM: Float = 0.04
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
            return SIMD4(0.90, 0.88, 0.84, 1.0)
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

private struct WeldKey: Hashable {
    let x: Int64
    let z: Int64

    init(_ point: SIMD2<Float>) {
        self.x = Int64((point.x / DollhouseConstants.weldGridM).rounded())
        self.z = Int64((point.y / DollhouseConstants.weldGridM).rounded())
    }
}

private struct MiteredCorners {
    let inner: SIMD2<Float>
    let outer: SIMD2<Float>
}

private struct EdgeSegment {
    let t0: Float
    let t1: Float
    let y0: Float
    let y1: Float
    let layer: DollhouseLayer
}

private struct PlannedOpening {
    let t0: Float
    let t1: Float
    let y0: Float
    let y1: Float
    let layer: DollhouseLayer
    let positionAlongEdge: Float
    let positionXZ: SIMD2<Float>
    let widthM: Float
    let heightM: Float
    let openingId: String
    let category: String
}

struct DollhouseMeshBuilder {

    // MARK: - Entrypoints

    static func build(rooms: [FloorPlan.Room], configuration: DollhouseBuildConfiguration = DollhouseBuildConfiguration(), photos360: [FloorPlan.Photo360] = []) throws -> DollhouseScene {
        guard !rooms.isEmpty else { throw DollhouseMeshBuilderError.noRooms }

        let largePlan = isLargePlan(rooms)
        var effectiveConfiguration = configuration
        if largePlan && configuration.performanceMode {
            effectiveConfiguration.showFurniture = false
        }

        var meshes: [DollhouseMesh] = []
        var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var hasGeometry = false
        var usedEstimatedHeight = false
        var degenerateRoomCount = 0

        var photos360ByRoom: [String: [FloorPlan.Photo360]] = [:]
        for photo in photos360 {
            photos360ByRoom[photo.roomId, default: []].append(photo)
        }

        let sections = makeFloorSections(rooms: rooms)
        var sectionOffsetZ: Float = 0.0
        var sectionSummaries: [DollhouseFloorSection] = []
        var allHotspots: [DollhouseHotspot] = []

        for (sectionIndex, section) in sections.enumerated() {
            let weldedOutlines = weldSectionOutlines(rooms: section.rooms)
            let sectionOrigin = SIMD3<Float>(0.0, 0.0, sectionOffsetZ - localMinZ(of: section.rooms, weldedOutlines: weldedOutlines))
            var sectionMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var sectionMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

            let sectionSharedEdges = findSharedEdges(section.rooms, weldedOutlines: weldedOutlines)
            for room in section.rooms {
                let outline = weldedOutlines[room.roomId] ?? []
                let result = buildRoom(
                    room: room,
                    outline: outline,
                    configuration: effectiveConfiguration,
                    sectionOrigin: sectionOrigin,
                    skipEdges: sectionSharedEdges.skip[room.roomId] ?? [],
                    interiorEdges: sectionSharedEdges.interior[room.roomId] ?? [],
                    photos360: photos360ByRoom[room.roomId] ?? []
                )
                if result.estimatedHeight { usedEstimatedHeight = true }
                if result.degenerate { degenerateRoomCount += 1 }
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
                allHotspots.append(contentsOf: result.hotspots)
            }

            if sectionMin.x.isFinite && sectionMax.x.isFinite {
                sectionSummaries.append(DollhouseFloorSection(
                    id: "section-\(sectionIndex)",
                    title: section.title,
                    roomIds: section.rooms.map(\.roomId),
                    originOffset: sectionOrigin,
                    boundsMin: sectionMin,
                    boundsMax: sectionMax
                ))
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
            usedEstimatedHeight: usedEstimatedHeight,
            headingDeg: sections.count == 1 ? agreedHeading(rooms) : nil,
            degenerateRoomCount: degenerateRoomCount,
            hotspots: allHotspots
        )
    }

    static func buildForExport(rooms: [FloorPlan.Room], maxTriangles: Int = DollhouseConstants.maxTriangles) throws -> DollhouseScene {
        let full = try build(rooms: rooms, configuration: DollhouseBuildConfiguration(mode: .dollhouse))
        if full.totalTriangles <= maxTriangles { return full }
        let reduced = try build(rooms: rooms, configuration: DollhouseBuildConfiguration(mode: .dollhouse, showFurniture: false))
        if reduced.totalTriangles <= maxTriangles { return reduced }
        throw DollhouseMeshBuilderError.tooManyTriangles
    }

    static func isLargePlan(_ rooms: [FloorPlan.Room]) -> Bool {
        if rooms.count > DollhouseConstants.largePlanRoomThreshold { return true }
        let complexity = rooms.reduce(0) { $0 + $1.outlineM.count + $1.objects.count }
        return complexity > 120
    }

    // MARK: - Section geometry

    private static func localMinZ(of rooms: [FloorPlan.Room], weldedOutlines: [String: [SIMD2<Float>]]) -> Float {
        var minZ = Float.greatestFiniteMagnitude
        for room in rooms {
            let originZ = Float(room.structureOriginM?.dropFirst().first ?? 0)
            for point in weldedOutlines[room.roomId] ?? [] {
                minZ = min(minZ, originZ + point.y)
            }
        }
        return minZ.isFinite ? minZ : 0
    }

    private static func weldSectionOutlines(rooms: [FloorPlan.Room]) -> [String: [SIMD2<Float>]] {
        var representatives: [WeldKey: SIMD2<Float>] = [:]
        for room in rooms {
            let originX = Float(room.structureOriginM?.first ?? 0)
            let originZ = Float(room.structureOriginM?.dropFirst().first ?? 0)
            for point in room.outlineM where point.count >= 2 {
                let world = SIMD2<Float>(Float(point[0]) + originX, Float(point[1]) + originZ)
                let key = WeldKey(world)
                if representatives[key] == nil {
                    representatives[key] = world
                }
            }
        }
        var result: [String: [SIMD2<Float>]] = [:]
        for room in rooms {
            let originX = Float(room.structureOriginM?.first ?? 0)
            let originZ = Float(room.structureOriginM?.dropFirst().first ?? 0)
            var welded: [SIMD2<Float>] = []
            for point in room.outlineM where point.count >= 2 {
                let world = SIMD2<Float>(Float(point[0]) + originX, Float(point[1]) + originZ)
                let key = WeldKey(world)
                welded.append(representatives[key] ?? world)
            }
            result[room.roomId] = welded
        }
        return result
    }

    // MARK: - Shared edges (interior wall detection)

    private struct SharedEdge {
        let roomId: String
        let index: Int
        let ax: Float
        let az: Float
        let bx: Float
        let bz: Float
        let length: Float
        let isOpen: Bool
    }

    private static func findSharedEdges(_ rooms: [FloorPlan.Room], weldedOutlines: [String: [SIMD2<Float>]]) -> (skip: [String: Set<Int>], interior: [String: Set<Int>]) {
        var edges: [SharedEdge] = []
        for room in rooms {
            guard let outline = weldedOutlines[room.roomId], outline.count >= 3 else { continue }
            let openSet = Set(room.openEdges)
            let n = outline.count
            for i in 0..<n {
                let a = outline[i]
                let b = outline[(i + 1) % n]
                let dx = b.x - a.x
                let dz = b.y - a.y
                let length = (dx * dx + dz * dz).squareRoot()
                edges.append(SharedEdge(roomId: room.roomId, index: i, ax: a.x, az: a.y, bx: b.x, bz: b.y, length: length, isOpen: openSet.contains(i)))
            }
        }
        var skip: [String: Set<Int>] = [:]
        var interior: [String: Set<Int>] = [:]
        let count = edges.count
        for i in 0..<count {
            for j in (i + 1)..<count {
                let e1 = edges[i]
                let e2 = edges[j]
                if e1.roomId == e2.roomId { continue }
                if e1.isOpen || e2.isOpen { continue }
                guard let overlap = collinearOverlap(e1, e2) else { continue }
                let shorter = e1.length <= e2.length ? e1 : e2
                let longer = e1.length <= e2.length ? e2 : e1
                guard overlap >= 0.9 * shorter.length else { continue }
                interior[longer.roomId, default: []].insert(longer.index)
                skip[shorter.roomId, default: []].insert(shorter.index)
            }
        }
        return (skip, interior)
    }

    private static func collinearOverlap(_ e1: SharedEdge, _ e2: SharedEdge) -> Float? {
        let len1 = e1.length
        let len2 = e2.length
        if len1 < 0.2 || len2 < 0.2 { return nil }
        let d1x = e1.bx - e1.ax
        let d1z = e1.bz - e1.az
        let d2x = e2.bx - e2.ax
        let d2z = e2.bz - e2.az
        let crossAbs = abs(d1x * d2z - d1z * d2x)
        if crossAbs / (len1 * len2) > 0.05 { return nil }
        let ux = d1x / len1
        let uz = d1z / len1
        let perp = abs((e2.ax - e1.ax) * uz - (e2.az - e1.az) * ux)
        if perp > 0.15 { return nil }
        let t1 = (e2.ax - e1.ax) * ux + (e2.az - e1.az) * uz
        let t2 = (e2.bx - e1.ax) * ux + (e2.bz - e1.az) * uz
        let tLo = max(0, min(t1, t2))
        let tHi = min(len1, max(t1, t2))
        return tHi - tLo
    }

    // MARK: - Sections (floors)

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
                sections.append(Section(title: "\(base) \u{00B7} \(vuuroLocalized("part")) \(index + 1)", rooms: subgroup))
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

    private static func agreedHeading(_ rooms: [FloorPlan.Room]) -> Double? {
        let headings = rooms.compactMap(\.headingDeg).filter { $0.isFinite }
        guard let first = headings.first else { return nil }
        let base = ((first.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        for h in headings {
            let norm = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
            var diff = abs(norm - base)
            if diff > 180 { diff = 360 - diff }
            if diff > 5 { return nil }
        }
        return base
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

    // MARK: - Room build

    private struct RoomBuildResult {
        let meshes: [DollhouseMesh]
        let estimatedHeight: Bool
        var degenerate: Bool = false
        var hotspots: [DollhouseHotspot] = []
    }

    private static func buildRoom(
        room: FloorPlan.Room,
        outline: [SIMD2<Float>],
        configuration: DollhouseBuildConfiguration,
        sectionOrigin: SIMD3<Float>,
        skipEdges: Set<Int>,
        interiorEdges: Set<Int>,
        photos360: [FloorPlan.Photo360] = []
    ) -> RoomBuildResult {
        guard outline.count >= 3 else {
            return RoomBuildResult(meshes: [], estimatedHeight: false, degenerate: true)
        }
        let area = polygonArea(outline)
        guard area >= DollhouseConstants.minRoomAreaM2 else {
            return RoomBuildResult(meshes: [], estimatedHeight: false, degenerate: true)
        }

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
        let floorMesh = makeFloorMesh(outline: outline, base: base, material: floorMaterial, layer: .wallsAndFloors, path: roomPath.appending("Floor"))
        meshes.append(floorMesh)

        let openEdges = Set(room.openEdges)
        let signedArea = outlineSignedArea(outline)
        let isCounterClockwise = signedArea > 0

        for index in outline.indices {
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            if skipEdges.contains(index) { continue }

            if openEdges.contains(index) {
                let edge = b - a
                let edgeLength = simd_length(edge)
                if edgeLength > 0.05 {
                    let yaw = atan2(edge.y, edge.x)
                    let mid = (a + b) * 0.5
                    let marker = makeBox(center: SIMD3<Float>(mid.x, 0.015, mid.y), size: SIMD3<Float>(edgeLength, 0.03, 0.08), yaw: yaw, base: base, material: DollhouseMaterial.openEdge, layer: .wallsAndFloors, path: roomPath.appending("OpenEdge-\(index)"))
                    meshes.append(marker)
                }
                continue
            }

            let direction = b - a
            let length = simd_length(direction)
            if length < 1e-4 { continue }
            let unit = direction / length
            let inwardSign: Float = isCounterClockwise ? 1 : -1
            let inwardNormal2D = SIMD2<Float>(-unit.y * inwardSign, unit.x * inwardSign)
            let thickness = interiorEdges.contains(index) ? DollhouseConstants.interiorWallThicknessM : DollhouseConstants.exteriorWallThicknessM

            let openings = planOpenings(on: room, edgeIndex: index, a: a, b: b, unit: unit, length: length, roomHeight: wallHeight)
            let segments = subdivideEdge(edgeLength: length, roomHeight: wallHeight, openings: openings)

            for (segmentIndex, segment) in segments.enumerated() {
                let segA = a + unit * segment.t0
                let segB = a + unit * segment.t1
                let mesh = makeWallSegment(
                    a: segA,
                    b: segB,
                    y0: segment.y0,
                    y1: segment.y1,
                    base: base,
                    material: DollhouseMaterial.exteriorWall,
                    layer: segment.layer,
                    path: roomPath.appending("Wall-\(index)-\(segmentIndex)"),
                    inwardNormal2D: inwardNormal2D,
                    thickness: thickness,
                    extendAtStart: segment.t0 <= 0.0001,
                    extendAtEnd: segment.t1 >= length - 0.0001
                )
                meshes.append(mesh)
            }

            for opening in openings {
                if let frame = makeOpeningFrame(
                    edgeA: a,
                    edgeB: b,
                    unit: unit,
                    opening: opening,
                    base: base,
                    roomHeight: wallHeight,
                    thickness: thickness,
                    path: roomPath.appending("Opening-\(opening.openingId)")
                ) {
                    meshes.append(frame)
                }
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
                let mesh = makeBox(center: SIMD3<Float>(position.x, dims.y / 2, position.y), size: dims, yaw: yaw, base: base, material: material, layer: .furniture, path: roomPath.appending("Object-\(object.objectId)"))
                meshes.append(mesh)
            }
        }

        let hotspots = makeHotspots(photos360: photos360, roomId: roomKey, base: base)

        return RoomBuildResult(meshes: meshes, estimatedHeight: estimated, hotspots: hotspots)
    }

    // MARK: - Openings & subdivision

    private static func planOpenings(
        on room: FloorPlan.Room,
        edgeIndex: Int,
        a: SIMD2<Float>,
        b: SIMD2<Float>,
        unit: SIMD2<Float>,
        length: Float,
        roomHeight: Float
    ) -> [PlannedOpening] {
        var planned: [PlannedOpening] = []
        for opening in room.openings {
            guard opening.positionM.count >= 2 else { continue }
            let point = SIMD2<Float>(Float(opening.positionM[0]), Float(opening.positionM[1]))
            let t = simd_dot(point - a, unit)
            let onEdge = t >= -0.05 && t <= length + 0.05
            guard onEdge else { continue }
            let perpendicular = abs((point.x - a.x) * unit.y - (point.y - a.y) * unit.x)
            guard perpendicular <= DollhouseConstants.maxOpeningWallDistanceM else { continue }

            let width = openingWidth(opening)
            let clampedCenter = max(width / 2, min(length - width / 2, t))
            let t0 = max(0, clampedCenter - width / 2)
            let t1 = min(length, clampedCenter + width / 2)
            guard t1 > t0 else { continue }

            let span: (y0: Float, y1: Float, layer: DollhouseLayer)
            switch opening.category {
            case "door":
                span = (0, min(DollhouseConstants.doorHeightM, roomHeight), .doors)
            case "window":
                let sill = min(DollhouseConstants.windowSillM, roomHeight - 0.1)
                let top = min(sill + DollhouseConstants.windowHeightM, roomHeight)
                span = (sill, top, .windows)
            default:
                span = (0, min(DollhouseConstants.otherOpeningHeightM, roomHeight), .openings)
            }
            guard span.y1 > span.y0 else { continue }

            planned.append(PlannedOpening(
                t0: t0,
                t1: t1,
                y0: span.y0,
                y1: span.y1,
                layer: span.layer,
                positionAlongEdge: clampedCenter,
                positionXZ: point,
                widthM: width,
                heightM: span.y1 - span.y0,
                openingId: opening.openingId,
                category: opening.category
            ))
        }
        return planned.sorted { $0.t0 < $1.t0 }
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

    private static func subdivideEdge(edgeLength: Float, roomHeight: Float, openings: [PlannedOpening]) -> [EdgeSegment] {
        if openings.isEmpty {
            return [EdgeSegment(t0: 0, t1: edgeLength, y0: 0, y1: roomHeight, layer: .wallsAndFloors)]
        }

        var merged: [PlannedOpening] = []
        for opening in openings {
            if var last = merged.last, opening.t0 < last.t1 {
                let newT1 = max(last.t1, opening.t1)
                let newY0 = min(last.y0, opening.y0)
                let newY1 = max(last.y1, opening.y1)
                merged[merged.count - 1] = PlannedOpening(
                    t0: last.t0,
                    t1: newT1,
                    y0: newY0,
                    y1: newY1,
                    layer: last.layer,
                    positionAlongEdge: last.positionAlongEdge,
                    positionXZ: last.positionXZ,
                    widthM: newT1 - last.t0,
                    heightM: newY1 - newY0,
                    openingId: last.openingId,
                    category: last.category
                )
                last = merged[merged.count - 1]
            } else {
                merged.append(opening)
            }
        }

        var segments: [EdgeSegment] = []
        var cursor: Float = 0
        for opening in merged {
            if opening.t0 > cursor + 0.0001 {
                segments.append(EdgeSegment(t0: cursor, t1: opening.t0, y0: 0, y1: roomHeight, layer: .wallsAndFloors))
            }
            if opening.y0 > 0.0001 {
                segments.append(EdgeSegment(t0: opening.t0, t1: opening.t1, y0: 0, y1: opening.y0, layer: .wallsAndFloors))
            }
            if opening.y1 < roomHeight - 0.0001 {
                segments.append(EdgeSegment(t0: opening.t0, t1: opening.t1, y0: opening.y1, y1: roomHeight, layer: .wallsAndFloors))
            }
            cursor = opening.t1
        }
        if cursor < edgeLength - 0.0001 {
            segments.append(EdgeSegment(t0: cursor, t1: edgeLength, y0: 0, y1: roomHeight, layer: .wallsAndFloors))
        }
        return segments
    }

    // MARK: - Mesh helpers

    private static func appendWallFace(vertices: inout [DollhouseVertex], indices: inout [UInt32], corners: [SIMD3<Float>], expectedNormal: SIMD3<Float>) {
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

    private static func makeWallSegment(
        a: SIMD2<Float>,
        b: SIMD2<Float>,
        y0: Float,
        y1: Float,
        base: SIMD3<Float>,
        material: DollhouseMaterial,
        layer: DollhouseLayer,
        path: DollhouseNodePath,
        inwardNormal2D: SIMD2<Float>,
        thickness: Float,
        extendAtStart: Bool,
        extendAtEnd: Bool
    ) -> DollhouseMesh {
        let direction = b - a
        let length = simd_length(direction)
        if length < 1e-4 || y1 - y0 < 1e-4 {
            return DollhouseMesh(vertices: [], indices: [], material: material, layer: layer, path: path)
        }
        let unit = direction / length
        let halfThickness = thickness / 2
        let aExt = extendAtStart ? a - unit * halfThickness : a
        let bExt = extendAtEnd ? b + unit * halfThickness : b
        let innerA = aExt + inwardNormal2D * halfThickness
        let innerB = bExt + inwardNormal2D * halfThickness
        let outerA = aExt - inwardNormal2D * halfThickness
        let outerB = bExt - inwardNormal2D * halfThickness

        func world(_ p: SIMD2<Float>, _ y: Float) -> SIMD3<Float> {
            SIMD3<Float>(p.x + base.x, base.y + y, p.y + base.z)
        }

        let w0 = world(innerA, y0)
        let w1 = world(innerB, y0)
        let w2 = world(innerB, y1)
        let w3 = world(innerA, y1)
        let o0 = world(outerA, y0)
        let o1 = world(outerB, y0)
        let o2 = world(outerB, y1)
        let o3 = world(outerA, y1)

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
        if extendAtStart {
            appendWallFace(vertices: &vertices, indices: &indices, corners: [w0, o0, o1, w1], expectedNormal: downNormal)
            appendWallFace(vertices: &vertices, indices: &indices, corners: [w3, w2, o2, o3], expectedNormal: upNormal)
        } else {
            appendWallFace(vertices: &vertices, indices: &indices, corners: [w0, o0, o1, w1], expectedNormal: negAlongNormal)
            appendWallFace(vertices: &vertices, indices: &indices, corners: [w3, w2, o2, o3], expectedNormal: alongNormal)
        }

        return DollhouseMesh(vertices: vertices, indices: indices, material: material, layer: layer, path: path)
    }

    private static func makeOpeningFrame(
        edgeA: SIMD2<Float>,
        edgeB: SIMD2<Float>,
        unit: SIMD2<Float>,
        opening: PlannedOpening,
        base: SIMD3<Float>,
        roomHeight: Float,
        thickness: Float,
        path: DollhouseNodePath
    ) -> DollhouseMesh? {
        let direction = edgeB - edgeA
        let length = simd_length(direction)
        if length < 1e-4 { return nil }

        let centerOnWall = edgeA + unit * opening.positionAlongEdge
        let center3D = SIMD3<Float>(centerOnWall.x + base.x, base.y + opening.y0 + opening.heightM / 2, centerOnWall.y + base.z)
        let yaw = atan2(unit.y, unit.x)
        let material: DollhouseMaterial
        switch opening.category {
        case "door": material = DollhouseMaterial.door
        case "window": material = DollhouseMaterial.window
        default: material = DollhouseMaterial.otherOpening
        }
        let depth = thickness + DollhouseConstants.frameDepthM
        let size = SIMD3<Float>(opening.widthM, opening.heightM, depth)
        return makeBox(center: center3D, size: size, yaw: yaw, base: SIMD3<Float>(0, 0, 0), material: material, layer: opening.layer, path: path)
    }

    private static func makeFloorMesh(outline: [SIMD2<Float>], base: SIMD3<Float>, material: DollhouseMaterial, layer: DollhouseLayer, path: DollhouseNodePath) -> DollhouseMesh {
        let triangles = triangulate(outline)
        var vertices: [DollhouseVertex] = []
        let upNormal = SIMD3<Float>(0, 1, 0)
        for point in outline {
            let position = SIMD3<Float>(point.x + base.x, base.y, point.y + base.z)
            vertices.append(DollhouseVertex(position: position, normal: upNormal))
        }
        guard !triangles.isEmpty else {
            return DollhouseMesh(vertices: vertices, indices: [], material: material, layer: layer, path: path)
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
        return DollhouseMesh(vertices: vertices, indices: indices, material: material, layer: layer, path: path)
    }

    private static func makeBox(center: SIMD3<Float>, size: SIMD3<Float>, yaw: Float, base: SIMD3<Float>, material: DollhouseMaterial, layer: DollhouseLayer, path: DollhouseNodePath) -> DollhouseMesh {
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
        return DollhouseMesh(vertices: vertices, indices: indices, material: material, layer: layer, path: path)
    }

    // MARK: - Triangulation

    private static func polygonArea(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
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
}

private extension DollhouseMeshBuilder {
    static func makeHotspots(photos360: [FloorPlan.Photo360], roomId: String, base: SIMD3<Float>) -> [DollhouseHotspot] {
        guard !photos360.isEmpty else { return [] }
        return photos360.compactMap { photo in
            guard photo.positionM.count >= 2 else { return nil }
            let x = Float(photo.positionM[0])
            let z = Float(photo.positionM[1])
            let position = SIMD3<Float>(x + base.x, base.y + 1.4, z + base.z)
            return DollhouseHotspot(id: photo.photoId, roomId: roomId, position: position)
        }
    }
}
