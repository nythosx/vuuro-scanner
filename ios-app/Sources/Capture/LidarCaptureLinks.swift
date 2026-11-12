import SwiftUI

struct LidarCaptureMatch: Identifiable, Equatable {
    let url: URL
    let manifest: LidarCaptureManifest
    let matchedByTime: Bool

    var id: String { url.lastPathComponent }

    var createdAt: Date? { LidarCaptureLibrary.date(manifest.createdAt) }

    var savedFrames: Int { manifest.stats.frames + (manifest.stats.depthOnlyFrames ?? 0) }

    var hasMesh: Bool {
        if manifest.stats.meshSeen { return true }
        if case .success(let report?) = DepthMeshFusion.loadReport(captureURL: url) {
            return report.faces > 0
        }
        return false
    }
}

extension LidarCaptureLibrary {
    static let keepLinkedCaptures = 10
    static let timeMatchSlackS: TimeInterval = 600

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    static func matches(sessionId: String, sessionDates: [Date]) -> Result<[LidarCaptureMatch], Error> {
        let folders: [URL]
        do {
            folders = try captures()
        } catch {
            return .failure(error)
        }
        var result: [LidarCaptureMatch] = []
        for url in folders {
            let manifest: LidarCaptureManifest
            do {
                manifest = try LidarCaptureLibrary.manifest(at: url)
            } catch {
                DiagnosticsLog.shared.record("LiDAR capture \(url.lastPathComponent) skipped, its manifest could not be read: \(error.localizedDescription)", category: .error)
                continue
            }
            if let linked = manifest.sessionId {
                if linked == sessionId {
                    result.append(LidarCaptureMatch(url: url, manifest: manifest, matchedByTime: false))
                }
            } else if overlaps(manifest, sessionDates) {
                result.append(LidarCaptureMatch(url: url, manifest: manifest, matchedByTime: true))
            }
        }
        return .success(substantiveFirst(result))
    }

    static func substantiveFirst(_ captures: [LidarCaptureMatch]) -> [LidarCaptureMatch] {
        captures.sorted { a, b in
            if a.manifest.stats.frames != b.manifest.stats.frames { return a.manifest.stats.frames > b.manifest.stats.frames }
            if a.manifest.durationS != b.manifest.durationS { return a.manifest.durationS > b.manifest.durationS }
            if a.savedFrames != b.savedFrames { return a.savedFrames > b.savedFrames }
            return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
        }
    }

    static func meshURL(_ captures: [LidarCaptureMatch], selectedId: String?, meshIds: Set<String>) -> URL? {
        guard let capture = captures.first(where: { $0.id == selectedId }) ?? captures.first,
              meshIds.contains(capture.id) else { return nil }
        return capture.url
    }

    static func overlaps(_ manifest: LidarCaptureManifest, _ dates: [Date]) -> Bool {
        guard let start = date(manifest.createdAt), let end = date(manifest.updatedAt) else { return false }
        let lower = start.addingTimeInterval(-timeMatchSlackS)
        let upper = max(start, end).addingTimeInterval(timeMatchSlackS)
        return dates.contains { $0 >= lower && $0 <= upper }
    }

    static func pruneOld(keeping entries: [ScanHistoryEntry]) {
        let ids = Set(entries.map(\.sessionId))
        let dates = entries.flatMap { [$0.createdAt] + ($0.lastCapturedAt.map { [$0] } ?? []) }
        do {
            var linkedKept = 0
            var otherKept = 0
            for url in try captures() {
                var protected = false
                do {
                    let manifest = try LidarCaptureLibrary.manifest(at: url)
                    if let sessionId = manifest.sessionId {
                        protected = ids.contains(sessionId)
                    } else {
                        protected = overlaps(manifest, dates)
                    }
                } catch {
                    protected = false
                }
                let keep: Bool
                if protected {
                    linkedKept += 1
                    keep = linkedKept <= keepLinkedCaptures
                } else {
                    otherKept += 1
                    keep = otherKept <= keepCaptures
                }
                if !keep {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            DiagnosticsLog.shared.record("Old LiDAR captures could not be removed: \(error.localizedDescription)", category: .error)
        }
    }

    static func deleteCaptures(sessionId: String) {
        do {
            for url in try captures() {
                do {
                    guard try LidarCaptureLibrary.manifest(at: url).sessionId == sessionId else { continue }
                } catch {
                    continue
                }
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            DiagnosticsLog.shared.record("LiDAR captures for scan \(sessionId) could not be removed: \(error.localizedDescription)", category: .error)
        }
    }

    static func lookup(sessionId: String) -> (captures: [LidarCaptureMatch], error: String?) {
        let entry = ScanHistoryStore.shared.entry(sessionId: sessionId)
        let dates = entry.map { [$0.createdAt] + ($0.lastCapturedAt.map { [$0] } ?? []) } ?? []
        switch matches(sessionId: sessionId, sessionDates: dates) {
        case .success(let found):
            return (found, nil)
        case .failure(let error):
            return ([], "Could not look for this scan's LiDAR capture: \(error.localizedDescription)")
        }
    }
}

struct LidarCaptureEntryButton: View {
    let captures: [LidarCaptureMatch]
    let lookupError: String?
    let identifierPrefix: String
    @Binding var selectedId: String?
    var onClose: () -> Void = {}

    @State private var showProof = false

    var body: some View {
        Group {
            if !captures.isEmpty {
                Button {
                    showProof = true
                } label: {
                    HStack {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 18))
                        Text(captures.count > 1 ? "LiDAR captures (\(captures.count)): mesh, depth and frames" : "LiDAR capture: mesh, depth and frames")
                            .font(.system(size: 16, weight: .bold))
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .background(VuuroColor.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("\(identifierPrefix).lidarCapture")
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            } else if let lookupError {
                Text(lookupError)
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                Text("No LiDAR capture for this scan on this phone.")
                    .font(.system(size: 14))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showProof, onDismiss: onClose) {
            NavigationStack {
                LiDARProofView(captures: captures, selectedId: $selectedId)
            }
        }
    }
}
