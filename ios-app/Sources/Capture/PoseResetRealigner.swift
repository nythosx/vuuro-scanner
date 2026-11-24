import Foundation
import simd

enum PoseResetRealigner {
    struct Fit: Equatable {
        let transform: simd_float4x4
        let inlierShare: Float
        let medianErrorM: Float
    }

    struct Outcome {
        let frames: [MeshFrame]
        let dropped: Int
        let realigned: Int
    }

    static let depthStride = 8
    static let framesPerSegment = 8
    static let maxSourcePoints = 2000
    static let maxMeshPoints = 150_000
    static let iterations = 15
    static let cellM: Float = 0.1
    static let startSearchM: Float = 0.3
    static let endSearchM: Float = 0.08
    static let inlierM: Float = 0.05
    static let minInlierShare: Float = 0.6
    static let maxMedianErrorM: Float = 0.03
    static let maxRotationDeg: Float = 20
    static let maxShiftM: Float = 1.5
    static let minDepthM: Float = 0.3
    static let maxDepthM: Float = 5

    final class Grid {
        let cell: Float
        private var cells: [SIMD3<Int32>: [SIMD3<Float>]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = cell
            for point in points {
                cells[key(point), default: []].append(point)
            }
        }

        var isEmpty: Bool { cells.isEmpty }

        private func key(_ point: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((point.x / cell).rounded(.down)), Int32((point.y / cell).rounded(.down)), Int32((point.z / cell).rounded(.down)))
        }

        func nearest(_ point: SIMD3<Float>, within radius: Float) -> SIMD3<Float>? {
            let center = key(point)
            let reach = Int32(max(1, (radius / cell).rounded(.up)))
            var best: SIMD3<Float>?
            var bestDistance = radius * radius
            for dx in -reach...reach {
                for dy in -reach...reach {
                    for dz in -reach...reach {
                        guard let list = cells[center &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for candidate in list {
                            let distance = simd_distance_squared(candidate, point)
                            if distance < bestDistance {
                                bestDistance = distance
                                best = candidate
                            }
                        }
                    }
                }
            }
            return best
        }
    }

