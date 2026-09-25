import Foundation
import Security

enum KeychainTokenStore {
    private static let service = "com.vuuro.scan.accesstoken"

    @discardableResult
    static func save(token: String, forSessionId sessionId: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionId,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            DiagnosticsLog.shared.record("Keychain delete before save failed for session \(sessionId): OSStatus \(deleteStatus)", category: .error)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus != errSecSuccess {
                DiagnosticsLog.shared.record("Keychain update failed for session \(sessionId): OSStatus \(updateStatus)", category: .error)
                return false
            }
            return true
        } else if addStatus != errSecSuccess {
            DiagnosticsLog.shared.record("Keychain save failed for session \(sessionId): OSStatus \(addStatus)", category: .error)
            return false
        }
        return true
    }

    static func loadToken(forSessionId sessionId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(forSessionId sessionId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func resetIfReinstalled() {
        let key = "com.vuuro.scan.keychainInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        deleteAll()
        UserDefaults.standard.set(true, forKey: key)
        Task { @MainActor in
            DiagnosticsLog.shared.record("First launch after install/reinstall detected — cleared any leftover Keychain tokens from a previous install", category: .info)
        }
    }
}
