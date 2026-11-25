import Foundation

struct TyprSettings {
    static let mechanicalKeyboardKey = "typr.mechanicalKeyboard"

    nonisolated(unsafe) static let shared = TyprSettings()

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    var mechanicalKeyboard: Bool {
        get { defaults?.object(forKey: Self.mechanicalKeyboardKey) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Self.mechanicalKeyboardKey) }
    }
}
