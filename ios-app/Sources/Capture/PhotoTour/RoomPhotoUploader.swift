import Foundation

@MainActor
enum RoomPhotoUploader {
    static func uploadAll(
        captureGroupId: String,
        session: ScanSessionResponse,
        floorPlan: FloorPlan,
        store: RoomPhotoStore = .shared,
        client: ScanServiceClient = ScanServiceClient()
    ) async {
        let batches: [RoomPhotoManifest]
        do {
            batches = try store.allBatches(captureGroupId: captureGroupId)
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: could not read local batches for \(captureGroupId): \(error.localizedDescription)",
                category: .error
            )
            return
        }
        guard !batches.isEmpty else { return }

        let serverRooms = floorPlan.rooms.filter { $0.captureGroupId == captureGroupId }
        guard !serverRooms.isEmpty else {
            DiagnosticsLog.shared.record(
                "Photo360: no server rooms carry this capture group \(captureGroupId); leaving \(batches.count) batch(es) on disk",
                category: .info
            )
            return
        }

        guard batches.count == serverRooms.count else {
            DiagnosticsLog.shared.record(
                "Photo360: local batch count (\(batches.count)) does not match server room count (\(serverRooms.count)); leaving photos on disk",
                category: .error
            )
            return
        }

        let pairing: [(batch: RoomPhotoManifest, roomId: String)]?
        if let byOrigin = pairByStructureOrigin(batches: batches, serverRooms: serverRooms) {
            pairing = byOrigin
        } else if let positional = pairPositionally(batches: batches, serverRooms: serverRooms) {
            DiagnosticsLog.shared.record(
                "Photo360: falling back to positional pairing for \(captureGroupId) — structure origins did not match",
                category: .info
            )
            pairing = positional
        } else {
            pairing = nil
        }

        guard let matched = pairing else {
            DiagnosticsLog.shared.record(
                "Photo360: could not pair local batches with server rooms in \(captureGroupId); leaving photos on disk",
                category: .error
            )
            return
        }

        for (batch, roomId) in matched {
            let photos = batch.photos.filter { isPlausiblePosition($0.positionM) }
            guard !photos.isEmpty else { continue }
            for photo in photos {
                if Task.isCancelled { return }
                await uploadOne(
                    photo: photo,
                    batch: batch,
                    roomId: roomId,
                    session: session,
                    store: store,
                    client: client
                )
            }
        }

        store.clearAll(captureGroupId: captureGroupId)
    }

    private static let originToleranceM: Double = 0.01

    private static func pairByStructureOrigin(
        batches: [RoomPhotoManifest],
        serverRooms: [FloorPlan.Room]
    ) -> [(batch: RoomPhotoManifest, roomId: String)]? {
        var remaining = serverRooms
        var matched: [(batch: RoomPhotoManifest, roomId: String)] = []
        for batch in batches {
            guard let origin = batch.structureOriginM, origin.count == 2,
                  origin.allSatisfy({ $0.isFinite }) else {
                return nil
            }
            guard let bestIndex = remaining.indices.min(by: { lhs, rhs in
                originDistanceSquared(remaining[lhs].structureOriginM, origin)
                    < originDistanceSquared(remaining[rhs].structureOriginM, origin)
            }) else {
                return nil
            }
            let distance = originDistanceSquared(remaining[bestIndex].structureOriginM, origin)
            guard distance.isFinite, distance <= originToleranceM * originToleranceM else {
                return nil
            }
            matched.append((batch: batch, roomId: remaining[bestIndex].roomId))
            remaining.remove(at: bestIndex)
        }
        return matched
    }

    private static func pairPositionally(
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
    ) async {
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
            return
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
        } catch is CancellationError {
        } catch {
            DiagnosticsLog.shared.record(
                "Photo360: upload failed for \(photo.localId): \(error.localizedDescription)",
                category: .error
            )
        }
    }
}
