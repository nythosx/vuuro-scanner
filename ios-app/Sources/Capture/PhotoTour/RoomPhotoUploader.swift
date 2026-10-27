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
final class RoomPhotoUploadTrace {
    var batches: [RoomPhotoManifest] = []
    var serverRoomCount = 0
    var pairing = "not_attempted"
    var failures: [PhotoStepSummary.Failure] = []
}

@MainActor
enum RoomPhotoUploader {
    static let maxParallelUploads = 3

    static func uploadAll(
        captureGroupId: String,
        session: ScanSessionResponse,
        floorPlan: FloorPlan,
        store: RoomPhotoStore,
        client: ScanServiceClient = ScanServiceClient(),
        trigger: String = "after_scan"
    ) async -> RoomPhotoUploadOutcome {
        let trace = RoomPhotoUploadTrace()
        let outcome = await performUpload(
            captureGroupId: captureGroupId,
            session: session,
            floorPlan: floorPlan,
            store: store,
            client: client,
            trace: trace
        )
        if !trace.batches.isEmpty || outcome.skipReason != nil {
            let report = summary(captureGroupId: captureGroupId, trigger: trigger, trace: trace, outcome: outcome)
            do {
                try await client.postClientEvent(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    kind: PhotoStepSummary.kind,
                    payload: report
                )
            } catch {
                DiagnosticsLog.shared.record(
                    "Photo360: could not send the photo step report for \(session.id): \(error.localizedDescription)",
                    category: .error
                )
            }
        }
        return outcome
    }

    static func summary(
        captureGroupId: String,
        trigger: String,
        trace: RoomPhotoUploadTrace,
        outcome: RoomPhotoUploadOutcome
    ) -> PhotoStepSummary {
        PhotoStepSummary(
            build: BuildInfo.commitSHA,
            trigger: trigger,
            captureGroupId: captureGroupId,
            serverRoomCount: trace.serverRoomCount,
            pairing: trace.pairing,
            photosTaken: trace.batches.reduce(0) { $0 + $1.photos.count },
            photosUploaded: outcome.photosUploaded,
            photosFailed: outcome.photosFailed,
            skipReason: outcome.skipReason,
            failures: Array(trace.failures.prefix(50)),
            rooms: trace.batches.map {
                PhotoStepSummary.Room(roomKey: $0.roomKey, photos: $0.photos.count, coverage: $0.finishCoverage)
            }
        )
    }

