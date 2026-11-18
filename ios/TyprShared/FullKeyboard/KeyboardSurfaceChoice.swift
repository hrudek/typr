import Foundation

// Typr: switching between the full keyboard and the compact dictation bar. The compact
// bar's keyboard key shows the full keyboard; sliding down on the full keyboard's Typr
// key (`TyprKeyGesture`) shows the compact bar.

/// Whether the compact bar or the full keyboard was last chosen (the compact bar's keyboard
/// key, or a downward slide on the Typr key). Kept in the keyboard's own defaults, so it
/// works without Full Access.
@MainActor
struct KeyboardSurfaceChoice {
    private static let key = "typr.keyboardShowsCompactBar"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The compact dictation bar was picked over the full keyboard. Off by default.
    var showsCompactBar: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// The full keyboard runs on iPhone only, unless the compact bar was chosen.
    static func wantsFullKeyboard(isPhone: Bool, compactChosen: Bool) -> Bool {
        isPhone && !compactChosen
    }
}
