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

    var id: String { key ?? "__unknown__" }

    var roomCount: Int { sessions.reduce(0) { $0 + $1.parsedRoomCount } }
    var totalAreaM2: Double { sessions.reduce(0) { $0 + ($1.cachedFloorAreaM2 ?? 0) } }
    var latestDate: Date { sessions.map(\.createdAt).max() ?? .distantPast }
}

struct HomeAggregate: Identifiable {
    let key: HomeKey
    var floors: [FloorGroup]

    var id: String { key.id }

    var totalRooms: Int { floors.reduce(0) { $0 + $1.roomCount } }
    var totalAreaM2: Double { floors.reduce(0) { $0 + $1.totalAreaM2 } }
    var totalSessions: Int { floors.reduce(0) { $0 + $1.sessions.count } }
    var latestDate: Date { floors.map(\.latestDate).max() ?? .distantPast }

    var mostRecentEntry: ScanHistoryEntry? {
        floors.flatMap(\.sessions).max { $0.createdAt < $1.createdAt }
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

    private static func groupByFloor(_ entries: [ScanHistoryEntry]) -> [FloorGroup] {
        var byNormalized: [String: (display: String, sessions: [ScanHistoryEntry])] = [:]
        var unknowns: [ScanHistoryEntry] = []

        for entry in entries {
            let trimmed = (entry.floor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                unknowns.append(entry)
                continue
            }
            let normalized = trimmed.lowercased()
            if var existing = byNormalized[normalized] {
                existing.sessions.append(entry)
                byNormalized[normalized] = existing
            } else {
                byNormalized[normalized] = (display: trimmed, sessions: [entry])
            }
        }

        var groups = byNormalized.map { key, value in
            FloorGroup(
                key: key,
                displayName: value.display,
                rank: floorRank(key),
                sessions: value.sessions.sorted { $0.createdAt > $1.createdAt }
            )
        }
        if !unknowns.isEmpty {
            groups.append(FloorGroup(
                key: nil,
                displayName: nil,
                rank: -1000,
                sessions: unknowns.sorted { $0.createdAt > $1.createdAt }
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
