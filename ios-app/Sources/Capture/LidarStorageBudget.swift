import Foundation

enum LidarStorageBudget {
    static let warnBelowMB = 2048
    static let stopBelowMB = 1024
    static let checkIntervalS: TimeInterval = 5
    static let measuredMBPerMinute: Double = 41.5
    static let measuredMBPerSquareMetre: Double = 4.7

    enum Level: Equatable {
        case ok
        case low
        case full
    }

    static func level(freeMB: Int) -> Level {
        if freeMB < stopBelowMB { return .full }
        if freeMB < warnBelowMB { return .low }
        return .ok
    }

    static func minutesLeft(freeMB: Int) -> Int {
        max(0, Int(Double(freeMB - stopBelowMB) / measuredMBPerMinute))
    }

    static func squareMetresLeft(freeMB: Int) -> Int {
        max(0, Int(Double(freeMB - stopBelowMB) / measuredMBPerSquareMetre))
    }

    static func mbPerMinute(bytes: Int64, durationS: Double) -> Double? {
        guard durationS >= 10, bytes > 0 else { return nil }
        return Double(bytes) / 1_048_576 / (durationS / 60)
    }

    static func freeMB(at url: URL) -> Result<Int, Error> {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
                return .failure(PlainError(message: "The phone did not report its free storage."))
            }
            return .success(Int(bytes / 1_048_576))
        } catch {
            return .failure(error)
        }
    }

    static func lowNote(freeMB: Int) -> String {
        String(format: vuuroLocalized("Phone storage is low: about %ld min or %ld m² of LiDAR left. Finish this room soon."), minutesLeft(freeMB: freeMB), squareMetresLeft(freeMB: freeMB))
    }
}