    static func segments(_ resets: [LidarPoseReset]) -> [Range<Int>] {
        var byRoom: [Int: (first: Int, cuts: Set<Int>)] = [:]
        for reset in resets {
            var entry = byRoom[reset.room] ?? (reset.roomFirstKeyframe, [])
            entry.first = min(entry.first, reset.roomFirstKeyframe)
            entry.cuts.insert(reset.firstKeyframeAfter)
            byRoom[reset.room] = entry
        }
        var result: [Range<Int>] = []
        for entry in byRoom.values {
            var start = entry.first
            for cut in entry.cuts.sorted() where cut > start {
                result.append(start..<cut)
                start = cut
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func meshPoints(_ parts: [MeshPhotoTexturer.PartInput]) -> [SIMD3<Float>] {
        let total = parts.reduce(0) { $0 + $1.vertexCount }
        let step = max(1, total / maxMeshPoints)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(total, maxMeshPoints) + parts.count)
        for part in parts {
            part.vertices.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                guard floats.count >= part.vertexCount * 3 else { return }
                var index = 0
                while index < part.vertexCount {
                    let local = SIMD4<Float>(floats[index * 3], floats[index * 3 + 1], floats[index * 3 + 2], 1)
                    let world = part.transform * local
                    points.append(SIMD3<Float>(world.x, world.y, world.z))
                    index += step
                }
            }
        }
        return points
    }

    static func depthPoints(_ frame: MeshFrame, depth: [UInt16]) -> [SIMD3<Float>] {
        guard frame.depthWidth > 0, frame.depthHeight > 0, depth.count >= frame.depthWidth * frame.depthHeight,
              frame.fx > 0, frame.fy > 0, frame.imageWidth > 0, frame.imageHeight > 0 else { return [] }
        let scaleX = Float(frame.imageWidth) / Float(frame.depthWidth)
        let scaleY = Float(frame.imageHeight) / Float(frame.depthHeight)
        var points: [SIMD3<Float>] = []
        var v = depthStride / 2
        while v < frame.depthHeight {
            var u = depthStride / 2
            while u < frame.depthWidth {
                let meters = Float(depth[v * frame.depthWidth + u]) / 1000
                if meters >= minDepthM, meters <= maxDepthM {
                    let imageU = (Float(u) + 0.5) * scaleX
                    let imageV = (Float(v) + 0.5) * scaleY
                    let local = SIMD4<Float>((imageU - frame.cx) * meters / frame.fx, -(imageV - frame.cy) * meters / frame.fy, -meters, 1)
                    let world = frame.cameraTransform * local
                    points.append(SIMD3<Float>(world.x, world.y, world.z))
                }
                u += depthStride
            }
            v += depthStride
        }
        return points
    }

    static func rigidFit(source: [SIMD3<Float>], target: [SIMD3<Float>]) -> simd_float4x4? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let count = Float(source.count)
        let sourceMean = source.reduce(SIMD3<Float>.zero, +) / count
        let targetMean = target.reduce(SIMD3<Float>.zero, +) / count
        var s = simd_float3x3()
        for (p, q) in zip(source, target) {
            let a = p - sourceMean
            let b = q - targetMean
            s.columns.0 += a * b.x
            s.columns.1 += a * b.y
            s.columns.2 += a * b.z
        }
        let sxx = s.columns.0.x, sxy = s.columns.1.x, sxz = s.columns.2.x
        let syx = s.columns.0.y, syy = s.columns.1.y, syz = s.columns.2.y
        let szx = s.columns.0.z, szy = s.columns.1.z, szz = s.columns.2.z
        let n = simd_float4x4(rows: [
            SIMD4<Float>(sxx + syy + szz, syz - szy, szx - sxz, sxy - syx),
            SIMD4<Float>(syz - szy, sxx - syy - szz, sxy + syx, szx + sxz),
            SIMD4<Float>(szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy),
            SIMD4<Float>(sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz)
        ])
        var shift: Float = 0
        for column in 0..<4 { shift += simd_reduce_add(simd_abs(n[column])) }
        guard shift.isFinite, shift > 0 else { return nil }
        var power = (n + simd_float4x4(diagonal: SIMD4<Float>(repeating: shift))) * (1 / shift)
        for _ in 0..<40 {
            power = power * power
            var largest: Float = 0
            for column in 0..<4 { largest = max(largest, simd_reduce_max(simd_abs(power[column]))) }
            guard largest.isFinite, largest > 0 else { return nil }
            power = power * (1 / largest)
        }
        var vector = power[0]
        for column in 1..<4 where simd_length(power[column]) > simd_length(vector) {
            vector = power[column]
        }
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else { return nil }
        vector /= length
        if vector.x < 0 { vector = -vector }
        let rotation = simd_quatf(ix: vector.y, iy: vector.z, iz: vector.w, r: vector.x).normalized
        let translation = targetMean - rotation.act(sourceMean)
        var transform = simd_float4x4(rotation)
        transform.columns.3 = SIMD4<Float>(translation, 1)
        return transform
    }

