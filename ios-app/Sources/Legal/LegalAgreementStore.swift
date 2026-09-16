
import Foundation

enum LegalAgreementStore {
    private static let versionKey = "legalAgreedVersion"
    private static let dateKey = "legalAgreedAt"

    static var agreedVersion: String? {
        UserDefaults.standard.string(forKey: versionKey)
    }

    static var agreedAt: Date? {
        UserDefaults.standard.object(forKey: dateKey) as? Date
    }

    static func recordAgreement(version: String = LegalDocument.currentVersion, at date: Date = Date()) {
        UserDefaults.standard.set(version, forKey: versionKey)
        UserDefaults.standard.set(date, forKey: dateKey)
    }
}
