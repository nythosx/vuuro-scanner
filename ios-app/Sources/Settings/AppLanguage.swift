
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case dutch = "nl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System default"
        case .english: return "English"
        case .dutch: return "Nederlands"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .english: return Locale(identifier: "en")
        case .dutch: return Locale(identifier: "nl")
        }
    }
}

enum AppLanguageSettings {
    static let storageKey = "appLanguage"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue) ?? .system
    }

    static var effectiveLocale: Locale {
        current.locale ?? Locale.autoupdatingCurrent
    }
}
