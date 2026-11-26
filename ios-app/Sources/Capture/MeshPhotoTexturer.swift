import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import os
import simd

enum MeshPhotoTexturer {
    struct PartInput {
        let vertices: Data
        let vertexCount: Int
        let faces: Data
        let faceCount: Int
        let classes: Data?
        let transform: simd_float4x4
    }

    struct Group: Equatable {
        let slot: Int
        let classId: UInt8
        let start: Int
        let count: Int
    }

    struct PartOutput {
        let positions: Data
        let uvs: Data
        let colors: Data
        let vertexCount: Int
        let groups: [Group]
    }

    struct Output {
        let parts: [PartOutput]
        let images: [CGImage?]
        let photosUnreadable: Int
        let facesInPhoto: Int
        let facesFilled: Int
        let totalFaces: Int
        let photosUsed: Int
        let gains: [Float]
        var photosLinedUp = 0
        var photosChecked = 0
        var photoLimit = 0
        var photosInTexture = 0
        var photoLongSide = 0
        var photosNudged = 0
    }

    struct PartState {
        let valid: [Bool]
        let slots: [Int]
        let uvs: [Float]
    }

    struct Camera {
        let view: simd_float4x4
        let position: SIMD3<Float>
        let width: Float
        let height: Float
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let depth: [UInt16]?
        let depthWidth: Int
        let depthHeight: Int
        var blurPenalty: Float = 1
        var confidence: [UInt8]? = nil
        var brightness: Luminance? = nil
    }

    final class Monitor: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        private var stopped = false
        private var done = 0
        private var stageStartedAt = ProcessInfo.processInfo.systemUptime
        private var finished: [MeshPhotoBuildLog.Stage] = []

