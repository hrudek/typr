import Foundation

/// Settings › Typr: the fork's own options, in the App Group defaults the app and the
/// keyboard both read.
struct TyprSettings {
    static let mechanicalKeyboardKey = "typr.mechanicalKeyboard"

    /// One instance for the keyboard's drawing, which reads the design on every draw.
    nonisolated(unsafe) static let shared = TyprSettings()

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    /// Mechanical keyboard design: on until turned off.
    var mechanicalKeyboard: Bool {
        get { defaults?.object(forKey: Self.mechanicalKeyboardKey) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Self.mechanicalKeyboardKey) }
    }
}
