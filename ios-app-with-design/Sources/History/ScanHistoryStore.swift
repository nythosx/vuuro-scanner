//
//  ScanHistoryStore.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Local-only persistence for scan sessions this device has created — see
//  ScanHistoryEntry's header for why this can never be a server-side listing.
//
//  Known limit: backed by UserDefaults, which stores each entry's
//  access_token in plaintext, not the Keychain. Acceptable for this window
//  (local pilot, no App Store distribution — see ../../docs/adr/0001), but a
//  real deployment should move this to the Keychain before shipping, same
//  as any other long-lived credential.
//

import Foundation

final class ScanHistoryStore {
    static let shared = ScanHistoryStore()

    private let defaults: UserDefaults
    private let key = "com.vuuro.scan.history"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [ScanHistoryEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([ScanHistoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ entry: ScanHistoryEntry) {
        var entries = all()
        entries.removeAll { $0.sessionId == entry.sessionId }
        entries.append(entry)
        save(entries)
    }

    func remove(sessionId: String) {
        save(all().filter { $0.sessionId != sessionId })
    }

    private func save(_ entries: [ScanHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