    private static func performUpload(
        captureGroupId: String,
        session: ScanSessionResponse,
        floorPlan: FloorPlan,
        store: RoomPhotoStore,
        client: ScanServiceClient,
        trace: RoomPhotoUploadTrace
    ) async -> RoomPhotoUploadOutcome {
        let batches: [RoomPhotoManifest]
        do {
            batches = try store.allBatches(captureGroupId: captureGroupId)
            trace.batches = batches
        } catch {
            trace.pairing = "read_error"
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
        trace.serverRoomCount = serverRooms.count
        guard !serverRooms.isEmpty else {
            trace.pairing = "no_server_rooms"
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

        let paired = pairWithMethod(batches: batches, serverRooms: serverRooms)
        trace.pairing = paired?.method ?? "failed"

        guard let matched = paired?.pairs else {
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

        var jobs: [(photo: RoomPhotoMetadata, batch: RoomPhotoManifest, roomId: String)] = []
        for (batch, roomId) in matched {
            for photo in batch.photos where isPlausiblePosition(photo.positionM) {
                jobs.append((photo, batch, roomId))
            }
        }
        let expected = jobs.count

        var uploaded = 0
        var failed = 0
        await withTaskGroup(of: (String, String?).self) { group in
            var next = 0
            while next < jobs.count || !group.isEmpty {
                while next < jobs.count, next - uploaded - failed < maxParallelUploads, !Task.isCancelled {
                    let job = jobs[next]
                    next += 1
                    group.addTask { @MainActor in
                        let failure = await RoomPhotoUploader.uploadOne(
                            photo: job.photo,
                            batch: job.batch,
                            roomId: job.roomId,
                            session: session,
                            store: store,
                            client: client
                        )
                        return (job.photo.localId, failure)
                    }
                }
                guard let result = await group.next() else { break }
                let (photoId, failure) = result
                if let failure {
                    failed += 1
                    trace.failures.append(PhotoStepSummary.Failure(photoId: photoId, reason: failure))
                } else {
                    uploaded += 1
                }
            }
        }

        if Task.isCancelled {
            return RoomPhotoUploadOutcome(
                batchesConsidered: batches.count,
                photosUploaded: uploaded,
                photosFailed: failed,
                skipReason: nil
            )
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
        pairWithMethod(batches: batches, serverRooms: serverRooms)?.pairs
    }

    static func pairWithMethod(
        batches: [RoomPhotoManifest],
        serverRooms: [FloorPlan.Room]
    ) -> (pairs: [(batch: RoomPhotoManifest, roomId: String)], method: String)? {
        if let byOrigin = pairByStructureOrigin(batches: batches, serverRooms: serverRooms) {
            return (byOrigin, "origin")
        }
        if let greedy = pairGreedy(batches: batches, serverRooms: serverRooms) {
            DiagnosticsLog.shared.record(
                "Photo360: paired all \(greedy.count) local batch(es) by origin; \(serverRooms.count - greedy.count) server room(s) have no tour photos",
                category: .info
            )
            return (greedy, "origin_partial")
        }
        if batches.count == 1, serverRooms.count == 1 {
            DiagnosticsLog.shared.record(
                "Photo360: origins did not match, pairing the only local batch with the only server room \(serverRooms[0].roomId)",
                category: .info
            )
            return ([(batch: batches[0], roomId: serverRooms[0].roomId)], "single_room")
        }
        if serverRooms.allSatisfy({ $0.structureOriginM == nil }),
           let positional = pairPositionally(batches: batches, serverRooms: serverRooms) {
            DiagnosticsLog.shared.record(
                "Photo360: server rooms carry no origin, pairing \(positional.count) batch(es) in capture order",
                category: .info
            )
            return (positional, "capture_order")
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
    ) async -> String? {
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
            return "photo file missing on the phone: \(error.localizedDescription)"
        }

        do {
            _ = try await client.uploadPhoto360(
                sessionId: session.id,
                accessToken: session.accessToken,
                roomId: roomId,
                imageData: data,
                positionM: photo.positionM,
                headingDeg: photo.headingDeg,
                zoom: photo.zoom,
                pitchDeg: photo.pitchDeg,
                idempotencyKey: photo.localId
            )
            return nil
        } catch is CancellationError {
            return "cancelled"
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: upload failed for \(photo.localId): \(error.localizedDescription)",
                category: .error
            )
            return error.localizedDescription
        }
    }
}

struct PhotoStepSummary: Encodable {
    static let kind = "photo_step_summary"

    struct Failure: Encodable {
        let photoId: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case photoId = "photo_id"
            case reason
        }
    }

    struct Room: Encodable {
        let roomKey: String
        let photos: Int
        let coverage: RoomPhotoFinishCoverage?

        enum CodingKeys: String, CodingKey {
            case roomKey = "room_key"
            case photos
            case coverage
        }
    }

    let build: String
    let trigger: String
    let captureGroupId: String
    let serverRoomCount: Int
    let pairing: String
    let photosTaken: Int
    let photosUploaded: Int
    let photosFailed: Int
    let skipReason: String?
    let failures: [Failure]
    let rooms: [Room]

    enum CodingKeys: String, CodingKey {
        case build
        case trigger
        case captureGroupId = "capture_group_id"
        case serverRoomCount = "server_room_count"
        case pairing
        case photosTaken = "photos_taken"
        case photosUploaded = "photos_uploaded"
        case photosFailed = "photos_failed"
        case skipReason = "skip_reason"
        case failures
        case rooms
    }
}
