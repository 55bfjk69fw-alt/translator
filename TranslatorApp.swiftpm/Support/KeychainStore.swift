import Foundation
import Security

/// Minimal keychain wrapper for the API keys (OpenAI + DashScope).
enum KeychainStore {
    private static let openAIService = "com.stufflebeam.translator.openai"
    private static let dashScopeService = "com.stufflebeam.translator.dashscope"
    private static let account = "api-key"

    static func saveAPIKey(_ key: String) {
        save(key, service: openAIService)
    }

    static func loadAPIKey() -> String? {
        load(service: openAIService)
    }

    /// DashScope key for the Fun-ASR STT stage (docs/DATONG-STT.md).
    static func saveDashScopeKey(_ key: String) {
        save(key, service: dashScopeService)
    }

    static func loadDashScopeKey() -> String? {
        load(service: dashScopeService)
    }

    private static func save(_ key: String, service: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("Keychain save failed: \(status)")
        }
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