    static func fit(source: [SIMD3<Float>], grid: Grid) -> Fit? {
        guard source.count >= 50, !grid.isEmpty else { return nil }
        var total = matrix_identity_float4x4
        var moved = source
        for step in 0..<iterations {
            let share = Float(step) / Float(max(iterations - 1, 1))
            let radius = startSearchM + (endSearchM - startSearchM) * share
            var from: [SIMD3<Float>] = []
            var to: [SIMD3<Float>] = []
            for point in moved {
                if let match = grid.nearest(point, within: radius) {
                    from.append(point)
                    to.append(match)
                }
            }
            guard let increment = rigidFit(source: from, target: to) else { return nil }
            total = increment * total
            moved = source.map { point in
                let world = total * SIMD4<Float>(point, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }
        }
        var errors: [Float] = []
        errors.reserveCapacity(moved.count)
        for point in moved {
            if let match = grid.nearest(point, within: inlierM * 2) {
                errors.append(simd_distance(point, match))
            } else {
                errors.append(.infinity)
            }
        }
        let inliers = errors.filter { $0 <= inlierM }.count
        let sorted = errors.sorted()
        let median = sorted[sorted.count / 2]
        return Fit(transform: total, inlierShare: Float(inliers) / Float(errors.count), medianErrorM: median)
    }

    static func accepts(_ fit: Fit) -> Bool {
        guard fit.inlierShare >= minInlierShare, fit.medianErrorM <= maxMedianErrorM else { return false }
        let rotation = simd_quatf(fit.transform)
        let degrees = abs(rotation.angle * 180 / .pi)
        let shift = simd_length(SIMD3<Float>(fit.transform.columns.3.x, fit.transform.columns.3.y, fit.transform.columns.3.z))
        return min(degrees, 360 - degrees) <= maxRotationDeg && shift <= maxShiftM
    }

    static func realign(frames: [MeshFrame], resets: [LidarPoseReset], meshPoints: [SIMD3<Float>], isCancelled: () -> Bool = { false }) -> Outcome {
        let usable = LidarPoseReset.usable(frames, resets: resets)
        guard usable.dropped > 0, !meshPoints.isEmpty else {
            return Outcome(frames: usable.frames, dropped: usable.dropped, realigned: 0)
        }
        let grid = Grid(points: meshPoints, cell: cellM)
        let keptIndexes = Set(usable.frames.map(\.index))
        let left = frames.filter { !keptIndexes.contains($0.index) }
        var recovered: [MeshFrame] = []
        for segment in segments(resets) {
            if isCancelled() { break }
            let members = left.filter { segment.contains($0.index) }
            guard !members.isEmpty else { continue }
            let withDepth = members.filter { $0.depthURL != nil && $0.depthWidth > 0 && $0.depthHeight > 0 }
            guard !withDepth.isEmpty else { continue }
            let pickStep = max(1, withDepth.count / framesPerSegment)
            var source: [SIMD3<Float>] = []
            var pick = 0
            while pick < withDepth.count, source.count < maxSourcePoints {
                if let depth = loadDepth(withDepth[pick]) {
                    source.append(contentsOf: depthPoints(withDepth[pick], depth: depth))
                }
                pick += pickStep
            }
            if source.count > maxSourcePoints {
                let thin = source.count / maxSourcePoints + 1
                source = stride(from: 0, to: source.count, by: thin).map { source[$0] }
            }
            guard let fit = fit(source: source, grid: grid) else { continue }
            DiagnosticsLog.shared.record(String(format: "Position reset frames %ld to %ld: %.0f%% of depth points on the mesh, median %.1f cm after aligning", segment.lowerBound, segment.upperBound - 1, fit.inlierShare * 100, fit.medianErrorM * 100), category: .state)
            guard accepts(fit) else { continue }
            recovered.append(contentsOf: members.map { $0.moved(by: fit.transform) })
        }
        let all = (usable.frames + recovered).sorted { $0.index < $1.index }
        return Outcome(frames: all, dropped: usable.dropped - recovered.count, realigned: recovered.count)
    }

    static func depthTargetPoints(_ frames: [MeshFrame]) -> [SIMD3<Float>] {
        let withDepth = frames.filter { $0.depthURL != nil && $0.depthWidth > 0 && $0.depthHeight > 0 }
        guard !withDepth.isEmpty else { return [] }
        let perFrame = max(1, (withDepth.first.map { ($0.depthWidth / depthStride) * ($0.depthHeight / depthStride) } ?? 1))
        let step = max(1, withDepth.count * perFrame / maxMeshPoints)
        var points: [SIMD3<Float>] = []
        var index = 0
        while index < withDepth.count, points.count < maxMeshPoints {
            if let depth = loadDepth(withDepth[index]) {
                points.append(contentsOf: depthPoints(withDepth[index], depth: depth))
            }
            index += step
        }
        return points
    }

    private static func loadDepth(_ frame: MeshFrame) -> [UInt16]? {
        guard let url = frame.depthURL else { return nil }
        let count = frame.depthWidth * frame.depthHeight
        guard count > 0, let data = FileManager.default.contents(atPath: url.path), data.count >= count * 2 else { return nil }
        var values = [UInt16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}

extension MeshFrame {
    func moved(by transform: simd_float4x4) -> MeshFrame {
        MeshFrame(
            index: index,
            cameraTransform: transform * cameraTransform,
            verticalFieldOfView: verticalFieldOfView,
            imageURL: imageURL,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy,
            depthURL: depthURL,
            confidenceURL: confidenceURL,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            motionDegPerS: motionDegPerS,
            blurPx: blurPx,
            timestamp: timestamp
        )
    }
}
