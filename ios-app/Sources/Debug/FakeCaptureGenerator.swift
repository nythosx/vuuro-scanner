//
//  FakeCaptureGenerator.swift
//  VuuroScan
//
//  DEBUG-ONLY, gated behind FakeLidarMode.isEnabled. Produces a random-but-
//  server-valid RoomPlanCaptureExport so the post-capture flow can be
//  exercised on a device/simulator with no LiDAR at all (e.g. appetize.io),
//  without ever touching RoomCaptureView/ARKit — those need real hardware
//  and would just hang or crash there. Mirrors the same RoomPlan-shaped
//  contract scan-service/fixtures/*.json already uses server-side, and
//  stays within the server's own sanity bounds (RoomPlanSimulatorAdapter.php:
//  0.25m2 minimum floor area, well inside the 1000m coordinate cap) so it's
//  exercising the real upload/validation path, not dodging it.
//

#if DEBUG
import Foundation

enum FakeCaptureGenerator {
    static func random() -> RoomPlanCaptureExport {
        let width = Double.random(in: 2.0...8.0)
        let length = Double.random(in: 2.0...8.0)

        let floor = RoomPlanCaptureExport.SurfaceExport(
            identifier: UUID().uuidString,
            category: "floor",
            confidence: randomConfidence(),
            dimensions: [width, 2.4, length],
            polygonCorners: [
                [0, 0, 0],
                [width, 0, 0],
                [width, 0, length],
                [0, 0, length],
            ]
        )

        let walls = (0..<Int.random(in: 3...4)).map { _ in
            RoomPlanCaptureExport.SurfaceExport(
                identifier: UUID().uuidString,
                category: "wall",
                confidence: randomConfidence(),
                dimensions: [Double.random(in: 1.0...width), 2.4, 0.1]
            )
        }

        return RoomPlanCaptureExport(
            story: 0,
            floors: [floor],
            walls: walls,
            doors: [],
            windows: [],
            openings: [],
            objects: []
        )
    }

    private static func randomConfidence() -> String {
        ["high", "medium", "low"].randomElement()!
    }
}
#endif
