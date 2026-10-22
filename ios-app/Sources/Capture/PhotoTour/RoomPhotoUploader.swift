import Foundation

struct RoomPhotoUploadOutcome: Equatable {
    let batchesConsidered: Int
    let photosUploaded: Int
    let photosFailed: Int
    let skipReason: String?

    static let none = RoomPhotoUploadOutcome(
        batchesConsidered: 0,
        photosUploaded: 0,
        photosFailed: 0,
        skipReason: nil
    )

    var hadFailures: Bool {
        photosFailed > 0 || skipReason != nil
    }
}

@MainActor
enum RoomPhotoUploader {
    static func uploadAll(
        captureGroupId: String,
        session: ScanSessionResponse,
        floorPlan: FloorPlan,
        store: RoomPhotoStore,
        client: ScanServiceClient = ScanServiceClient()
    ) async -> RoomPhotoUploadOutcome {
        let batches: [RoomPhotoManifest]
        do {
            batches = try store.allBatches(captureGroupId: captureGroupId)
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: could not read local batches for \(captureGroupId): \(error.localizedDescription)",
                category: .error
            )
            return RoomPhotoUploadOutcome(
                batchesConsidered: 0,
                photosUploaded: 0,
                photosFailed: 0,
                skipReason: vuuroLocalized("Could not read local tour photos.")
            )
        }
        guard !batches.isEmpty else { return .none }

        let serverRooms = roomsForCaptureGroup(floorPlan.rooms, captureGroupId: captureGroupId)
        guard !serverRooms.isEmpty else {
            DiagnosticsLog.shared.record(
                "Photo360: no server rooms carry this capture group \(captureGroupId); leaving \(batches.count) batch(es) on disk",
                category: .info
            )
            return RoomPhotoUploadOutcome(
                batchesConsidered: batches.count,
                photosUploaded: 0,
                photosFailed: 0,
                skipReason: vuuroLocalized("Tour photos weren't attached to the captured rooms.")
            )
        }

        if batches.count != serverRooms.count {
            DiagnosticsLog.shared.record(
                "Photo360: local batch count (\(batches.count)) does not match server room count (\(serverRooms.count)) for \(captureGroupId); will still upload the rest if every remaining batch pairs to exactly one room",
                category: .info
            )
        }

        let pairing = pair(batches: batches, serverRooms: serverRooms)

        guard let matched = pairing else {
            DiagnosticsLog.shared.record(
                "Photo360: could not pair local batches with server rooms in \(captureGroupId); leaving photos on disk",
                category: .error
            )
            return RoomPhotoUploadOutcome(
                batchesConsidered: batches.count,
                photosUploaded: 0,
                photosFailed: 0,
                skipReason: vuuroLocalized("Could not match tour photos to the captured rooms.")
            )
        }

        var uploaded = 0
        var failed = 0
        var expected = 0
        for (batch, roomId) in matched {
            let photos = batch.photos.filter { isPlausiblePosition($0.positionM) }
            guard !photos.isEmpty else { continue }
            expected += photos.count
            for photo in photos {
                if Task.isCancelled {
                    return RoomPhotoUploadOutcome(
                        batchesConsidered: batches.count,
                        photosUploaded: uploaded,
                        photosFailed: failed,
                        skipReason: nil
                    )
                }
                let ok = await uploadOne(
                    photo: photo,
                    batch: batch,
                    roomId: roomId,
                    session: session,
                    store: store,
                    client: client
                )
                if ok {
                    uploaded += 1
                } else {
                    failed += 1
                }
            }
        }

        if failed == 0 && expected > 0 && uploaded == expected {
            store.clearAll(captureGroupId: captureGroupId)
        }

