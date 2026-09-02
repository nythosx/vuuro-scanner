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

    // Real bug found by Mark on the first real RoomPlan capture (2026-09-02):
    // `polygonCorners` are in the surface's own local coordinate space (a
    // floor's local plane, local Z near zero), not room-world space —
    // exporting them raw collapsed every real floor to a 0.0000 m2 outline,
    // deterministically, since the adapter's world-space (x,z) projection
    // read a near-constant local Z as if it varied. `surface.transform`
    // places the surface's local frame in the room's world coordinates —
    // applying it here is what Apple's own RoomPlan documentation describes
    // for reading polygonCorners in world space, and it's what every fixture
    // (both here and scan-service/fixtures/*.json) always assumed the
    // exporter already did. No fixture ever exercised this specific step
    // because it was never possible to test without real hardware.
    //
    // LIDAR-10: doors/windows/openings get the same treatment now, not just
    // floors — Mark's card asks for door/window "positions, not only
    // coverage," and this is the one technique already proven on real
    // hardware, so it's reused rather than inventing a second approach.
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

    // Unverified without Xcode/real hardware (no Mac reachable on this
    // machine — see docs/adr/0001-scan-service-stack.md): written to
    // RoomPlan's documented CapturedRoom.Object shape (category, confidence,
    // dimensions, transform), same caution CaptureCoordinator.swift's
    // RoomBuilder call already flags. Mark's real-device retest loop is what
    // confirms this, same as it caught the mapFloor transform bug above.
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
    // Mirrors RoomPlanSimulatorAdapter.php's MIN_POLYGON_AREA_M2 guard,
    // client-side — Mark's 2026-09-02 request (b): a capture this degenerate
    // needed no LiDAR to build or test, so it shouldn't have taken a round
    // trip to the server to catch. Same (x,z) ground-plane projection and
    // shoelace formula as the adapter, applied to the now-world-space
    // corners mapFloor produces.
    private static let minFloorAreaM2 = 0.25

    // Checks every floor, not just the first — RoomPlanSimulatorAdapter.php
    // rejects on ANY floor with a degenerate outline (a multi-story capture
    // can carry more than one), so a guard that only looked at floors[0]
    // would let a bad floors[1] slip past locally and still round-trip to
    // the server for the same reject this guard exists to avoid.
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
