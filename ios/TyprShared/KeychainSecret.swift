import Foundation
import Security

/// A generic password, readable only after first unlock and never migrated to another device.
/// Without an access group it stays in the app's own group; the App Group's access group lets
/// the keyboard read it too (App Groups are Keychain access groups, no extra entitlement).
nonisolated final class KeychainSecret: Sendable {
    static let anthropicAPIKey = KeychainSecret(service: "dev.rudek.typr.anthropic", account: "api-key")
    static let keyboardAnthropicAPIKey = KeychainSecret(service: "dev.rudek.typr.anthropic.keyboard",
                                                        account: "api-key", accessGroup: KeyboardBridge.appGroup)

    private let service: String
    private let account: String
    private let accessGroup: String?

    init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item.merge(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
