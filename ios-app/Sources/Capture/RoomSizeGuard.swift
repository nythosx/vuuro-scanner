import RoomPlan
import simd

enum RoomSizeGuard {
    static let practicalLimitMeters: Float = 9.0

    static func exceedsPracticalLimit(_ room: CapturedRoom) -> Bool {
        for floor in room.floors {
            let corners = floor.polygonCorners.map { floor.transform * simd_float4($0, 1) }
            let xs = corners.map { $0.x }
            let zs = corners.map { $0.z }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minZ = zs.min(), let maxZ = zs.max() else {
                continue
            }
            if (maxX - minX) > practicalLimitMeters || (maxZ - minZ) > practicalLimitMeters {
                return true
            }
        }
        return false
    }
}
