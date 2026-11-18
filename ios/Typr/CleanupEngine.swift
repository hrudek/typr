import Foundation
import Security

/// Which model runs AI cleanup. App-only: the keyboard never cleans up text itself.
enum CleanupEngine: String, CaseIterable {
    case appleIntelligence = "apple-intelligence"
    case anthropic

    var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .anthropic: "Claude"
        }
    }

    var promptRevision: String { self == .anthropic ? CleanupPrompt.revision : CleanupGuard.revision }

    var guardRevision: String { self == .anthropic ? "none" : CleanupGuard.revision }
}

/// App-only preference in the standard defaults; the next dictation uses it.
@MainActor
struct CleanupEnginePreferences {
    private static let key = "typr.cleanupEngine"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var engine: CleanupEngine {
        get { defaults.string(forKey: Self.key).flatMap(CleanupEngine.init(rawValue:)) ?? .appleIntelligence }
        nonmutating set {
            if newValue == .appleIntelligence {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(newValue.rawValue, forKey: Self.key)
            }
        }
    }
}

/// Raw secret storage: the Keychain in the app, memory in tests.
@MainActor
protocol SecretStoring: AnyObject {
    func read() -> String?
    func write(_ value: String) -> Bool
    func delete()
}

/// The owner's Anthropic API key. Never logged, never in defaults, logs or exports.
@MainActor
struct AnthropicKeyStore {
    private let storage: any SecretStoring

    init(storage: any SecretStoring = KeychainSecret.anthropicAPIKey) {
        self.storage = storage
    }

    var key: String? {
        guard let saved = storage.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty else { return nil }
        return saved
    }

    var hasKey: Bool { key != nil }

    static func canSave(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Trims pasted whitespace; an empty entry never replaces a saved key.
    @discardableResult
    func save(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return storage.write(trimmed)
    }

    func remove() { storage.delete() }
}

/// A generic password in the app's own Keychain access group (no shared group: the keyboard
/// can't read it), only after first unlock and never migrated to another device.
@MainActor
final class KeychainSecret: SecretStoring {
    static let anthropicAPIKey = KeychainSecret(service: "dev.rudek.typr.anthropic", account: "api-key")

    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
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

/// Resolves the engine per call, so a switch applies to the next dictation without a restart.
@MainActor
struct SelectedTranscriptCleaner: TyprTranscriptCleaning {
    let engine: @MainActor () -> CleanupEngine
    let apple: any TyprTranscriptCleaning
    let anthropic: any TyprTranscriptCleaning

    private var current: any TyprTranscriptCleaning {
        engine() == .anthropic ? anthropic : apple
    }

    var unavailableReason: String? { current.unavailableReason }

    func makeSession() -> any CleanupSession { current.makeSession() }
}

/// Apple Intelligence before iOS 26: never available, so its session is never used.
@MainActor
struct UnsupportedAppleCleaner: TyprTranscriptCleaning {
    var unavailableReason: String? { "Requires iOS 26 or later" }
    func makeSession() -> any CleanupSession { UnavailableCleanupSession() }
}

@MainActor
final class UnavailableCleanupSession: CleanupSession {
    func prewarm() async {}
    func generate(_ prompt: String) async throws -> String { throw CleanupModelError.unavailable }
}
