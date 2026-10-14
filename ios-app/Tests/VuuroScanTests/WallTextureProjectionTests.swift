import XCTest
import simd
@testable import VuuroScan

final class WallTextureProjectionTests: XCTestCase {
    private func photo(_ position: [Double], headingDeg: Double) -> FloorPlan.Photo360 {
        FloorPlan.Photo360(
            photoId: "p",
            roomId: "r",
            url: "test://photo",
            positionM: position,
            headingDeg: headingDeg,
            capturedAt: "2026-10-14T00:00:00Z"
        )
    }

    func testStraightAheadProjectsToCentre() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, 5)
        )
        XCTAssertNotNil(uv)
        XCTAssertEqual(uv?.x ?? -1, 0.5, accuracy: 0.01)
    }

    func testFloorPointAppearsBelowCentre() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, 5)
        )
        XCTAssertNotNil(uv)
        XCTAssertGreaterThan(uv?.y ?? -1, 0.5)
    }

    func testPointBehindCameraReturnsNil() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, -5)
        )
        XCTAssertNil(uv)
    }

    func testPointCloserThanMinDepthReturnsNil() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, 0.05)
        )
        XCTAssertNil(uv)
    }

    func testPointToLeftProjectsToUBelowCentre() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(-1, 0, 5)
        )
        XCTAssertNotNil(uv)
        XCTAssertLessThan(uv?.x ?? 2, 0.5)
    }

    func testPointToRightProjectsToUAboveCentre() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(1, 0, 5)
        )
        XCTAssertNotNil(uv)
        XCTAssertGreaterThan(uv?.x ?? -1, 0.5)
    }

    func testPointWellOutsideFrameReturnsNil() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(-50, 0, 5)
        )
        XCTAssertNil(uv)
    }

    func testRawProjectionReturnsUvOutOfFrame() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPointRaw(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(-50, 0, 5)
        )
        XCTAssertNotNil(uv)
        XCTAssertLessThan(uv?.x ?? 2, 0)
    }

    func testProjectPointOnSameOutOfFramePointReturnsNil() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(-50, 0, 5)
        )
        XCTAssertNil(uv)
    }

    func testRawProjectionBehindCameraReturnsNil() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPointRaw(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, -5)
        )
        XCTAssertNil(uv)
    }

    func testRawProjectionCloserThanMinDepthReturnsNil() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPointRaw(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, 0.05)
        )
        XCTAssertNil(uv)
    }

    func testPhotoHeadingEqualRoomHeadingLooksAlongPositiveZ() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 0,
            point: SIMD3<Float>(0, 0, 5)
        )
        XCTAssertNotNil(uv)
        XCTAssertEqual(uv?.x ?? -1, 0.5, accuracy: 0.01)
    }

    func testPhotoNorthInRoomWhereZIsEastLooksAtPlusX() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 90,
            point: SIMD3<Float>(5, 0, 0)
        )
        XCTAssertNotNil(uv)
        XCTAssertEqual(uv?.x ?? -1, 0.5, accuracy: 0.01)
    }

    func testOppositeDirectionIsBehindCamera() {
        let p = photo([0, 0], headingDeg: 0)
        let uv = WallTextureProjection.projectPoint(
            photo: p,
            roomHeadingDeg: 90,
            point: SIMD3<Float>(-5, 0, 0)
        )
        XCTAssertNil(uv)
    }

    func testCompassNorthMatchesDollhouseSceneBuilder() {
        for roomHeading: Float in [0, 45, 90, 180, 270] {
            let northPhoto = photo([0, 0], headingDeg: 0)
            let rad = roomHeading * .pi / 180.0
            let northX = sin(rad)
            let northZ = cos(rad)
            let northPoint = SIMD3<Float>(
                northX * 5,
                WallTextureProjection.cameraHeightM,
                northZ * 5
            )
            let uv = WallTextureProjection.projectPoint(
                photo: northPhoto,
                roomHeadingDeg: roomHeading,
                point: northPoint
            )
            XCTAssertNotNil(uv, "heading \(roomHeading) should produce a UV")
            XCTAssertEqual(uv?.x ?? -1, 0.5, accuracy: 0.0001, "u at heading \(roomHeading)")
            XCTAssertEqual(uv?.y ?? -1, 0.5, accuracy: 0.0001, "v at heading \(roomHeading)")
        }
    }

    func testMostHeadOnPhotoWins() {
        let wallA = SIMD2<Float>(5, -2)
        let wallB = SIMD2<Float>(5, 2)
        let inward = SIMD2<Float>(-1, 0)
        let photos = [
            photo([0, 0], headingDeg: 225),
            photo([0, 0], headingDeg: 270),
            photo([0, 0], headingDeg: 315),
        ]
        let best = WallTextureProjection.pickWallPhoto(
            wallA: wallA,
            wallB: wallB,
            inwardNormal: inward,
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: photos
        )
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.headingDeg ?? -1, 270, accuracy: 0.01)
    }

    func testPhotoLookingAwayFromWallReturnsNil() {
        let away = [photo([0, 0], headingDeg: 90)]
        let result = WallTextureProjection.pickWallPhoto(
            wallA: SIMD2<Float>(5, -2),
            wallB: SIMD2<Float>(5, 2),
            inwardNormal: SIMD2<Float>(-1, 0),
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: away
        )
        XCTAssertNil(result)
    }

    func testPhotoAt90DegreesToWallReturnsNil() {
        let sideways = [photo([0, 0], headingDeg: 0)]
        let result = WallTextureProjection.pickWallPhoto(
            wallA: SIMD2<Float>(5, -2),
            wallB: SIMD2<Float>(5, 2),
            inwardNormal: SIMD2<Float>(-1, 0),
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: sideways
        )
        XCTAssertNil(result)
    }

    func testWallBehindCameraReturnsNil() {
        let behind = [photo([0, 0], headingDeg: 0)]
        let result = WallTextureProjection.pickWallPhoto(
            wallA: SIMD2<Float>(-5, -2),
            wallB: SIMD2<Float>(-5, 2),
            inwardNormal: SIMD2<Float>(1, 0),
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: behind
        )
        XCTAssertNil(result)
    }

    func testFourMeterWallWithMidpointInFramePasses() {
        let center = photo([0, 0], headingDeg: 270)
        let result = WallTextureProjection.pickWallPhoto(
            wallA: SIMD2<Float>(5, -2),
            wallB: SIMD2<Float>(5, 2),
            inwardNormal: SIMD2<Float>(-1, 0),
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: [center]
        )
        XCTAssertNotNil(result)
    }

    func testFortyMeterWallWithMidpointInFrameIsRejectedAsTooWide() {
        let center = photo([0, 0], headingDeg: 270)
        let result = WallTextureProjection.pickWallPhoto(
            wallA: SIMD2<Float>(5, -20),
            wallB: SIMD2<Float>(5, 20),
            inwardNormal: SIMD2<Float>(-1, 0),
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: [center]
        )
        XCTAssertNil(result)
    }

    func testTwoMeterWallFullyInFrameReturnsPhoto() {
        let center = photo([0, 0], headingDeg: 270)
        let result = WallTextureProjection.pickWallPhoto(
            wallA: SIMD2<Float>(5, -1),
            wallB: SIMD2<Float>(5, 1),
            inwardNormal: SIMD2<Float>(-1, 0),
            roomHeadingDeg: 0,
            wallHeightM: 2.5,
            photos: [center]
        )
        XCTAssertNotNil(result)
    }
}
