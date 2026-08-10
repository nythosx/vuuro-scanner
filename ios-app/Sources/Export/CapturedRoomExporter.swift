//
//  CapturedRoomExporter.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Converts RoomPlan's CapturedRoom into the exact JSON shape the Scan
//  Service's RoomPlanSimulatorAdapter expects as `raw_capture`
//  (scan-service/src/Adapters/RoomPlanSimulatorAdapter.php and
//  scan-service/fixtures/roomplan_captured_room_single_room.json). Keeping
//  this mapping explicit and separate from CapturedRoom's own Codable
//  conformance (rather than just `JSONEncoder().encode(capturedRoom)`) is
//  deliberate: the Scan Service's adapter contract is pinned to the fixture
//  shape, not to whatever Apple happens to name its Codable keys, so this
//  file is the seam that has to hold even if Apple's own encoding changes.
//
//  IMPORTANT — unverified assumption: `polygonCorners` on a floor Surface is
//  assumed available (used for the shoelace-based area/perimeter math on the
//  Scan Service side). This has not been confirmed against the real RoomPlan
//  SDK on this machine — see docs/adr/0001-scan-service-stack.md. The first
//  thing to check once Xcode is reachable: does CapturedRoom.Surface actually
//  expose `polygonCorners`, and if not, what's the real way to get a floor
//  outline out of RoomPlan? Fix this mapping (and the fixture, and the
//  adapter if needed) then — don't leave the assumption unverified past the
//  first real build.

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
