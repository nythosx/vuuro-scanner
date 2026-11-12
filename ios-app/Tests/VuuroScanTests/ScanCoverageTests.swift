import XCTest
import simd
@testable import VuuroScan

final class ScanCoverageTests: XCTestCase {
    private func patch(_ classification: UInt8, y: Float, xRange: ClosedRange<Int>, zRange: ClosedRange<Int>, normalY: Float = 1) -> [ScanCoverageFace] {
        var faces: [ScanCoverageFace] = []
        for x in xRange {
            for z in zRange {
                let center = SIMD3<Float>((Float(x) + 0.5) * ScanCoverageGrid.cellM, y, (Float(z) + 0.5) * ScanCoverageGrid.cellM)
                faces.append(ScanCoverageFace(center: center, normalY: normalY, classification: classification))
            }
        }
        return faces
    }

    private func grid(_ faces: [ScanCoverageFace]) -> ScanCoverageGrid {
        var grid = ScanCoverageGrid()
        grid.set(UUID(), cells: ScanCoverageGrid.cells(from: faces))
        return grid
    }

    func testCeilingWithoutFloorBelowIsMissing() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...9, zRange: 0...9)
            + patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...4, zRange: 0...9)
        let snapshot = grid(faces).snapshot(cameraTransform: nil, path: [])
        XCTAssertEqual(snapshot.floor.count, 50)
        XCTAssertEqual(snapshot.missing.count, 50)
        XCTAssertEqual(snapshot.floorPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(snapshot.floorMissingM2, 50 * 0.0625, accuracy: 0.0001)
    }

    func testWallsAndFurnitureAreNotMissingFloor() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...3, zRange: 0...3)
            + patch(ScanCoverageGrid.wallClass, y: 1.2, xRange: 0...0, zRange: 0...3, normalY: 0)
            + patch(ScanCoverageGrid.seatClass, y: 0.4, xRange: 1...2, zRange: 1...2)
            + patch(ScanCoverageGrid.floorClass, y: 0, xRange: 3...3, zRange: 0...3)
        let snapshot = grid(faces).snapshot(cameraTransform: nil, path: [])
        XCTAssertEqual(snapshot.wall.count, 4)
        XCTAssertEqual(snapshot.furniture.count, 4)
        XCTAssertEqual(snapshot.missing, [CoverageCell(x: 1, z: 0), CoverageCell(x: 2, z: 0), CoverageCell(x: 1, z: 3), CoverageCell(x: 2, z: 3)])
    }

    func testFlatUnclassifiedAtFloorHeightCountsAsFloor() {
        let faces = patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...0, zRange: 0...0)
            + patch(0, y: 0.05, xRange: 1...1, zRange: 0...0, normalY: -0.95)
            + patch(0, y: 0.9, xRange: 2...2, zRange: 0...0)
            + patch(0, y: 0.02, xRange: 3...3, zRange: 0...0, normalY: 0.2)
        let snapshot = grid(faces).snapshot(cameraTransform: nil, path: [])
        XCTAssertEqual(snapshot.floor, [CoverageCell(x: 0, z: 0), CoverageCell(x: 1, z: 0)])
    }

    func testRemovedAnchorsDropTheirCells() {
        var grid = ScanCoverageGrid()
        let kept = UUID()
        grid.set(kept, cells: ScanCoverageGrid.cells(from: patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...1, zRange: 0...0)))
        grid.set(UUID(), cells: ScanCoverageGrid.cells(from: patch(ScanCoverageGrid.floorClass, y: 0, xRange: 5...6, zRange: 0...0)))
        grid.keepOnly([kept])
        XCTAssertEqual(grid.snapshot(cameraTransform: nil, path: []).floor.count, 2)
    }

    func testLargestClusterIsChosen() {
        let small: Set<CoverageCell> = [CoverageCell(x: 0, z: 0), CoverageCell(x: 1, z: 0)]
        let big: Set<CoverageCell> = Set((10...12).flatMap { x in (0...1).map { CoverageCell(x: Int32(x), z: Int32($0)) } })
        XCTAssertEqual(Set(ScanCoverageGrid.largestCluster(small.union(big))), big)
    }

    func testHintDirectionFollowsWhereThePhoneFaces() {
        let forward = SIMD2<Float>(0, -1)
        func missing(around center: SIMD2<Float>) -> Set<CoverageCell> {
            let cell = ScanCoverageGrid.cell(center)
            return Set((-1...0).flatMap { dx in (-1...0).map { CoverageCell(x: cell.x + Int32(dx), z: cell.z + Int32($0)) } })
        }
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing(around: [0, -3]), camera: [0, 0], forward: forward)?.direction, .ahead)
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing(around: [3, 0]), camera: [0, 0], forward: forward)?.direction, .right)
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing(around: [-3, 0]), camera: [0, 0], forward: forward)?.direction, .left)
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing(around: [0, 3]), camera: [0, 0], forward: forward)?.direction, .behind)
    }

    func testTinyGapGivesNoHint() {
        let missing: Set<CoverageCell> = [CoverageCell(x: 4, z: 4), CoverageCell(x: 4, z: 5)]
        XCTAssertNil(ScanCoverageGrid.hint(missing: missing, camera: [0, 0], forward: [0, -1]))
    }

    func testIdentityCameraFacesNegativeZ() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: -1...0, zRange: -14...(-12))
        let snapshot = grid(faces).snapshot(cameraTransform: matrix_identity_float4x4, path: [])
        XCTAssertEqual(snapshot.cameraForward, SIMD2<Float>(0, -1))
        XCTAssertEqual(snapshot.hint?.direction, .ahead)
    }

    func testWallStripsTouchingMeshWallAreSeen() {
        let meshWall = Set((0...3).map { CoverageCell(x: Int32($0), z: 0) })
        let wall = ScanCoverageWall(start: [0, 0.1], end: [4, 0.1])
        let strips = ScanCoverageGrid.strips(for: [wall], meshWall: meshWall)
        XCTAssertEqual(strips.count, 8)
        XCTAssertEqual(strips.map(\.seen), [true, true, false, false, false, false, false, false])
        var snapshot = ScanCoverageSnapshot()
        snapshot.wallStrips = strips
        XCTAssertEqual(snapshot.wallMissingM, 3, accuracy: 0.0001)
        XCTAssertEqual(snapshot.wallPercent ?? -1, 25, accuracy: 0.001)
    }

    func testWallFromRoomPlanTransformRunsAlongItsXAxis() {
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(0, 0, 1, 0)
        transform.columns.2 = SIMD4<Float>(-1, 0, 0, 0)
        transform.columns.3 = SIMD4<Float>(2, 1.2, 3, 1)
        let wall = ScanCoverageWall(transform: transform, widthM: 4)
        XCTAssertEqual(wall?.start, SIMD2<Float>(2, 1))
        XCTAssertEqual(wall?.end, SIMD2<Float>(2, 5))
        XCTAssertNil(ScanCoverageWall(transform: transform, widthM: 0))
        XCTAssertNil(ScanCoverageWall(transform: transform, widthM: .nan))
    }

    func testNoWallsGivesNoWallPercent() {
        let snapshot = grid(patch(ScanCoverageGrid.wallClass, y: 1, xRange: 0...2, zRange: 0...0, normalY: 0)).snapshot(cameraTransform: nil, path: [])
        XCTAssertNil(snapshot.wallPercent)
        XCTAssertNil(LidarLiveCoverage(snapshot).wallSeenPercent)
    }

    private let squareRoom = [
        ScanCoverageWall(start: [0, 0], end: [4.2, 0]),
        ScanCoverageWall(start: [4, 0], end: [4, 4]),
        ScanCoverageWall(start: [4, 4], end: [0, 4]),
        ScanCoverageWall(start: [0, 4], end: [0, 0]),
    ]

    func testCornersAreWhereWallEndsMeet() {
        let meshWall: Set<CoverageCell> = [CoverageCell(x: 0, z: 0), CoverageCell(x: 1, z: 0), CoverageCell(x: 0, z: 1)]
        let corners = ScanCoverageGrid.corners(for: squareRoom, meshWall: meshWall)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners.filter(\.seen).count, 1)
        XCTAssertTrue(corners.first(where: { simd_distance($0.point, SIMD2<Float>(0, 0)) < 0.01 })?.seen ?? false)
    }

    func testLoneWallEndIsNotACorner() {
        let corners = ScanCoverageGrid.corners(for: [ScanCoverageWall(start: [0, 0], end: [3, 0])], meshWall: [])
        XCTAssertTrue(corners.isEmpty)
    }

    func testUnseenCornerGivesHintWhenFloorIsDone() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.5, 1.4, 3, 1)
        let snapshot = ScanCoverageGrid().snapshot(cameraTransform: transform, path: [], walls: squareRoom)
        XCTAssertEqual(snapshot.corners.count, 4)
        XCTAssertEqual(snapshot.hint?.target, .corner)
        XCTAssertEqual(snapshot.hint?.direction, .behind)
        XCTAssertEqual(snapshot.hint?.distanceM ?? 0, simd_distance(SIMD2<Float>(0.5, 3), [0, 4]), accuracy: 0.0001)
        let summary = LidarLiveCoverage(snapshot)
        XCTAssertEqual(summary.cornersSeen, 0)
        XCTAssertEqual(summary.cornersTotal, 4)
    }

    func testFloorHintComesBeforeCornerHint() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 4...7, zRange: 4...7)
        let snapshot = grid(faces).snapshot(cameraTransform: matrix_identity_float4x4, path: [], walls: squareRoom)
        XCTAssertEqual(snapshot.hint?.target, .floor)
    }

    func testStripsAreNeverLongerThanHalfAMetre() {
        let strips = ScanCoverageGrid.strips(for: [ScanCoverageWall(start: [0, 0], end: [0.7, 0])], meshWall: [])
        XCTAssertEqual(strips.count, 2)
        XCTAssertEqual(strips.map { simd_distance($0.start, $0.end) }.max() ?? 1, 0.35, accuracy: 0.0001)
    }

    func testNoCeilingGivesNoFloorPercent() {
        let snapshot = grid(patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...3, zRange: 0...3)).snapshot(cameraTransform: nil, path: [])
        XCTAssertEqual(snapshot.floor.count, 16)
        XCTAssertFalse(snapshot.ceilingSeen)
        XCTAssertNil(snapshot.floorPercent)
        XCTAssertNil(LidarLiveCoverage(snapshot).floorPercent)
    }

    func testUnclassifiedMeshStillFindsFloorAndCeiling() {
        let faces = patch(0, y: 0.02, xRange: 0...4, zRange: 0...3)
            + patch(0, y: 2.5, xRange: 0...4, zRange: 4...7, normalY: -1)
        let snapshot = grid(faces).snapshot(cameraTransform: nil, path: [])
        XCTAssertEqual(snapshot.floor.count, 20)
        XCTAssertEqual(snapshot.missing.count, 20)
        XCTAssertEqual(snapshot.floorPercent ?? -1, 50, accuracy: 0.001)
    }

    func testTooFewUnclassifiedCellsDoNotGuessAFloor() {
        let snapshot = grid(patch(0, y: 0.02, xRange: 0...3, zRange: 0...3)).snapshot(cameraTransform: nil, path: [])
        XCTAssertTrue(snapshot.floor.isEmpty)
    }

    func testThinnedPathKeepsEndsAndHalvesPoints() {
        let path = (0..<11).map { SIMD2<Float>(Float($0), 0) }
        let thinned = ScanCoverageTracker.thinned(path)
        XCTAssertEqual(thinned.count, 6)
        XCTAssertEqual(thinned.first, path.first)
        XCTAssertEqual(thinned.last, path.last)
        let even = (0..<10).map { SIMD2<Float>(Float($0), 0) }
        XCTAssertEqual(ScanCoverageTracker.thinned(even).count, 6)
        XCTAssertEqual(ScanCoverageTracker.thinned(even).last, even.last)
    }

    func testFloorBeyondScannedCeilingUsesRoomPlanArea() {
        let faces = patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...7, zRange: 0...7)
            + patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...1, zRange: 0...1)
        let onlyCeiling = grid(faces).snapshot(cameraTransform: nil, path: [])
        XCTAssertEqual(onlyCeiling.floorPercent ?? -1, 100, accuracy: 0.001)
        let withRoom = grid(faces).snapshot(cameraTransform: nil, path: [], roomAreaM2: 16)
        XCTAssertEqual(withRoom.floorPercent ?? -1, 25, accuracy: 0.001)
        let noCeilingWithRoom = grid(patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...7, zRange: 0...7)).snapshot(cameraTransform: nil, path: [], roomAreaM2: 8)
        XCTAssertEqual(noCeilingWithRoom.floorPercent ?? -1, 50, accuracy: 0.001)
    }

    func testFurnitureCountsAsFloorSeenAndPercentIsCapped() {
        XCTAssertEqual(ScanCoverageGrid.floorPercent(seenCells: 50, missingCells: 0, ceilingSeen: true, roomAreaM2: 1) ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(ScanCoverageGrid.floorPercent(seenCells: 50, missingCells: 0, ceilingSeen: false, roomAreaM2: .nan))
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...3, zRange: 0...0)
            + patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...1, zRange: 0...0)
            + patch(ScanCoverageGrid.seatClass, y: 0.4, xRange: 2...2, zRange: 0...0)
        XCTAssertEqual(grid(faces).snapshot(cameraTransform: nil, path: []).floorPercent ?? -1, 75, accuracy: 0.001)
    }

    func testShortWallIsNotACorner() {
        let corners = ScanCoverageGrid.corners(for: [ScanCoverageWall(start: [0, 0], end: [0.2, 0])], meshWall: [])
        XCTAssertTrue(corners.isEmpty)
    }

    private let earlierWallCells = Set((0...3).map { CoverageCell(x: Int32($0), z: 0) })
    private let sharedWall = ScanCoverageWall(start: [0, 0.1], end: [1, 0.1])

    func testEarlierRoomWallCountsForStripsButIsNotDrawn() {
        var room = grid(patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...3, zRange: 2...4))
        room.contextWalls = [ScanCoverageGrid.ContextWall(cells: earlierWallCells, floorY: 0.05)]
        let snapshot = room.snapshot(cameraTransform: nil, path: [], walls: [sharedWall])
        XCTAssertEqual(snapshot.wallStrips.map(\.seen), [true, true])
        XCTAssertTrue(snapshot.wall.isEmpty)
        XCTAssertTrue(room.ownWall.isEmpty)
    }

    func testWallFromAnotherStoreyDoesNotCount() {
        var room = grid(patch(ScanCoverageGrid.floorClass, y: 2.9, xRange: 0...3, zRange: 2...4))
        room.contextWalls = [ScanCoverageGrid.ContextWall(cells: earlierWallCells, floorY: 0)]
        let snapshot = room.snapshot(cameraTransform: nil, path: [], walls: [sharedWall])
        XCTAssertEqual(snapshot.wallStrips.map(\.seen), [false, false])
    }

    func testEarlierWallIsNotMissingFloorUnderTheCeiling() {
        let faces = patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...3, zRange: 1...1)
            + patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...3, zRange: 0...1)
        var room = grid(faces)
        room.contextWalls = [ScanCoverageGrid.ContextWall(cells: earlierWallCells, floorY: 0)]
        let snapshot = room.snapshot(cameraTransform: nil, path: [])
        XCTAssertTrue(snapshot.missing.isEmpty)
    }

    func testRoomContextKeepsEarlierRoomsWithTheirFloorHeight() {
        let room = grid(patch(ScanCoverageGrid.floorClass, y: 0.02, xRange: 0...3, zRange: 1...1)
            + patch(ScanCoverageGrid.wallClass, y: 1.2, xRange: 0...3, zRange: 0...0, normalY: 0))
        let context = room.roomContext()
        XCTAssertEqual(context.count, 1)
        XCTAssertEqual(context.first?.cells, earlierWallCells)
        XCTAssertEqual(context.first?.floorY ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertTrue(grid(patch(ScanCoverageGrid.wallClass, y: 1.2, xRange: 0...3, zRange: 0...0, normalY: 0)).roomContext().isEmpty)
    }

    func testMissingWallGivesHintWhenFloorAndCornersAreDone() {
        let snapshot = ScanCoverageGrid().snapshot(cameraTransform: matrix_identity_float4x4, path: [], walls: [ScanCoverageWall(start: [-1, -3], end: [1, -3])])
        XCTAssertTrue(snapshot.corners.isEmpty)
        XCTAssertEqual(snapshot.hint?.target, .wall)
        XCTAssertEqual(snapshot.hint?.direction, .ahead)
    }

    private func meshCopy(vertices: [Float], indices: [UInt32], classes: [UInt8], transform: simd_float4x4 = matrix_identity_float4x4) -> ScanCoverageMeshCopy {
        ScanCoverageMeshCopy(
            transform: transform,
            vertices: vertices.withUnsafeBufferPointer { Data(buffer: $0) },
            vertexStride: 12,
            vertexCount: vertices.count / 3,
            indices: indices.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerIndex: 4,
            faceCount: indices.count / 3,
            classes: Data(classes),
            classStride: 1,
            classCount: classes.count
        )
    }

    func testMeshCopyReadsWorldCentresAndClasses() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 0, 0, 1)
        let mesh = meshCopy(vertices: [0, 0, 0, 0.1, 0, 0, 0, 0, 0.1, 0.1, 0, 0.1], indices: [0, 2, 1, 1, 2, 3], classes: [2, 2], transform: transform)
        let faces = mesh.faces()
        XCTAssertEqual(faces.count, 2)
        XCTAssertEqual(faces[0].center.x, 10 + 0.1 / 3, accuracy: 0.0001)
        XCTAssertEqual(abs(faces[0].normalY), 1, accuracy: 0.0001)
        XCTAssertEqual(faces.map(\.classification), [2, 2])
    }

    func testLargeTriangleMarksMoreThanOneCell() {
        let mesh = meshCopy(vertices: [0, 0, 0, 1, 0, 0, 0, 0, 1], indices: [0, 2, 1], classes: [2])
        let faces = mesh.faces()
        XCTAssertEqual(faces.count, 4)
        XCTAssertGreaterThan(ScanCoverageGrid.cells(from: faces).floor.count, 1)
    }

    func testBrokenMeshCopyGivesNoFaces() {
        XCTAssertEqual(meshCopy(vertices: [0, 0, 0], indices: [0, 1, 2], classes: []).faces().count, 0)
        var short = meshCopy(vertices: [0, 0, 0, 1, 0, 0, 0, 0, 1], indices: [0, 2, 1], classes: [2])
        short.indices = Data([0, 0])
        XCTAssertEqual(short.faces().count, 0)
    }

    func testAnchorKeyIgnoresSubMillimetreJitter() {
        let key = ScanCoverageTracker.AnchorKey(vertices: 10, faces: 12, position: [1.2341, 0, -2])
        XCTAssertEqual(key, ScanCoverageTracker.AnchorKey(vertices: 10, faces: 12, position: [1.23412, 0.0001, -2.0002]))
        XCTAssertNotEqual(key, ScanCoverageTracker.AnchorKey(vertices: 10, faces: 12, position: [1.2391, 0, -2]))
        XCTAssertEqual(ScanCoverageTracker.AnchorKey.millimetres(.nan), 0)
    }

    func testStraightWallSplitByRoomPlanIsNotACorner() {
        let walls = [ScanCoverageWall(start: [0, 0], end: [2.31, 0]), ScanCoverageWall(start: [2.31, 0], end: [5.06, 0.02])]
        XCTAssertTrue(ScanCoverageGrid.corners(for: walls, meshWall: []).isEmpty)
        let turned = [ScanCoverageWall(start: [0, 0], end: [2.31, 0]), ScanCoverageWall(start: [2.31, 0], end: [2.31, 3])]
        XCTAssertEqual(ScanCoverageGrid.corners(for: turned, meshWall: []).count, 1)
    }

    func testWallEndJoinsTheNearestCorner() {
        let walls = [
            ScanCoverageWall(start: [0, 0], end: [0, -3]),
            ScanCoverageWall(start: [0.6, 0], end: [0.6, 3]),
            ScanCoverageWall(start: [0.32, 0], end: [3, 0]),
        ]
        let corners = ScanCoverageGrid.corners(for: walls, meshWall: [])
        XCTAssertEqual(corners.count, 1)
        XCTAssertEqual(corners.first?.point.x ?? -1, 0.46, accuracy: 0.0001)
    }

    func testHintFollowsTheLatestCamera() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: -1...0, zRange: -14...(-12))
        let snapshot = grid(faces).snapshot(cameraTransform: matrix_identity_float4x4, path: [])
        XCTAssertEqual(snapshot.hint?.direction, .ahead)
        var later = matrix_identity_float4x4
        later.columns.3 = SIMD4<Float>(0, 1.4, -6, 1)
        let moved = ScanCoverageGrid.moved(snapshot, to: later)
        XCTAssertEqual(moved.hint?.direction, .behind)
        XCTAssertEqual(moved.camera, SIMD2<Float>(0, -6))
        XCTAssertEqual(moved.hint?.center, snapshot.hint?.center)
    }

    func testSummarySaysWhetherCeilingWasSeen() throws {
        let noCeiling = LidarLiveCoverage(grid(patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...1, zRange: 0...0)).snapshot(cameraTransform: nil, path: []))
        XCTAssertEqual(noCeiling.ceilingSeen, false)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noCeiling)) as? [String: Any]
        XCTAssertEqual(json?["ceiling_seen"] as? Bool, false)
    }

    func testHighFlatUnclassifiedIsCeilingEvenWithClassifiedFloor() {
        let faces = patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...1, zRange: 0...0)
            + patch(0, y: 2.6, xRange: 0...3, zRange: 1...1, normalY: -1)
            + patch(0, y: 1.0, xRange: 0...3, zRange: 2...2)
        let snapshot = grid(faces).snapshot(cameraTransform: nil, path: [])
        XCTAssertTrue(snapshot.ceilingSeen)
        XCTAssertEqual(snapshot.missing.count, 4)
    }

    func testSummaryKeepsTheNumbers() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...3, zRange: 0...0)
            + patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...2, zRange: 0...0)
        let summary = LidarLiveCoverage(grid(faces).snapshot(cameraTransform: nil, path: []))
        XCTAssertEqual(summary.floorPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(summary.floorSeenM2, 3 * 0.0625, accuracy: 0.0001)
        let decoded = try? JSONDecoder().decode(LidarLiveCoverage.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded, summary)
    }
    func testFloorPercentUsesTheScannedCeilingOnceItCoversMostOfTheRoom() {
        XCTAssertEqual(ScanCoverageGrid.floorPercent(seenCells: 830, missingCells: 24, ceilingSeen: true, roomAreaM2: 60.5) ?? -1, 830.0 / 854.0 * 100, accuracy: 0.001)
        XCTAssertEqual(ScanCoverageGrid.floorPercent(seenCells: 100, missingCells: 0, ceilingSeen: true, roomAreaM2: 60.5) ?? -1, 100.0 / 968.0 * 100, accuracy: 0.001)
        XCTAssertEqual(ScanCoverageGrid.floorPercent(seenCells: 650, missingCells: 20, ceilingSeen: true, roomAreaM2: 60.5, seenUnderCeilingCells: 650, floorUnderCeilingCells: 670) ?? -1, 650.0 / 670.0 * 100, accuracy: 0.001)
        XCTAssertEqual(ScanCoverageGrid.floorPercent(seenCells: 100, missingCells: 0, ceilingSeen: true, roomAreaM2: 60.5, seenUnderCeilingCells: 100, floorUnderCeilingCells: 100) ?? -1, 100.0 / 968.0 * 100, accuracy: 0.001)
    }

    func testStairsAreNotMissingFloor() {
        let faces = patch(ScanCoverageGrid.ceilingClass, y: 2.5, xRange: 0...9, zRange: 0...9)
            + patch(ScanCoverageGrid.floorClass, y: 0, xRange: 0...4, zRange: 0...9)
        let stair = ScanCoverageStair(center: [1.875, 1.25], axis: [1, 0], lengthM: 1.25, depthM: 2.5)
        let snapshot = grid(faces).snapshot(cameraTransform: nil, path: [], stairs: [stair])
        XCTAssertTrue(snapshot.missing.isEmpty)
        XCTAssertFalse(snapshot.stairs.isEmpty)
        XCTAssertEqual(snapshot.floorPercent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(grid(faces).snapshot(cameraTransform: nil, path: []).missing.count, 50)
    }

    func testStairFromRoomPlanTransformCoversItsFootprint() throws {
        let stair = try XCTUnwrap(ScanCoverageStair(transform: matrix_identity_float4x4, dimensions: [1, 2, 3]))
        XCTAssertTrue(stair.contains([0.4, 1.4]))
        XCTAssertFalse(stair.contains([0.7, 0]))
        XCTAssertEqual(stair.areaM2, 3, accuracy: 0.001)
        XCTAssertNil(ScanCoverageStair(transform: matrix_identity_float4x4, dimensions: [0, 2, 3]))
        XCTAssertNil(ScanCoverageStair(transform: matrix_identity_float4x4, dimensions: [.nan, 2, 3]))
    }

    func testFloorHintSkipsAGapMarkedAsStuck() {
        func block(_ center: SIMD2<Float>, _ half: Int32) -> Set<CoverageCell> {
            let cell = ScanCoverageGrid.cell(center)
            return Set((-half...half).flatMap { dx in (-half...half).map { CoverageCell(x: cell.x + dx, z: cell.z + $0) } })
        }
        let missing = block([0, -3], 2).union(block([3, 0], 1))
        let forward = SIMD2<Float>(0, -1)
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing, camera: [0, 0], forward: forward)?.direction, .ahead)
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing, camera: [0, 0], forward: forward)?.cells, 25)
        XCTAssertEqual(ScanCoverageGrid.hint(missing: missing, camera: [0, 0], forward: forward, skipNear: [[0, -3]])?.direction, .right)
        XCTAssertNil(ScanCoverageGrid.hint(missing: missing, camera: [0, 0], forward: forward, skipNear: [[0, -3], [3, 0]]))
    }

    func testFloorHintWatchMarksAGapThatDoesNotShrink() {
        var watch = ScanCoverageFloorHintWatch()
        let hint = ScanCoverageHint(direction: .ahead, distanceM: 2, center: [0, -3], cells: 10)
        XCTAssertFalse(watch.update(hint, at: 0))
        XCTAssertFalse(watch.update(hint, at: 5))
        XCTAssertTrue(watch.update(hint, at: 10.5))
        XCTAssertEqual(watch.skipped, [[0, -3]])
    }

    func testFloorHintWatchRestartsWhenTheGapShrinks() {
        var watch = ScanCoverageFloorHintWatch()
        XCTAssertFalse(watch.update(ScanCoverageHint(direction: .ahead, distanceM: 2, center: [0, -3], cells: 10), at: 0))
        XCTAssertFalse(watch.update(ScanCoverageHint(direction: .ahead, distanceM: 2, center: [0.2, -3], cells: 7), at: 8))
        XCTAssertFalse(watch.update(ScanCoverageHint(direction: .ahead, distanceM: 2, center: [0.2, -3], cells: 7), at: 15))
        XCTAssertTrue(watch.update(ScanCoverageHint(direction: .ahead, distanceM: 2, center: [0.2, -3], cells: 7), at: 18.5))
    }

    func testFloorHintWatchIgnoresCornerAndWallHints() {
        var watch = ScanCoverageFloorHintWatch()
        let corner = ScanCoverageHint(target: .corner, direction: .ahead, distanceM: 2, center: [0, -3])
        XCTAssertFalse(watch.update(corner, at: 0))
        XCTAssertFalse(watch.update(corner, at: 30))
        XCTAssertTrue(watch.skipped.isEmpty)
    }

    func testMovedHintKeepsItsGapSize() {
        var snapshot = ScanCoverageSnapshot()
        snapshot.hint = ScanCoverageHint(direction: .ahead, distanceM: 2, center: [0, -3], cells: 12)
        XCTAssertEqual(ScanCoverageGrid.moved(snapshot, to: matrix_identity_float4x4).hint?.cells, 12)
    }

    func testHintArrowMatchesTheDirection() {
        XCTAssertEqual(ScanCoverageMapView.hintSymbol(.ahead), "arrow.up")
        XCTAssertEqual(ScanCoverageMapView.hintSymbol(.left), "arrow.left")
        XCTAssertEqual(ScanCoverageMapView.hintSymbol(.right), "arrow.right")
        XCTAssertEqual(ScanCoverageMapView.hintSymbol(.behind), "arrow.down")
    }
}
