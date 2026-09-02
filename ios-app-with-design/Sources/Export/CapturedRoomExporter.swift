//
//  CapturedRoomExporter.swift
//  VuuroScan
//

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

    struct SurfaceExport: Encodable {
        let identifier: String
        let category: String
        let confidence: String
        var dimensions: [Double]? = nil
        var polygonCorners: [[Double]]? = nil
        // Single world-space point — only set for `objects`, which RoomPlan
        // reports as a bounding box + transform, not a polygon outline like
        // floors/walls/doors/windows/openings.
        var position: [Double]? = nil
    }
}

enum CapturedRoomExporter {
    static func export(_ room: CapturedRoom) -> RoomPlanCaptureExport {
        RoomPlanCaptureExport(
            story: 0,
            floors: room.floors.map { mapSurface($0, category: "floor") },
            walls: room.walls.map { mapSurface($0, category: "wall") },
            doors: room.doors.map { mapSurface($0, category: "door") },
            windows: room.windows.map { mapSurface($0, category: "window") },
            openings: room.openings.map { mapSurface($0, category: "opening") },
            // LIDAR-10: real captured furniture/fixtures, not the previous
            // hardcoded `[]` — empty only when RoomPlan itself saw none.
            objects: room.objects.map(mapObject)
        )
    }

    // See ios-app/'s copy of this file for why: Mark found on the first real
    // RoomPlan capture (2026-09-02) that `polygonCorners` are in the
    // surface's own local coordinate space, not room-world space —
    // exporting them raw collapsed every real floor to a 0.0000 m2 outline.
    // `surface.transform` places the surface's local frame in world space.
    // LIDAR-10: doors/windows/openings get the same treatment now, not just
    // floors — reusing the one technique already proven on real hardware.
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

    // See ios-app/'s copy of this file for why: unverified without Xcode/real
    // hardware, written to RoomPlan's documented CapturedRoom.Object shape.
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

    // Passes through RoomPlan's own category — never invents one it did not
    // report. @unknown default covers a category added in a newer SDK than
    // this was written against.
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
    // See ios-app/'s copy of this file for why: mirrors
    // RoomPlanSimulatorAdapter.php's MIN_POLYGON_AREA_M2 guard client-side.
    private static let minFloorAreaM2 = 0.25

    // See ios-app/'s copy of this file for why: checks every floor, not just
    // the first — a multi-story capture can carry more than one, and the
    // adapter rejects on any floor with a degenerate outline.
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
