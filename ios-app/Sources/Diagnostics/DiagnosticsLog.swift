
import Foundation

struct DiagnosticsLogEntry: Identifiable {
    enum Category: String {
        case info = "INFO"
        case error = "ERROR"
        case state = "STATE"
        case instruction = "INSTRUCTION"
        case request = "REQUEST"
    }

    let id = UUID()
    let timestamp: Date
    let category: Category
    let message: String
}

final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @MainActor @Published private(set) var entries: [DiagnosticsLogEntry] = []

    private let maxEntries = 300

    private init() {
        record(BuildInfo.summary, category: .info)
    }

    nonisolated func record(_ rawMessage: String, category: DiagnosticsLogEntry.Category) {
        let message = DiagnosticsRedactor.redact(rawMessage)
        #if DEBUG
        print("[VuuroScan][\(category.rawValue)] \(message)")
        #endif
        let entry = DiagnosticsLogEntry(timestamp: Date(), category: category, message: message)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }
}
