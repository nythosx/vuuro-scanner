
#if DEBUG
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

@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @Published private(set) var entries: [DiagnosticsLogEntry] = []

     private let maxEntries = 300

    private init() {
        record(BuildInfo.summary, category: .info)
    }

    func record(_ message: String, category: DiagnosticsLogEntry.Category) {
        entries.append(DiagnosticsLogEntry(timestamp: Date(), category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        print("[VuuroScan][\(category.rawValue)] \(message)")
    }
}
#endif