        return RoomPhotoUploadOutcome(
            batchesConsidered: batches.count,
            photosUploaded: uploaded,
            photosFailed: failed,
            skipReason: nil
        )
    }

    static func pair(
        batches: [RoomPhotoManifest],
        serverRooms: [FloorPlan.Room]
    ) -> [(batch: RoomPhotoManifest, roomId: String)]? {
        if let byOrigin = pairByStructureOrigin(batches: batches, serverRooms: serverRooms) {
            return byOrigin
        }
        if let greedy = pairGreedy(batches: batches, serverRooms: serverRooms) {
            DiagnosticsLog.shared.record(
                "Photo360: paired all \(greedy.count) local batch(es) by origin; \(serverRooms.count - greedy.count) server room(s) have no tour photos",
                category: .info
            )
            return greedy
        }
        if batches.count == 1, serverRooms.count == 1 {
            DiagnosticsLog.shared.record(
                "Photo360: origins did not match, pairing the only local batch with the only server room \(serverRooms[0].roomId)",
                category: .info
            )
            return [(batch: batches[0], roomId: serverRooms[0].roomId)]
        }
        if serverRooms.allSatisfy({ $0.structureOriginM == nil }),
           let positional = pairPositionally(batches: batches, serverRooms: serverRooms) {
            DiagnosticsLog.shared.record(
                "Photo360: server rooms carry no origin, pairing \(positional.count) batch(es) in capture order",
                category: .info
            )
            return positional
        }
        return nil
    }

    static func pendingPhotoCount(floorPlan: FloorPlan, store: RoomPhotoStore) -> [String: Int] {
        var groupIds: Set<String> = []
        for room in floorPlan.rooms {
            if let id = room.captureGroupId, !id.isEmpty { groupIds.insert(id) }
            if let id = room.joinedToGroupId, !id.isEmpty { groupIds.insert(id) }
        }
        var counts: [String: Int] = [:]
        for groupId in groupIds {
            let batches = (try? store.allBatches(captureGroupId: groupId)) ?? []
            let total = batches.reduce(0) { $0 + $1.photos.count }
            if total > 0 { counts[groupId] = total }
        }
        return counts
    }

    static func roomsForCaptureGroup(_ rooms: [FloorPlan.Room], captureGroupId: String) -> [FloorPlan.Room] {
        rooms.filter {
            $0.captureGroupId == captureGroupId || $0.joinedToGroupId == captureGroupId
        }
    }

    private static let originToleranceM: Double = 0.01

    static func pairByStructureOrigin(
        batches: [RoomPhotoManifest],
        serverRooms: [FloorPlan.Room]
    ) -> [(batch: RoomPhotoManifest, roomId: String)]? {
        guard batches.count == serverRooms.count else { return nil }
        guard batches.count > 0 else { return [] }
        guard batches.count <= 8 else {
            return pairGreedy(batches: batches, serverRooms: serverRooms)
        }
        let toleranceSq = originToleranceM * originToleranceM
        var best: [Int]? = nil
        var bestCost = Double.infinity
        for perm in permutations(Array(serverRooms.indices)) {
            var cost = 0.0
            var valid = true
            for (batchIndex, roomIndex) in perm.enumerated() {
                let origin = batches[batchIndex].structureOriginM ?? []
                guard origin.count == 2, origin.allSatisfy({ $0.isFinite }) else {
                    valid = false
                    break
                }
                let distSq = originDistanceSquared(serverRooms[roomIndex].structureOriginM, origin)
                if !distSq.isFinite || distSq > toleranceSq {
                    valid = false
                    break
                }
                cost += distSq
            }
            if valid && cost < bestCost {
                bestCost = cost
                best = perm
            }
        }
        guard let assignment = best else { return nil }
        return zip(batches, assignment).map { (batch: $0.0, roomId: serverRooms[$0.1].roomId) }
    }

    static func pairGreedy(
        batches: [RoomPhotoManifest],
        serverRooms: [FloorPlan.Room]
    ) -> [(batch: RoomPhotoManifest, roomId: String)]? {
        let toleranceSq = originToleranceM * originToleranceM
        var remaining = serverRooms
        var matched: [(batch: RoomPhotoManifest, roomId: String)] = []
        for batch in batches {
            guard let origin = batch.structureOriginM, origin.count == 2,
                  origin.allSatisfy({ $0.isFinite }) else {
                return nil
            }
            let candidates = remaining.indices.filter { index in
                let d = originDistanceSquared(remaining[index].structureOriginM, origin)
                return d.isFinite && d <= toleranceSq
            }
            guard candidates.count == 1 else { return nil }
            let index = candidates[0]
            matched.append((batch: batch, roomId: remaining[index].roomId))
            remaining.remove(at: index)
        }
        return matched
    }

    static func permutations<T>(_ array: [T]) -> [[T]] {
        if array.isEmpty { return [[]] }
        var result: [[T]] = []
        for (index, element) in array.enumerated() {
            var remaining = array
            remaining.remove(at: index)
            for perm in permutations(remaining) {
                result.append([element] + perm)
            }
        }
        return result
    }

    static func pairPositionally(
        batches: [RoomPhotoManifest],
        serverRooms: [FloorPlan.Room]
    ) -> [(batch: RoomPhotoManifest, roomId: String)]? {
        guard batches.count == serverRooms.count else { return nil }
        return batches.enumerated().map { index, batch in
            (batch: batch, roomId: serverRooms[index].roomId)
        }
    }

    private static func originDistanceSquared(_ a: [Double]?, _ b: [Double]) -> Double {
        guard let a, a.count == 2 else { return .infinity }
        let dx = a[0] - b[0]
        let dz = a[1] - b[1]
        return dx * dx + dz * dz
    }

    private static func isPlausiblePosition(_ position: [Double]) -> Bool {
        guard position.count == 2 else { return false }
        return position.allSatisfy { $0.isFinite && abs($0) < 10000 }
    }

    private static func uploadOne(
        photo: RoomPhotoMetadata,
        batch: RoomPhotoManifest,
        roomId: String,
        session: ScanSessionResponse,
        store: RoomPhotoStore,
        client: ScanServiceClient
    ) async -> Bool {
        let data: Data
        do {
            data = try store.loadPhotoData(
                localId: photo.localId,
                captureGroupId: batch.captureGroupId,
                roomKey: batch.roomKey
            )
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: photo file missing for \(photo.localId): \(error.localizedDescription)",
                category: .error
            )
            return false
        }

        do {
            _ = try await client.uploadPhoto360(
                sessionId: session.id,
                accessToken: session.accessToken,
                roomId: roomId,
                imageData: data,
                positionM: photo.positionM,
                headingDeg: photo.headingDeg,
                idempotencyKey: photo.localId
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: upload failed for \(photo.localId): \(error.localizedDescription)",
                category: .error
            )
            return false
        }
    }
}
