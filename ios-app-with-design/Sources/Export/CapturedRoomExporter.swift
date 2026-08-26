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

    private static func mapFloor(_ surface: CapturedRoom.Surface) -> RoomPlanCaptureExport.SurfaceExport {
        var export = mapSurface(surface, category: "floor")
        export.polygonCorners = surface.polygonCorners.map { corner in
            [Double(corner.x), Double(corner.y), Double(corner.z)]
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
