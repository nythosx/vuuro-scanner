import Foundation

struct RoomPhotoMetadata: Codable, Equatable {
    let localId: String
    let capturedAt: Date
    let positionM: [Double]
    let headingDeg: Double
    let pitchDeg: Double
    let zoom: Double
    var cameraTransform: [Double]? = nil
    var intrinsics: [Double]? = nil

    init(
        localId: String,
        capturedAt: Date,
        positionM: [Double],
        headingDeg: Double,
        pitchDeg: Double,
        zoom: Double = 1.0,
        cameraTransform: [Double]? = nil,
        intrinsics: [Double]? = nil
    ) {
        self.localId = localId
        self.capturedAt = capturedAt
        self.positionM = positionM
        self.headingDeg = headingDeg
        self.pitchDeg = pitchDeg
        self.zoom = zoom
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localId = try c.decode(String.self, forKey: .localId)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        positionM = try c.decode([Double].self, forKey: .positionM)
        headingDeg = try c.decode(Double.self, forKey: .headingDeg)
        pitchDeg = try c.decode(Double.self, forKey: .pitchDeg)
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        cameraTransform = try c.decodeIfPresent([Double].self, forKey: .cameraTransform)
        intrinsics = try c.decodeIfPresent([Double].self, forKey: .intrinsics)
    }
}

struct RoomPhotoFinishCoverage: Codable, Equatable {
    let overall: Double
    let position: Double
    let walls: Double
    let ready: Bool
    let wallsTotal: Int
    let wallsCovered: Int
    let cellsTotal: Int
    let cellsCovered: Int

    enum CodingKeys: String, CodingKey {
        case overall
        case position
        case walls
        case ready
        case wallsTotal = "walls_total"
        case wallsCovered = "walls_covered"
        case cellsTotal = "cells_total"
        case cellsCovered = "cells_covered"
    }
}

struct RoomPhotoManifest: Codable, Equatable {
    let captureGroupId: String
    let roomKey: String
    let structureOriginM: [Double]?
    let capturedAt: Date
    var photos: [RoomPhotoMetadata]
    var finishCoverage: RoomPhotoFinishCoverage? = nil
}

@MainActor
final class RoomPhotoStore {
    static let shared = RoomPhotoStore()

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootDirectory = base.appendingPathComponent("VuuroScan/photo-tour", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    func savePhoto(
        _ data: Data,
        metadata: RoomPhotoMetadata,
        captureGroupId: String,
        roomKey: String,
        structureOriginM: [Double]?
    ) throws {
        let dir = batchDirectory(captureGroupId: captureGroupId, roomKey: roomKey)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let photoURL = dir.appendingPathComponent("\(metadata.localId).jpg")
        try data.write(to: photoURL, options: [.atomic, .completeFileProtection])

        var manifest: RoomPhotoManifest
        if fileManager.fileExists(atPath: manifestURL(captureGroupId: captureGroupId, roomKey: roomKey).path) {
            manifest = try loadManifest(captureGroupId: captureGroupId, roomKey: roomKey)
        } else {
            manifest = RoomPhotoManifest(
                captureGroupId: captureGroupId,
                roomKey: roomKey,
                structureOriginM: structureOriginM,
                capturedAt: metadata.capturedAt,
                photos: []
            )
        }
        manifest.photos.removeAll { $0.localId == metadata.localId }
        manifest.photos.append(metadata)
        try writeManifest(manifest, captureGroupId: captureGroupId, roomKey: roomKey)
    }

    func loadManifest(captureGroupId: String, roomKey: String) throws -> RoomPhotoManifest {
        let url = manifestURL(captureGroupId: captureGroupId, roomKey: roomKey)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RoomPhotoManifest.self, from: data)
    }

    func loadPhotoData(localId: String, captureGroupId: String, roomKey: String) throws -> Data {
        let url = batchDirectory(captureGroupId: captureGroupId, roomKey: roomKey)
            .appendingPathComponent("\(localId).jpg")
        return try Data(contentsOf: url)
    }

    func deletePhoto(localId: String, captureGroupId: String, roomKey: String) throws {
        let dir = batchDirectory(captureGroupId: captureGroupId, roomKey: roomKey)
        let photoURL = dir.appendingPathComponent("\(localId).jpg")
        try? fileManager.removeItem(at: photoURL)

        var manifest = try loadManifest(captureGroupId: captureGroupId, roomKey: roomKey)
        manifest.photos.removeAll { $0.localId == localId }
        try writeManifest(manifest, captureGroupId: captureGroupId, roomKey: roomKey)
    }

    func saveFinishCoverage(_ coverage: RoomPhotoFinishCoverage, captureGroupId: String, roomKey: String) throws {
        guard fileManager.fileExists(atPath: manifestURL(captureGroupId: captureGroupId, roomKey: roomKey).path) else { return }
        var manifest = try loadManifest(captureGroupId: captureGroupId, roomKey: roomKey)
        manifest.finishCoverage = coverage
        try writeManifest(manifest, captureGroupId: captureGroupId, roomKey: roomKey)
    }

    func saveWalkPaths(_ paths: [[[Double]]], captureGroupId: String, roomKey: String) throws {
        let dir = batchDirectory(captureGroupId: captureGroupId, roomKey: roomKey)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(paths)
        try data.write(to: walkPathsURL(captureGroupId: captureGroupId, roomKey: roomKey), options: [.atomic, .completeFileProtection])
    }

    func loadWalkPaths(captureGroupId: String, roomKey: String) -> [[[Double]]] {
        let url = walkPathsURL(captureGroupId: captureGroupId, roomKey: roomKey)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([[[Double]]].self, from: data)) ?? []
    }

    func allBatches(captureGroupId: String) throws -> [RoomPhotoManifest] {
        let groupDir = captureGroupDirectory(captureGroupId: captureGroupId)
        guard fileManager.fileExists(atPath: groupDir.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: groupDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var manifests: [RoomPhotoManifest] = []
        for url in entries {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            if let manifest = try? loadManifest(captureGroupId: captureGroupId, roomKey: url.lastPathComponent) {
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.capturedAt < $1.capturedAt }
    }

    func clearAll(captureGroupId: String) {
        let groupDir = captureGroupDirectory(captureGroupId: captureGroupId)
        try? fileManager.removeItem(at: groupDir)
    }

    private func captureGroupDirectory(captureGroupId: String) -> URL {
        rootDirectory.appendingPathComponent(sanitized(captureGroupId), isDirectory: true)
    }

    private func batchDirectory(captureGroupId: String, roomKey: String) -> URL {
        captureGroupDirectory(captureGroupId: captureGroupId)
            .appendingPathComponent(sanitized(roomKey), isDirectory: true)
    }

    private func manifestURL(captureGroupId: String, roomKey: String) -> URL {
        batchDirectory(captureGroupId: captureGroupId, roomKey: roomKey)
            .appendingPathComponent("manifest.json")
    }

    private func walkPathsURL(captureGroupId: String, roomKey: String) -> URL {
        batchDirectory(captureGroupId: captureGroupId, roomKey: roomKey)
            .appendingPathComponent("walk.json")
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
    }

    private func writeManifest(_ manifest: RoomPhotoManifest, captureGroupId: String, roomKey: String) throws {
        let url = manifestURL(captureGroupId: captureGroupId, roomKey: roomKey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
