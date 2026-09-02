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
    }
}

enum CapturedRoomExporter {
    static func export(_ room: CapturedRoom) -> RoomPlanCaptureExport {
        RoomPlanCaptureExport(
            story: 0,
            floors: room.floors.map(mapFloor),
            walls: room.walls.map { mapSurface($0, category: "wall") },
            doors: room.doors.map { mapSurface($0, category: "door") },
            windows: room.windows.map { mapSurface($0, category: "window") },
            openings: room.openings.map { mapSurface($0, category: "opening") },
            objects: []
        )
    }

    // See ios-app/'s copy of this file for why: Mark found on the first real
    // RoomPlan capture (2026-09-02) that `polygonCorners` are in the
    // surface's own local coordinate space, not room-world space —
    // exporting them raw collapsed every real floor to a 0.0000 m2 outline.
    // `surface.transform` places the surface's local frame in world space.
    private static func mapFloor(_ surface: CapturedRoom.Surface) -> RoomPlanCaptureExport.SurfaceExport {
        var export = mapSurface(surface, category: "floor")
        export.polygonCorners = surface.polygonCorners.map { corner in
            let world = surface.transform * simd_float4(corner, 1)
            return [Double(world.x), Double(world.y), Double(world.z)]
        }
        return export
    }

    private static func mapSurface(_ surface: CapturedRoom.Surface, category: String) -> RoomPlanCaptureExport.SurfaceExport {
        RoomPlanCaptureExport.SurfaceExport(
            identifier: surface.identifier.uuidString,
            category: category,
            confidence: mapConfidence(surface.confidence),
            dimensions: [Double(surface.dimensions.x), Double(surface.dimensions.y), Double(surface.dimensions.z)]
        )
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
