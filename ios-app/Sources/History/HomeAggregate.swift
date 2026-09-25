import Foundation

struct HomeKey: Hashable, Identifiable {
    let propertyId: String
    let unitId: String
    let organisationId: String

    var id: String { "\(propertyId)\u{1F}\(unitId)\u{1F}\(organisationId)" }

    var displayName: String {
        let p = propertyId.isEmpty ? "Untitled" : propertyId
        return unitId.isEmpty ? p : "\(p) \u{00B7} \(unitId)"
    }

    init(propertyId: String, unitId: String, organisationId: String) {
        self.propertyId = propertyId
        self.unitId = unitId
        self.organisationId = organisationId
    }

    init(entry: ScanHistoryEntry) {
        self.propertyId = entry.propertyId
        self.unitId = entry.unitId
        self.organisationId = entry.organisationId
    }
}

struct FloorGroup: Identifiable {
    let key: String?
    let displayName: String?
    let rank: Int
    var sessions: [ScanHistoryEntry]
    var roomCount: Int
    var totalAreaM2: Double

    var id: String { key ?? "__unknown__" }

    var latestDate: Date { sessions.map(\.createdAt).max() ?? .distantPast }
}

struct HomeAggregate: Identifiable {
    let key: HomeKey
    var floors: [FloorGroup]

    var id: String { key.id }

    var totalRooms: Int { floors.reduce(0) { $0 + $1.roomCount } }
    var totalAreaM2: Double { floors.reduce(0) { $0 + $1.totalAreaM2 } }
    var totalSessions: Int { Set(floors.flatMap { $0.sessions.map(\.sessionId) }).count }
    var latestDate: Date { floors.map(\.latestDate).max() ?? .distantPast }

    var mostRecentEntry: ScanHistoryEntry? {
        var seen = Set<String>()
        return floors
            .flatMap(\.sessions)
            .filter { seen.insert($0.sessionId).inserted }
            .max { $0.createdAt < $1.createdAt }
    }
}

enum HomeAddRoomsRequest {
    case newVisit(ScanIdentity)
    case addToScan(ScanHistoryEntry, floor: String)
}

enum HomeAggregator {
    static func aggregate(_ entries: [ScanHistoryEntry]) -> [HomeAggregate] {
        var byKey: [HomeKey: [ScanHistoryEntry]] = [:]
        for entry in entries {
            byKey[HomeKey(entry: entry), default: []].append(entry)
        }
        return byKey
            .map { HomeAggregate(key: $0.key, floors: groupByFloor($0.value)) }
            .sorted { $0.latestDate > $1.latestDate }
    }

    private struct FloorBucket {
        let normalizedKey: String?
        let displayName: String
        let roomCount: Int
        let areaM2: Double
    }

    private static func floorBuckets(for entry: ScanHistoryEntry) -> [FloorBucket] {
        if let perFloor = entry.cachedRoomsByFloor, !perFloor.isEmpty {
            let sessionFloor = (entry.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return perFloor.map { name, summary in
                let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmed = named.isEmpty ? sessionFloor : named
                return FloorBucket(
                    normalizedKey: trimmed.isEmpty ? nil : trimmed.lowercased(),
                    displayName: trimmed,
                    roomCount: summary.roomCount,
                    areaM2: summary.areaM2
                )
            }
        }
        let trimmed = (entry.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [FloorBucket(
            normalizedKey: trimmed.isEmpty ? nil : trimmed.lowercased(),
            displayName: trimmed,
            roomCount: entry.parsedRoomCount,
            areaM2: entry.cachedFloorAreaM2 ?? 0
        )]
    }

    private static func groupByFloor(_ entries: [ScanHistoryEntry]) -> [FloorGroup] {
        var byNormalized: [String: (display: String, sessions: [ScanHistoryEntry], roomCount: Int, areaM2: Double)] = [:]
        var unknownSessions: [ScanHistoryEntry] = []
        var unknownRoomCount = 0
        var unknownAreaM2 = 0.0

        for entry in entries {
            for bucket in floorBuckets(for: entry) {
                guard let key = bucket.normalizedKey else {
                    if !unknownSessions.contains(where: { $0.sessionId == entry.sessionId }) {
                        unknownSessions.append(entry)
                    }
                    unknownRoomCount += bucket.roomCount
                    unknownAreaM2 += bucket.areaM2
                    continue
                }
                if var existing = byNormalized[key] {
                    if !existing.sessions.contains(where: { $0.sessionId == entry.sessionId }) {
                        existing.sessions.append(entry)
                    }
                    existing.roomCount += bucket.roomCount
                    existing.areaM2 += bucket.areaM2
                    byNormalized[key] = existing
                } else {
                    byNormalized[key] = (
                        display: bucket.displayName,
                        sessions: [entry],
                        roomCount: bucket.roomCount,
                        areaM2: bucket.areaM2
                    )
                }
            }
        }

        var groups = byNormalized.map { key, value in
            FloorGroup(
                key: key,
                displayName: value.display,
                rank: floorRank(key),
                sessions: value.sessions.sorted { $0.createdAt > $1.createdAt },
                roomCount: value.roomCount,
                totalAreaM2: value.areaM2
            )
        }
        if !unknownSessions.isEmpty {
            groups.append(FloorGroup(
                key: nil,
                displayName: nil,
                rank: -1000,
                sessions: unknownSessions.sorted { $0.createdAt > $1.createdAt },
                roomCount: unknownRoomCount,
                totalAreaM2: unknownAreaM2
            ))
        }
        return groups.sorted { $0.rank > $1.rank }
    }

    static func floorRank(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("attic") || n.contains("zolder") || n.contains("roof") || n.contains("dak") || n.contains("loft") {
            return 100
        }
        if n.contains("basement") || n.contains("kelder") || n.contains("cellar") || n.contains("souterrain") {
            return -10
        }
        if n.contains("ground") || n.contains("begane") || n.contains("gelijkvloers") || n == "bg" {
            return 0
        }
        if let range = n.range(of: "\\d+", options: .regularExpression), let v = Int(n[range]) {
            return v
        }
        if n.contains("first") || n.contains("eerste") { return 1 }
        if n.contains("second") || n.contains("tweede") { return 2 }
        if n.contains("third") || n.contains("derde") { return 3 }
        if n.contains("fourth") || n.contains("vierde") { return 4 }
        return 5
    }
}

extension ScanHistoryEntry {
    var parsedRoomCount: Int {
        guard let summary = cachedRoomSummary, !summary.isEmpty else { return 0 }
        let parts = summary.components(separatedBy: ", ")
        var count = parts.count
        if let last = parts.last, last.hasPrefix("+"), last.hasSuffix(" more") {
            let inner = last.dropFirst().dropLast(" more".count)
            if let n = Int(inner) {
                count = count - 1 + n
            }
        }
        return count
    }
}
