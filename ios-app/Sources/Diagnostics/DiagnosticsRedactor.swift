import Foundation

enum DiagnosticsRedactor {
    static let placeholder = "[redacted]"

    private static let keyedSecret = try! NSRegularExpression(
        pattern: #"(?i)("?(?:access_token|accessToken|token|admin_key|api_key|apiKey|X-Scan-Access-Token|X-Admin-Key|password|secret)"?\s*[:=]\s*"?)([^\s"'&,;}]+)"#
    )
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)(Bearer\s+)([^\s"']+)"#)
    private static let shareCode = try! NSRegularExpression(pattern: #"VUURO-SCAN-1:[A-Za-z0-9+/=_-]+"#)
    private static let opaque = try! NSRegularExpression(pattern: #"[A-Za-z0-9_+=-]{32,}"#)
    private static let uuid = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    )

    static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where secret.count >= 8 {
            result = result.replacingOccurrences(of: secret, with: placeholder)
        }
        result = replace(keyedSecret, in: result, template: "$1\(placeholder)")
        result = replace(bearer, in: result, template: "$1\(placeholder)")
        result = replace(shareCode, in: result, template: "VUURO-SCAN-1:\(placeholder)")
        return redactOpaqueTokens(result)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func redactOpaqueTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in opaque.matches(in: text, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let candidate = String(result[swiftRange])
            let candidateRange = NSRange(candidate.startIndex..., in: candidate)
            if uuid.firstMatch(in: candidate, range: candidateRange) != nil { continue }
            result.replaceSubrange(swiftRange, with: placeholder)
        }
        return result
    }
}
