import Foundation

struct TyprSettings {
    static let mechanicalKeyboardKey = "typr.mechanicalKeyboard"
    static let orukeetKey = "typr.orukeet"

    nonisolated(unsafe) static let shared = TyprSettings()

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    var mechanicalKeyboard: Bool {
        get { defaults?.object(forKey: Self.mechanicalKeyboardKey) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Self.mechanicalKeyboardKey) }
    }

    /// Settings › Typr › Orukeet: Hex dictates with Orukeet once it is downloaded and ready.
    var orukeet: Bool {
        get { defaults?.object(forKey: Self.orukeetKey) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Self.orukeetKey) }
    }
}