        var stages: [MeshPhotoBuildLog.Stage] {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func endStage(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            finished.append(MeshPhotoBuildLog.Stage(name: name, seconds: now - stageStartedAt))
            stageStartedAt = now
            lock.unlock()
        }

        var fraction: Double {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func cancel() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        func report(_ fraction: Double) {
            lock.lock()
            value = max(value, min(max(fraction, 0), 1))
            lock.unlock()
        }

        func beginStage() {
            lock.lock()
            done = 0
            lock.unlock()
        }

        func tick(of total: Int, from start: Double, to end: Double) {
            lock.lock()
            done += 1
            let next = start + (end - start) * Double(done) / Double(max(total, 1))
            value = max(value, min(next, 1))
            lock.unlock()
        }
    }

    static let maxCandidates = 240
    static let minAvailableMemoryBytes = 200 * 1_048_576
    static let minTextures = 24
    static let maxTextures = 160
    static let facesPerTexture = 5000
    static let bytesPerTexture = 24 * 1_048_576
    static let cornerInset: Float = 0.25
    static let minBestFaces = 150
    static let textureSize = 2048
    static let gainSampleSize = 160
    static let maxGain: Float = 1.6
    static let chunkFaces = 4096
    static let minDistance: Float = 0.1
    static let maxDistance: Float = 6
    static let minFacing: Float = 0.2
    static let relaxedMinFacing: Float = 0.05
    static let fillRings = 12
    static let smoothRounds = 4
    static let smoothSlack: Float = 1.2
    static let seamRounds = 30
    static let seamMinShade: Float = 0.6
    static let hiddenClasses: Set<UInt8> = [3, 9]
    static let blownOutLevel: UInt8 = 250
    static let tooDarkLevel: UInt8 = 6
    static let badExposurePenalty: Float = 4
    static let gainSampleCeiling: Float = 0.96
    static let invalidPoint = SIMD3<Float>(repeating: 1e9)

    static func texture(parts: [PartInput], frames: [MeshFrame], monitor: Monitor = Monitor()) -> Result<Output, Error> {
        func stopped() -> Bool { monitor.isCancelled || Task.isCancelled }
        let usable = frames.filter { $0.imageURL != nil }
        guard !usable.isEmpty else {
            return .failure(PlainError(message: "This capture has no frame photos."))
        }
        let step = max(1, (usable.count + maxCandidates - 1) / maxCandidates)
        let candidates = stride(from: 0, to: usable.count, by: step).map { usable[$0] }
        var cameras: [Camera] = []
        cameras.reserveCapacity(candidates.count)
        let meshGrid = PoseResetRealigner.Grid(points: PoseResetRealigner.meshPoints(parts), cell: PoseResetRealigner.cellM)
        var nudged = 0
        monitor.beginStage()
        for frame in candidates {
            if stopped() { return .failure(CancellationError()) }
            var built: Camera
            if let corrected = PoseResetRealigner.correctDrift(frame, grid: meshGrid) {
                built = camera(corrected)
                nudged += 1
            } else {
                built = camera(frame)
            }
            if let url = frame.imageURL, let sample = loadLuminance(url) {
                built.brightness = Luminance(width: sample.width, height: sample.height, values: sample.values)
            }
            cameras.append(built)
            monitor.tick(of: candidates.count, from: 0, to: 0.15)
        }
        monitor.endStage("photo depth")
        let world = parts.map(worldVertices)
        let totalFaces = parts.reduce(0) { $0 + $1.faceCount }
        guard totalFaces > 0 else {
            return .failure(PlainError(message: "The mesh has no triangles to texture."))
        }

        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(totalFaces * 3)
        var partStart: [Int] = []
        for (part, input) in parts.enumerated() {
            partStart.append(corners.count / 3)
            forEachFace(input, world: world[part]) { _, a, b, c in
                corners.append(a)
                corners.append(b)
                corners.append(c)
            }
        }
        let faceTotal = corners.count / 3
        let words = (faceTotal + 63) / 64
        var (visible, bestCamera) = visibility(corners: corners, faceTotal: faceTotal, words: words, cameras: cameras, monitor: monitor)
        monitor.endStage("visibility")
        if stopped() { return .failure(CancellationError()) }
        let limit = textureLimit(faces: faceTotal, available: Int(os_proc_available_memory()))
        let kept = choosePhotos(visible: visible, cameras: cameras.count, words: words, limit: limit, steadiness: candidates.map { steadiness(motionDegPerS: $0.motionDegPerS, blurPx: $0.blurPx) }, bestCamera: bestCamera, minBest: max(minBestFaces, faceTotal / 2000))
        bestCamera = []
        guard !kept.isEmpty else {
            return .failure(PlainError(message: "No triangle of the mesh is seen clearly in a photo."))
        }

        var states: [PartState] = []
        var inPhoto = 0
        var filled = 0
        let keptCameras = kept.map { cameras[$0] }
        monitor.beginStage()
        for (part, input) in parts.enumerated() {
            if stopped() { return .failure(CancellationError()) }
            let base = partStart[part]
            let points = world[part]
            var slots = [Int](repeating: -1, count: input.faceCount)
            var faceUVs = [Float](repeating: 0, count: input.faceCount * 6)
            var valid = [Bool](repeating: false, count: input.faceCount)
            var best = [Float](repeating: .greatestFiniteMagnitude, count: input.faceCount)
            var cancelledHere = false
            forEachFace(input, world: points) { face, a, b, c in
                guard a != invalidPoint else { return }
                valid[face] = true
                if face % 256 == 0, monitor.isCancelled { cancelledHere = true }
                if cancelledHere { return }
                let global = base + face
                for (mapped, index) in kept.enumerated() where isVisible(visible, camera: index, face: global, words: words) {
                    guard let value = score(a, b, c, cameras[index]), value < best[face], let coords = clampedUVs(a, b, c, cameras[index]) else { continue }
                    best[face] = value
                    slots[face] = mapped
                    faceUVs.replaceSubrange((face * 6)..<(face * 6 + 6), with: coords)
                }
            }
            if stopped() { return .failure(CancellationError()) }
            let facesOf = facesByVertex(input, vertexCount: points.count, valid: valid)
            smoothChoices(input, world: points, facesOf: facesOf, valid: valid, best: best, slots: &slots, uvs: &faceUVs, cameras: keptCameras, isVisible: { slot, face in
                isVisible(visible, camera: kept[slot], face: base + face, words: words)
            }, isCancelled: stopped)
            for face in 0..<input.faceCount where valid[face] {
                if slots[face] >= 0 {
                    inPhoto += 1
                    continue
                }
                if face % 256 == 0, stopped() { break }
                let (a, b, c) = facePoints(input, world: points, face: face)
                var bestRelaxed = Float.greatestFiniteMagnitude
                for (mapped, camera) in keptCameras.enumerated() {
                    guard let value = score(a, b, c, camera, relaxed: true), value < bestRelaxed, let coords = clampedUVs(a, b, c, camera) else { continue }
                    bestRelaxed = value
                    slots[face] = mapped
                    faceUVs.replaceSubrange((face * 6)..<(face * 6 + 6), with: coords)
                }
                if slots[face] >= 0 { filled += 1 }
            }
            if stopped() { return .failure(CancellationError()) }
            filled += fillFromNeighbours(input, world: points, valid: valid, slots: &slots, uvs: &faceUVs, cameras: keptCameras, facesOf: facesOf, isCancelled: stopped)
            states.append(PartState(valid: valid, slots: slots, uvs: faceUVs))
            monitor.tick(of: parts.count, from: 0.7, to: 0.85)
        }
        monitor.endStage("picking photos")

        if stopped() { return .failure(CancellationError()) }
        var centroids: [SIMD3<Float>] = []
        centroids.reserveCapacity(faceTotal)
        for face in 0..<faceTotal {
            centroids.append((corners[face * 3] + corners[face * 3 + 1] + corners[face * 3 + 2]) / 3)
        }
        let samples = kept.map { index in candidates[index].imageURL.flatMap(loadLuminance) }
        let pairs = gainPairs(kept: kept, visible: visible, words: words, centroids: centroids, cameras: cameras, samples: samples)
        if stopped() { return .failure(CancellationError()) }
        let gains = levelGains(pairs: pairs, count: kept.count)
        monitor.report(0.9)
        monitor.endStage("brightness")
        corners = []
        centroids = []
        visible = []
        let slotsInUse = Set(states.flatMap(\.slots).filter { $0 >= 0 })

        var outputs: [PartOutput] = []
        monitor.beginStage()
        for (part, input) in parts.enumerated() {
            if stopped() { return .failure(CancellationError()) }
            let state = states[part]
            let tints = seamTints(input, world: world[part], valid: state.valid, slots: state.slots, cameras: keptCameras, samples: samples, gains: gains, isCancelled: stopped)
            let local = localFloats(input)
            var positionsBy: [Int: [Float]] = [:]
            var uvsBy: [Int: [Float]] = [:]
            var colorsBy: [Int: [Float]] = [:]
            for face in 0..<input.faceCount where state.valid[face] {
                let key = (state.slots[face] + 1) * 256 + Int(faceClass(input, face))
                for corner in 0..<3 {
                    let index = Int(faceIndex(input, face, corner))
                    positionsBy[key, default: []].append(contentsOf: local[(index * 3)..<(index * 3 + 3)])
                    let tint = tints[face * 3 + corner]
                    colorsBy[key, default: []].append(contentsOf: [tint.x, tint.y, tint.z])
                }
                uvsBy[key, default: []].append(contentsOf: state.uvs[(face * 6)..<(face * 6 + 6)])
            }
            var positions: [Float] = []
            var uvs: [Float] = []
            var colors: [Float] = []
            var groups: [Group] = []
            for key in positionsBy.keys.sorted() {
                guard let bucketPositions = positionsBy[key], let bucketUVs = uvsBy[key], let bucketColors = colorsBy[key] else { continue }
                let start = positions.count / 3
                positions.append(contentsOf: bucketPositions)
                uvs.append(contentsOf: bucketUVs)
                colors.append(contentsOf: bucketColors)
                groups.append(Group(slot: key / 256 - 1, classId: UInt8(key % 256), start: start, count: bucketPositions.count / 3))
            }
            outputs.append(PartOutput(
                positions: positions.withUnsafeBufferPointer { Data(buffer: $0) },
                uvs: uvs.withUnsafeBufferPointer { Data(buffer: $0) },
                colors: colors.withUnsafeBufferPointer { Data(buffer: $0) },
                vertexCount: positions.count / 3,
                groups: groups
            ))
            monitor.tick(of: parts.count, from: 0.9, to: 0.92)
        }
        states = []
        monitor.endStage("seams")

        var images: [CGImage?] = []
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        monitor.beginStage()
        for (slot, index) in kept.enumerated() {
            if stopped() { return .failure(CancellationError()) }
            if lowMemory(available: Int(os_proc_available_memory())) {
                return .failure(PlainError(message: "The phone is low on memory for the photo texture. Close other apps and try again."))
            }
            if let url = candidates[index].imageURL, let image = loadImage(url) {
                images.append(applyGain(gains[slot], to: image, context: context))
            } else {
                images.append(nil)
            }
            monitor.tick(of: kept.count, from: 0.92, to: 1)
        }
        monitor.endStage("loading photos")
        let unreadable = images.filter { $0 == nil }.count
        guard unreadable < images.count else {
            return .failure(PlainError(message: "None of the chosen frame photos could be opened for the texture."))
        }
        let inTexture = slotsInUse.filter { images.indices.contains($0) && images[$0] != nil }.count
        return .success(Output(parts: outputs, images: images, photosUnreadable: unreadable, facesInPhoto: inPhoto, facesFilled: filled, totalFaces: totalFaces, photosUsed: kept.count, gains: gains, photosLinedUp: usable.count, photosChecked: candidates.count, photoLimit: limit, photosInTexture: inTexture, photoLongSide: images.compactMap { image in image.map { max($0.width, $0.height) } }.max() ?? 0, photosNudged: nudged))
    }

    static func textureLimit(faces: Int, available: Int) -> Int {
        let byMesh = min(max(faces / facesPerTexture, minTextures), maxTextures)
        guard available > 0 else { return byMesh }
        let byMemory = max(0, available - 2 * minAvailableMemoryBytes) / bytesPerTexture
        return max(1, min(byMesh, byMemory))
    }

    static func choosePhotos(visible: [UInt64], cameras: Int, words: Int, limit: Int, steadiness: [Float] = [], bestCamera: [Int32], minBest: Int) -> [Int] {
        let covering = coverCameras(visible: visible, cameras: cameras, words: words, limit: limit, steadiness: steadiness)
        guard !covering.isEmpty, covering.count < limit else { return covering }
        var counts = [Int](repeating: 0, count: cameras)
        for camera in bestCamera where camera >= 0 && Int(camera) < cameras {
            counts[Int(camera)] += 1
        }
        let chosen = Set(covering)
        let extra = (0..<cameras)
            .filter { !chosen.contains($0) && counts[$0] >= minBest }
            .sorted { counts[$0] > counts[$1] || (counts[$0] == counts[$1] && $0 < $1) }
            .prefix(limit - covering.count)
        return (covering + extra).sorted()
    }

    static func lowMemory(available: Int) -> Bool {
        available > 0 && available < minAvailableMemoryBytes
    }

    static func steadiness(motionDegPerS: Float, blurPx: Float? = nil) -> Float {
        if let blurPx, blurPx.isFinite { return 1 / (1 + max(0, blurPx) / LidarMotionSpeed.holdBlurPx) }
        return 1 / (1 + max(0, motionDegPerS) / LidarMotionSpeed.steadyAngularDegPerS)
    }

    static func coverCameras(visible: [UInt64], cameras: Int, words: Int, limit: Int, steadiness: [Float] = []) -> [Int] {
        guard words > 0, visible.count >= cameras * words else { return [] }
        var cover = [UInt64](repeating: 0, count: words)
        var chosen: [Int] = []
        var used = Set<Int>()
        while chosen.count < limit {
            var best = -1
            var bestGain: Float = 0
            for camera in 0..<cameras where !used.contains(camera) {
                let base = camera * words
                var gain = 0
                for word in 0..<words {
                    gain += (visible[base + word] & ~cover[word]).nonzeroBitCount
                }
                let weighted = Float(gain) * (camera < steadiness.count ? steadiness[camera] : 1)
                if weighted > bestGain {
                    bestGain = weighted
                    best = camera
                }
            }
            guard best >= 0 else { break }
            chosen.append(best)
            used.insert(best)
            let base = best * words
            for word in 0..<words {
                cover[word] |= visible[base + word]
            }
        }
        return chosen.sorted()
    }

    static func levelGains(pairs: [(Int, Int, Float)], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var logs = [Float](repeating: 0, count: count)
        guard !pairs.isEmpty else { return logs.map { _ in 1 } }
        var linked = [Bool](repeating: false, count: count)
        for (a, b, _) in pairs {
            linked[a] = true
            linked[b] = true
        }
        let linkedCount = Float(linked.filter { $0 }.count)
        for _ in 0..<100 {
            var sum = [Float](repeating: 0, count: count)
            var seen = [Int](repeating: 0, count: count)
            for (a, b, ratio) in pairs {
                sum[a] += logs[b] + ratio
                seen[a] += 1
                sum[b] += logs[a] - ratio
                seen[b] += 1
            }
            var next = logs
            for index in 0..<count where seen[index] > 0 {
                next[index] = (logs[index] + sum[index] / Float(seen[index])) / 2
            }
            let mean = next.indices.reduce(Float(0)) { linked[$1] ? $0 + next[$1] : $0 } / linkedCount
            logs = next.indices.map { linked[$0] ? next[$0] - mean : 0 }
        }
        let limit = log(maxGain)
        return logs.map { exp(min(max($0, -limit), limit)) }
    }

    static func project(_ point: SIMD3<Float>, _ camera: Camera) -> SIMD2<Float>? {
        let local = camera.view * SIMD4<Float>(point, 1)
        let distance = -local.z
        guard distance >= minDistance, distance <= maxDistance else { return nil }
        let u = camera.fx * local.x / distance + camera.cx
        let v = -camera.fy * local.y / distance + camera.cy
        guard u >= 0, v >= 0, u < camera.width, v < camera.height else { return nil }
        return SIMD2<Float>(u, v)
    }

    static func projectInFront(_ point: SIMD3<Float>, _ camera: Camera) -> SIMD2<Float>? {
        let local = camera.view * SIMD4<Float>(point, 1)
        let distance = -local.z
        guard distance >= minDistance else { return nil }
        return SIMD2<Float>(camera.fx * local.x / distance + camera.cx, -camera.fy * local.y / distance + camera.cy)
    }

    static func clampedUVs(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ camera: Camera) -> [Float]? {
        var coords: [Float] = []
        coords.reserveCapacity(6)
        for point in [a, b, c] {
            guard let pixel = projectInFront(point, camera) else { return nil }
            coords.append(min(max(pixel.x / camera.width, 0), 1))
            coords.append(min(max(pixel.y / camera.height, 0), 1))
        }
        return coords
    }

    static func score(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ camera: Camera, relaxed: Bool = false) -> Float? {
        let centroid = (a + b + c) / 3
        guard let center = project(centroid, camera) else { return nil }
        if relaxed {
            guard projectInFront(a, camera) != nil, projectInFront(b, camera) != nil, projectInFront(c, camera) != nil else { return nil }
        } else {
            guard project(a, camera) != nil, project(b, camera) != nil, project(c, camera) != nil else { return nil }
        }
        let toCamera = camera.position - centroid
        let distance = simd_length(toCamera)
        guard distance > 0 else { return nil }
        let cross = simd_cross(b - a, c - a)
        let area = simd_length(cross)
        let facing = area > 0 ? abs(simd_dot(cross / area, toCamera / distance)) : 1
        guard facing >= (relaxed ? relaxedMinFacing : minFacing) else { return nil }
        switch depthAgrees(centroid, at: center, camera, relaxed: relaxed) {
        case .some(false):
            return nil
        case .none:
            if relaxed { return nil }
        case .some(true):
            break
        }
        if cornersHidden(a, b, c, camera, relaxed: relaxed) { return nil }
        let halfWidth = camera.width / 2
        let halfHeight = camera.height / 2
        let offCenter = max(abs(center.x - halfWidth) / halfWidth, abs(center.y - halfHeight) / halfHeight)
        let pixelsPerSquareMeter = camera.fx * camera.fy * facing * facing / (distance * distance)
        guard pixelsPerSquareMeter > 0 else { return nil }
        return 1_000_000 * (1 + offCenter) * camera.blurPenalty * exposurePenalty(center, camera) / pixelsPerSquareMeter
    }

    static func exposurePenalty(_ pixel: SIMD2<Float>, _ camera: Camera) -> Float {
        guard let sample = camera.brightness, sample.width > 0, sample.height > 0, sample.values.count >= sample.width * sample.height, camera.width > 0, camera.height > 0 else { return 1 }
        let x = min(max(Int(pixel.x * Float(sample.width) / camera.width), 0), sample.width - 1)
        let y = min(max(Int(pixel.y * Float(sample.height) / camera.height), 0), sample.height - 1)
        let value = sample.values[y * sample.width + x]
        return value >= blownOutLevel || value <= tooDarkLevel ? badExposurePenalty : 1
    }

    static func depthAt(_ pixel: SIMD2<Float>, _ camera: Camera, trustedOnly: Bool) -> Float? {
        guard let depth = camera.depth, camera.depthWidth > 0, camera.depthHeight > 0, depth.count >= camera.depthWidth * camera.depthHeight else { return nil }
        let du = min(max(Int(pixel.x * Float(camera.depthWidth) / camera.width), 0), camera.depthWidth - 1)
        let dv = min(max(Int(pixel.y * Float(camera.depthHeight) / camera.height), 0), camera.depthHeight - 1)
        let index = dv * camera.depthWidth + du
        if trustedOnly, let confidence = camera.confidence, confidence.count == depth.count, confidence[index] == 0 { return nil }
        let millimeters = depth[index]
        guard millimeters > 0 else { return nil }
        return Float(millimeters) / 1000
    }

    static func depthTolerance(_ along: Float, relaxed: Bool) -> Float {
        relaxed ? 0.2 + 0.06 * along : 0.08 + 0.03 * along
    }

    static func depthAgrees(_ point: SIMD3<Float>, at pixel: SIMD2<Float>, _ camera: Camera, relaxed: Bool) -> Bool? {
        guard let measured = depthAt(pixel, camera, trustedOnly: relaxed) else { return nil }
        let along = -(camera.view * SIMD4<Float>(point, 1)).z
        return abs(measured - along) <= depthTolerance(along, relaxed: relaxed)
    }

    static func cornersHidden(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ camera: Camera, relaxed: Bool) -> Bool {
        let centroid = (a + b + c) / 3
        for corner in [a, b, c] {
            let point = corner + (centroid - corner) * cornerInset
            guard let pixel = project(point, camera), let measured = depthAt(pixel, camera, trustedOnly: relaxed) else { continue }
            let along = -(camera.view * SIMD4<Float>(point, 1)).z
            if along - measured > depthTolerance(along, relaxed: relaxed) { return true }
        }
        return false
    }

    static func seesSpot(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ camera: Camera) -> Bool {
        let centroid = (a + b + c) / 3
        guard let center = project(centroid, camera) else { return false }
        return depthAgrees(centroid, at: center, camera, relaxed: true) == true && !cornersHidden(a, b, c, camera, relaxed: true)
    }

    static func confidenceValues(_ data: Data?, count: Int) -> [UInt8]? {
        guard let data, count > 0, data.count >= count else { return nil }
        return [UInt8](data.prefix(count))
    }

    static func blurPenalty(_ blurPx: Float?) -> Float {
        guard let blurPx, blurPx.isFinite else { return 1 }
        return 1 + max(0, blurPx) / (2 * LidarMotionSpeed.holdBlurPx)
    }

    static func facesByVertex(_ input: PartInput, vertexCount: Int, valid: [Bool]) -> [[Int32]] {
        var facesOf = [[Int32]](repeating: [], count: vertexCount)
        for face in 0..<input.faceCount where valid[face] {
            for corner in 0..<3 {
                facesOf[Int(faceIndex(input, face, corner))].append(Int32(face))
            }
        }
        return facesOf
    }

    static func facePoints(_ input: PartInput, world: [SIMD3<Float>], face: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        (world[Int(faceIndex(input, face, 0))], world[Int(faceIndex(input, face, 1))], world[Int(faceIndex(input, face, 2))])
    }

    static func majoritySlot(_ neighbours: [Int], current: Int) -> Int? {
        var counts: [Int: Int] = [:]
        for slot in neighbours where slot >= 0 {
            counts[slot, default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        guard top.key != current, top.value * 2 > neighbours.count, top.value > counts[current, default: 0] else { return nil }
        return top.key
    }

    @discardableResult
    static func smoothChoices(_ input: PartInput, world: [SIMD3<Float>], facesOf: [[Int32]], valid: [Bool], best: [Float], slots: inout [Int], uvs: inout [Float], cameras: [Camera], isVisible: (Int, Int) -> Bool, isCancelled: () -> Bool = { false }) -> Int {
        var total = 0
        for _ in 0..<smoothRounds {
            if isCancelled() { break }
            var found: [(face: Int, slot: Int, coords: [Float])] = []
            for face in 0..<input.faceCount where valid[face] && slots[face] >= 0 {
                var seen: Set<Int32> = [Int32(face)]
                var neighbourSlots: [Int] = []
                for corner in 0..<3 {
                    for neighbour in facesOf[Int(faceIndex(input, face, corner))] where seen.insert(neighbour).inserted {
                        neighbourSlots.append(slots[Int(neighbour)])
                    }
                }
                guard let choice = majoritySlot(neighbourSlots, current: slots[face]), isVisible(choice, face) else { continue }
                let (a, b, c) = facePoints(input, world: world, face: face)
                guard let value = score(a, b, c, cameras[choice]), value <= best[face] * smoothSlack, let coords = clampedUVs(a, b, c, cameras[choice]) else { continue }
                found.append((face: face, slot: choice, coords: coords))
            }
            if found.isEmpty { break }
            for item in found {
                slots[item.face] = item.slot
                uvs.replaceSubrange((item.face * 6)..<(item.face * 6 + 6), with: item.coords)
            }
            total += found.count
        }
        return total
    }

    static func fillFromNeighbours(_ input: PartInput, world: [SIMD3<Float>], valid: [Bool], slots: inout [Int], uvs: inout [Float], cameras: [Camera], facesOf known: [[Int32]]? = nil, isCancelled: () -> Bool = { false }) -> Int {
        let facesOf = known ?? facesByVertex(input, vertexCount: world.count, valid: valid)
        var open = (0..<input.faceCount).filter { valid[$0] && slots[$0] < 0 }
        var total = 0
        for _ in 0..<fillRings where !open.isEmpty {
            if isCancelled() { break }
            var found: [(face: Int, slot: Int, coords: [Float])] = []
            for face in open {
                let (a, b, c) = facePoints(input, world: world, face: face)
                search: for corner in 0..<3 {
                    for neighbour in facesOf[Int(faceIndex(input, face, corner))] where slots[Int(neighbour)] >= 0 {
                        let slot = slots[Int(neighbour)]
                        guard seesSpot(a, b, c, cameras[slot]), let coords = clampedUVs(a, b, c, cameras[slot]) else { continue }
                        found.append((face: face, slot: slot, coords: coords))
                        break search
                    }
                }
            }
            if found.isEmpty { break }
            for item in found {
                slots[item.face] = item.slot
                uvs.replaceSubrange((item.face * 6)..<(item.face * 6 + 6), with: item.coords)
            }
            total += found.count
            let done = Set(found.map(\.face))
            open.removeAll { done.contains($0) }
        }
        return total
    }

    static func seamShades(_ input: PartInput, world: [SIMD3<Float>], valid: [Bool], slots: [Int], cameras: [Camera], samples: [Luminance?], gains: [Float], isCancelled: () -> Bool = { false }) -> [Float] {
        seamTints(input, world: world, valid: valid, slots: slots, cameras: cameras, samples: samples, gains: gains, isCancelled: isCancelled).map { ($0.x + $0.y + $0.z) / 3 }
    }

    static func seamTints(_ input: PartInput, world: [SIMD3<Float>], valid: [Bool], slots: [Int], cameras: [Camera], samples: [Luminance?], gains: [Float], isCancelled: () -> Bool = { false }) -> [SIMD3<Float>] {
        var shades = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 1), count: input.faceCount * 3)
        let slotSpan = cameras.count + 1
        var nodeOf: [Int: Int] = [:]
        var nodeVertex: [Int] = []
        var nodeSlot: [Int] = []
        var cornerNode = [Int](repeating: -1, count: input.faceCount * 3)
        for face in 0..<input.faceCount where valid[face] && slots[face] >= 0 && slots[face] < cameras.count {
            for corner in 0..<3 {
                let vertex = Int(faceIndex(input, face, corner))
                let key = vertex * slotSpan + slots[face]
                if let node = nodeOf[key] {
                    cornerNode[face * 3 + corner] = node
                } else {
                    nodeOf[key] = nodeVertex.count
                    cornerNode[face * 3 + corner] = nodeVertex.count
                    nodeVertex.append(vertex)
                    nodeSlot.append(slots[face])
                }
            }
        }
        guard !nodeVertex.isEmpty else { return shades }
        var nodesAt: [Int: [Int]] = [:]
        for node in nodeVertex.indices {
            nodesAt[nodeVertex[node], default: []].append(node)
        }
        var value = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 1), count: nodeVertex.count)
        var fixed = [Bool](repeating: false, count: nodeVertex.count)
        let lowest = SIMD3<Float>(repeating: 0.03)
        for (vertex, nodes) in nodesAt where nodes.count > 1 {
            var levels: [(node: Int, level: SIMD3<Float>)] = []
            for node in nodes {
                let slot = nodeSlot[node]
                guard slot < samples.count, let sample = samples[slot], let raw = colour(world[vertex], cameras[slot], sample) else { continue }
                let level = raw * (slot < gains.count ? gains[slot] : 1)
                if all(level .> lowest) { levels.append((node: node, level: level)) }
            }
            guard levels.count > 1 else { continue }
            let target = levels.dropFirst().reduce(levels[0].level) { simd_min($0, $1.level) }
            for item in levels {
                value[item.node] = simd_clamp(target / item.level, SIMD3<Float>(repeating: seamMinShade), SIMD3<Float>(repeating: 1))
                fixed[item.node] = true
            }
        }
        guard fixed.contains(true) else { return shades }
        var neighbours = [[Int32]](repeating: [], count: nodeVertex.count)
        for face in 0..<input.faceCount {
            let n0 = cornerNode[face * 3], n1 = cornerNode[face * 3 + 1], n2 = cornerNode[face * 3 + 2]
            guard n0 >= 0, n1 >= 0, n2 >= 0 else { continue }
            neighbours[n0].append(contentsOf: [Int32(n1), Int32(n2)])
            neighbours[n1].append(contentsOf: [Int32(n0), Int32(n2)])
            neighbours[n2].append(contentsOf: [Int32(n0), Int32(n1)])
        }
        for _ in 0..<seamRounds {
            if isCancelled() { break }
            var next = value
            for node in value.indices where !fixed[node] && !neighbours[node].isEmpty {
                var sum = SIMD3<Float>(repeating: 0)
                for neighbour in neighbours[node] {
                    sum += value[Int(neighbour)]
                }
                next[node] = sum / Float(neighbours[node].count)
            }
            value = next
        }
        for corner in cornerNode.indices where cornerNode[corner] >= 0 {
            shades[corner] = value[cornerNode[corner]]
        }
        return shades
    }

    static func camera(_ frame: MeshFrame) -> Camera {
        let depth = loadDepth(frame)
        let transform = frame.cameraTransform
        return Camera(
            view: transform.inverse,
            position: SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
            width: Float(frame.imageWidth),
            height: Float(frame.imageHeight),
            fx: frame.fx,
            fy: frame.fy,
            cx: frame.cx,
            cy: frame.cy,
            depth: depth,
            depthWidth: depth == nil ? 0 : frame.depthWidth,
            depthHeight: depth == nil ? 0 : frame.depthHeight,
            blurPenalty: blurPenalty(frame.blurPx),
            confidence: depth == nil ? nil : loadConfidence(frame)
        )
    }

    private static func visibility(corners: [SIMD3<Float>], faceTotal: Int, words: Int, cameras: [Camera], monitor: Monitor) -> ([UInt64], [Int32]) {
        var visible = [UInt64](repeating: 0, count: cameras.count * words)
        var bestCamera = [Int32](repeating: -1, count: faceTotal)
        let chunks = (faceTotal + chunkFaces - 1) / chunkFaces
        visible.withUnsafeMutableBufferPointer { bits in
            bestCamera.withUnsafeMutableBufferPointer { best in
                corners.withUnsafeBufferPointer { points in
                    monitor.beginStage()
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        guard !monitor.isCancelled else { return }
                        let start = chunk * chunkFaces
                        let end = min(start + chunkFaces, faceTotal)
                        for face in start..<end {
                            if face % 256 == 0, monitor.isCancelled { return }
                            let a = points[face * 3]
                            let b = points[face * 3 + 1]
                            let c = points[face * 3 + 2]
                            var bestScore = Float.greatestFiniteMagnitude
                            for (index, camera) in cameras.enumerated() {
                                guard let value = score(a, b, c, camera) else { continue }
                                bits[index * words + face / 64] |= UInt64(1) << UInt64(face % 64)
                                if value < bestScore {
                                    bestScore = value
                                    best[face] = Int32(index)
                                }
                            }
                        }
                        monitor.tick(of: chunks, from: 0.15, to: 0.7)
                    }
                }
            }
        }
        return (visible, bestCamera)
    }

    private static func isVisible(_ visible: [UInt64], camera: Int, face: Int, words: Int) -> Bool {
        visible[camera * words + face / 64] & (UInt64(1) << UInt64(face % 64)) != 0
    }

    struct Luminance {
        let width: Int
        let height: Int
        let values: [UInt8]
        var rgb: [UInt8]? = nil
    }

    private static func gainPairs(kept: [Int], visible: [UInt64], words: Int, centroids: [SIMD3<Float>], cameras: [Camera], samples: [Luminance?]) -> [(Int, Int, Float)] {
        var pairs: [(Int, Int, Float)] = []
        for a in kept.indices {
            guard let first = samples[a] else { continue }
            for b in kept.indices where b > a {
                guard let second = samples[b] else { continue }
                var shared: [Int] = []
                for word in 0..<words {
                    var bits = visible[kept[a] * words + word] & visible[kept[b] * words + word]
                    while bits != 0 {
                        shared.append(word * 64 + bits.trailingZeroBitCount)
                        bits &= bits - 1
                    }
                }
                guard shared.count >= 200 else { continue }
                let step = max(1, shared.count / 400)
                var ratios: [Float] = []
                for position in stride(from: 0, to: shared.count, by: step) {
                    let point = centroids[shared[position]]
                    guard let la = luminance(point, cameras[kept[a]], first), let lb = luminance(point, cameras[kept[b]], second), la > 0.03, lb > 0.03, la < gainSampleCeiling, lb < gainSampleCeiling else { continue }
                    ratios.append(log(lb / la))
                }
                guard ratios.count >= 100 else { continue }
                ratios.sort()
                pairs.append((a, b, ratios[ratios.count / 2]))
            }
        }
        return pairs
    }

    private static func luminance(_ point: SIMD3<Float>, _ camera: Camera, _ sample: Luminance) -> Float? {
        guard let pixel = project(point, camera) else { return nil }
        let x = min(Int(pixel.x * Float(sample.width) / camera.width), sample.width - 1)
        let y = min(Int(pixel.y * Float(sample.height) / camera.height), sample.height - 1)
        return Float(sample.values[y * sample.width + x]) / 255
    }

    private static func colour(_ point: SIMD3<Float>, _ camera: Camera, _ sample: Luminance) -> SIMD3<Float>? {
        guard let pixel = project(point, camera) else { return nil }
        let x = min(Int(pixel.x * Float(sample.width) / camera.width), sample.width - 1)
        let y = min(Int(pixel.y * Float(sample.height) / camera.height), sample.height - 1)
        let index = y * sample.width + x
        if let rgb = sample.rgb, rgb.count == sample.width * sample.height * 3 {
            return SIMD3<Float>(Float(rgb[index * 3]), Float(rgb[index * 3 + 1]), Float(rgb[index * 3 + 2])) / 255
        }
        return SIMD3<Float>(repeating: Float(sample.values[index]) / 255)
    }

    private static func loadLuminance(_ url: URL) -> Luminance? {
        guard let image = thumbnail(url, size: gainSampleSize) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            let r = pixels[index * 4], g = pixels[index * 4 + 1], b = pixels[index * 4 + 2]
            rgb[index * 3] = r
            rgb[index * 3 + 1] = g
            rgb[index * 3 + 2] = b
            values[index] = UInt8(min(255, (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000))
        }
        return Luminance(width: width, height: height, values: values, rgb: rgb)
    }

    private static func applyGain(_ gain: Float, to image: CGImage, context: CIContext) -> CGImage {
        guard abs(gain - 1) > 0.02 else { return image }
        let value = CGFloat(gain)
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0)
        ])
        return context.createCGImage(output, from: input.extent) ?? image
    }

    private static func forEachFace(_ input: PartInput, world: [SIMD3<Float>], _ body: (Int, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        guard input.faces.count >= input.faceCount * 12 else { return }
        for face in 0..<input.faceCount {
            let i0 = Int(faceIndex(input, face, 0))
            let i1 = Int(faceIndex(input, face, 1))
            let i2 = Int(faceIndex(input, face, 2))
            if i0 < world.count, i1 < world.count, i2 < world.count {
                body(face, world[i0], world[i1], world[i2])
            } else {
                body(face, invalidPoint, invalidPoint, invalidPoint)
            }
        }
    }

    private static func faceIndex(_ input: PartInput, _ face: Int, _ corner: Int) -> UInt32 {
        let offset = (face * 3 + corner) * 4
        return input.faces.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func faceClass(_ input: PartInput, _ face: Int) -> UInt8 {
        guard let classes = input.classes, face < classes.count else { return 0 }
        let value = classes[classes.startIndex + face]
        return hiddenClasses.contains(value) ? value : 0
    }

    private static func localFloats(_ input: PartInput) -> [Float] {
        guard input.vertexCount > 0, input.vertices.count >= input.vertexCount * 12 else { return [] }
        var floats = [Float](repeating: 0, count: input.vertexCount * 3)
        _ = floats.withUnsafeMutableBytes { input.vertices.copyBytes(to: $0) }
        return floats
    }

    private static func worldVertices(_ input: PartInput) -> [SIMD3<Float>] {
        let floats = localFloats(input)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(input.vertexCount)
        for i in 0..<(floats.count / 3) {
            let world = input.transform * SIMD4<Float>(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2], 1)
            points.append(SIMD3<Float>(world.x, world.y, world.z))
        }
        return points
    }

    private static func thumbnail(_ url: URL, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        thumbnail(url, size: textureSize)
    }

    private static func loadDepth(_ frame: MeshFrame) -> [UInt16]? {
        guard let url = frame.depthURL, frame.depthWidth > 0, frame.depthHeight > 0 else { return nil }
        let count = frame.depthWidth * frame.depthHeight
        guard let data = FileManager.default.contents(atPath: url.path), data.count >= count * 2 else { return nil }
        var values = [UInt16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    private static func loadConfidence(_ frame: MeshFrame) -> [UInt8]? {
        guard let url = frame.confidenceURL else { return nil }
        return confidenceValues(FileManager.default.contents(atPath: url.path), count: frame.depthWidth * frame.depthHeight)
    }
}
