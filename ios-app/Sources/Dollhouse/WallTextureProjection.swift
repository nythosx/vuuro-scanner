import Foundation
import simd

enum WallTextureProjection {
    static let cameraHeightM: Float = 1.5
    static let horizontalFovDeg: Float = 60.0
    static let verticalFovDeg: Float = 60.0
    static let minDepthM: Float = 0.2
    static let maxHeadingOffsetDeg: Float = 60.0
    static let maxWallLengthPerSpan: Float = 2.0

    static func projectPointRaw(
        photo: FloorPlan.Photo360,
        roomHeadingDeg: Float,
        point: SIMD3<Float>
    ) -> SIMD2<Float>? {
        let forward = forwardVector(photo: photo, roomHeadingDeg: roomHeadingDeg)
        let rx = forward.y
        let rz = -forward.x

        let camX = Float(photo.positionM[0])
        let camZ = Float(photo.positionM[1])
        let dx = point.x - camX
        let dy = point.y - cameraHeightM
        let dz = point.z - camZ

        let zCam = dx * forward.x + dz * forward.y
        guard zCam >= minDepthM else { return nil }
        let xCam = dx * rx + dz * rz
        let yCam = dy

        let halfH = tan(horizontalFovDeg * .pi / 180.0 / 2.0)
        let halfV = tan(verticalFovDeg * .pi / 180.0 / 2.0)

        let u = 0.5 + xCam / (2.0 * halfH * zCam)
        let v = 0.5 - yCam / (2.0 * halfV * zCam)
        return SIMD2<Float>(u, v)
    }

    static func projectPoint(
        photo: FloorPlan.Photo360,
        roomHeadingDeg: Float,
        point: SIMD3<Float>
    ) -> SIMD2<Float>? {
        guard let uv = projectPointRaw(photo: photo, roomHeadingDeg: roomHeadingDeg, point: point) else {
            return nil
        }
        guard uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1 else {
            return nil
        }
        return uv
    }

    static func pickWallPhoto(
        wallA: SIMD2<Float>,
        wallB: SIMD2<Float>,
        inwardNormal: SIMD2<Float>,
        roomHeadingDeg: Float,
        wallHeightM: Float,
        photos: [FloorPlan.Photo360]
    ) -> FloorPlan.Photo360? {
        let minDot = -cos(maxHeadingOffsetDeg * .pi / 180.0)
        let midX = (wallA.x + wallB.x) / 2.0
        let midZ = (wallA.y + wallB.y) / 2.0
        let midHeightY = wallHeightM / 2.0
        let wallLength = simd_length(wallB - wallA)
        let halfH = tan(horizontalFovDeg * .pi / 180.0 / 2.0)

        var best: FloorPlan.Photo360?
        var bestScore: Float = -.infinity
        for photo in photos {
            guard photo.positionM.count >= 2 else { continue }
            let forward = forwardVector(photo: photo, roomHeadingDeg: roomHeadingDeg)
            let dot = forward.x * inwardNormal.x + forward.y * inwardNormal.y
            if dot > minDot { continue }
            let mid = projectPoint(
                photo: photo,
                roomHeadingDeg: roomHeadingDeg,
                point: SIMD3<Float>(midX, midHeightY, midZ)
            )
            guard mid != nil else { continue }
            let camX = Float(photo.positionM[0])
            let camZ = Float(photo.positionM[1])
            let zCam = (midX - camX) * forward.x + (midZ - camZ) * forward.y
            if zCam < minDepthM { continue }
            let coveredSpan = 2.0 * halfH * zCam
            if wallLength > maxWallLengthPerSpan * coveredSpan { continue }
            let dist = simd_length(SIMD2<Float>(midX - camX, midZ - camZ))
            let score = -dot - dist * 0.01
            if score > bestScore {
                bestScore = score
                best = photo
            }
        }
        return best
    }

    private static func forwardVector(
        photo: FloorPlan.Photo360,
        roomHeadingDeg: Float
    ) -> SIMD2<Float> {
        let theta = (roomHeadingDeg - Float(photo.headingDeg)) * .pi / 180.0
        return SIMD2<Float>(sin(theta), cos(theta))
    }
}
