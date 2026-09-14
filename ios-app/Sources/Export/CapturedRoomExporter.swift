
import RoomPlan
import simd

struct RoomPlanCaptureExport: Encodable {
    let story: Int
    let floors: [SurfaceExport]
    let walls: [SurfaceExport]
    let doors: [SurfaceExport]
    let windows: [SurfaceExport]
    let openings: [SurfaceExport]
    let objects: [SurfaceExport]

    var roomType: RoomTypeExport? = nil
    var structureOriginM: [Double]? = nil
    var walkPathM: [[Double]]? = nil
    var headingDeg: Double? = nil

    enum CodingKeys: String, CodingKey {
        case story, floors, walls, doors, windows, openings, objects
        case roomType = "room_type"
        case structureOriginM = "structure_origin_m"
        case walkPathM = "walk_path"
        case headingDeg = "heading_deg"
    }

    struct SurfaceExport: Encodable {
        let identifier: String
        let category: String
        let confidence: String
        var dimensions: [Double]? = nil
        var polygonCorners: [[Double]]? = nil

        var position: [Double]? = nil
    }

    struct RoomTypeExport: Encodable {
        let guess: String
        let guessSource: String
        var confirmed: String? = nil

        enum CodingKeys: String, CodingKey {
            case guess
            case guessSource = "guess_source"
            case confirmed
        }
    }
}

struct RoomTypeConfirmation {
    let value: String
    let answeredForGuessType: String?
}

enum CapturedRoomExporter {
    static func export(_ room: CapturedRoom, roomTypeConfirmation: RoomTypeConfirmation? = nil, walkPath: [[Double]]? = nil, headingDeg: Double? = nil) -> RoomPlanCaptureExport {
        var export = RoomPlanCaptureExport(
            story: 0,
            floors: room.floors.map { mapSurface($0, category: "floor") },
            walls: room.walls.map { mapSurface($0, category: "wall") },
            doors: room.doors.map { mapSurface($0, category: "door") },
            windows: room.windows.map { mapSurface($0, category: "window") },
            openings: room.openings.map { mapSurface($0, category: "opening") },
            objects: room.objects.map(mapObject)
        )
        export.walkPathM = (walkPath?.isEmpty ?? true) ? nil : walkPath
        export.headingDeg = headingDeg
        if RoomTypeGuessSettings.isEnabled, let guess = RoomTypeClassifier.guess(for: room) {
            let confirmedValue = roomTypeConfirmation?.answeredForGuessType == guess.type ? roomTypeConfirmation?.value : nil
            export.roomType = RoomPlanCaptureExport.RoomTypeExport(
                guess: guess.type,
                guessSource: guess.source,
                confirmed: confirmedValue
            )
        }
        return export
    }

    private static func worldPolygonCorners(_ surface: CapturedRoom.Surface) -> [[Double]] {
        surface.polygonCorners.map { corner in
            let world = surface.transform * simd_float4(corner, 1)
            return [Double(world.x), Double(world.y), Double(world.z)]
        }
    }

    private static func mapSurface(_ surface: CapturedRoom.Surface, category: String) -> RoomPlanCaptureExport.SurfaceExport {
        var export = RoomPlanCaptureExport.SurfaceExport(
            identifier: surface.identifier.uuidString,
            category: category,
            confidence: mapConfidence(surface.confidence),
            dimensions: [Double(surface.dimensions.x), Double(surface.dimensions.y), Double(surface.dimensions.z)]
        )
        export.polygonCorners = worldPolygonCorners(surface)
        return export
    }

    private static func mapObject(_ object: CapturedRoom.Object) -> RoomPlanCaptureExport.SurfaceExport {
        var export = RoomPlanCaptureExport.SurfaceExport(
            identifier: object.identifier.uuidString,
            category: mapObjectCategory(object.category),
            confidence: mapConfidence(object.confidence),
            dimensions: [Double(object.dimensions.x), Double(object.dimensions.y), Double(object.dimensions.z)]
        )
        let translation = object.transform.columns.3
        export.position = [Double(translation.x), Double(translation.y), Double(translation.z)]
        return export
    }

    private static func mapObjectCategory(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .bed: return "bed"
        case .sink: return "sink"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .oven: return "oven"
        case .dishwasher: return "dishwasher"
        case .table: return "table"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        case .washerDryer: return "washerDryer"
        @unknown default: return "object"
        }
    }

    private static func mapConfidence(_ confidence: CapturedRoom.Confidence) -> String {
        switch confidence {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        @unknown default: return "low"
        }
    }
}

extension RoomPlanCaptureExport {
    private static let minFloorAreaM2 = 0.25

    var hasUsableFloorOutline: Bool {
        guard !floors.isEmpty else { return false }
        return floors.allSatisfy { floor in
            guard let corners = floor.polygonCorners, corners.count >= 3 else { return false }
            let points = corners.map { (x: $0[0], z: $0[2]) }
            var sum = 0.0
            for i in points.indices {
                let a = points[i]
                let b = points[(i + 1) % points.count]
                sum += a.x * b.z - b.x * a.z
            }
            return abs(sum) / 2.0 >= Self.minFloorAreaM2
        }
    }
}
