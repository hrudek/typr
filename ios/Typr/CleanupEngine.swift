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

/// The owner's Anthropic API key. Never logged, never in defaults, logs or exports. A copy in
/// the App Group's Keychain access group lets the keyboard ask Claude for next-word predictions.
@MainActor
struct AnthropicKeyStore {
    private let storage: any SecretStoring
    private let keyboardCopy: (any SecretStoring)?

    init() {
        self.init(storage: KeychainSecret.anthropicAPIKey, keyboardCopy: KeychainSecret.keyboardAnthropicAPIKey)
    }

    init(storage: any SecretStoring, keyboardCopy: (any SecretStoring)? = nil) {
        self.storage = storage
        self.keyboardCopy = keyboardCopy
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
        guard !trimmed.isEmpty, storage.write(trimmed) else { return false }
        syncKeyboardCopy()
        return true
    }

    func remove() {
        storage.delete()
        keyboardCopy?.delete()
    }

    /// The keyboard's copy matches the saved key; keys saved before the copy existed get one at launch.
    func syncKeyboardCopy() {
        guard let keyboardCopy else { return }
        if let key {
            if keyboardCopy.read() != key, !keyboardCopy.write(key) { keyboardCopy.delete() }
        } else {
            keyboardCopy.delete()
        }
    }
}

extension KeychainSecret: SecretStoring {}

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
