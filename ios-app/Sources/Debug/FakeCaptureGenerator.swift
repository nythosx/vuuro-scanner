
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

        let objects = (0..<Int.random(in: 1...2)).map { _ in
            RoomPlanCaptureExport.SurfaceExport(
                identifier: UUID().uuidString,
                category: ["chair", "table", "storage"].randomElement()!,
                confidence: "high",
                dimensions: [0.5, 0.5, 0.5],
                position: [Double.random(in: 0.5...1.5), 0.25, Double.random(in: 0.5...1.5)]
            )
        }

        return RoomPlanCaptureExport(
            story: 0,
            floors: [floor],
            walls: walls,
            doors: [],
            windows: [],
            openings: [],
            objects: objects
        )
    }

    private static func randomConfidence() -> String {
        ["high", "medium", "low"].randomElement()!
    }
}
#endif
