import Foundation

enum FloorValidation {
    static let maxLength = 60

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitized(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in trimmed(value).unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            guard scalars.count < maxLength else { break }
            scalars.append(scalar)
        }
        return trimmed(String(scalars))
    }

    static func isValid(_ value: String) -> Bool {
        let cleaned = trimmed(value)
        return !cleaned.isEmpty && cleaned.unicodeScalars.count <= maxLength && cleaned == sanitized(cleaned)
    }
}
