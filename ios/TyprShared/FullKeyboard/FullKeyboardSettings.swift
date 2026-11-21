import Foundation

nonisolated enum KeyboardDesign: String, CaseIterable, Sendable {
    case standard = "default"
    case mechanical
}

/// The full keyboard's switches in the shared App Group.
@MainActor
struct FullKeyboardSettings {
    private enum Key {
        static let autocorrect = "settings.keyboardAutocorrect"
        static let swipeTyping = "settings.keyboardSwipeTyping"
        static let globeKey = "settings.keyboardGlobeKey"
        static let bottomRowOrder = "settings.keyboardBottomRowOrder"
        static let periodKey = "settings.keyboardPeriodKey"
        static let numberRow = "settings.keyboardNumberRow"
        static let splitKeyboard = "settings.keyboardSplit"
        static let splitColumns = "settings.keyboardSplitColumns"
        static let splitMirrored = "settings.keyboardSplitMirrored"
        static let design = "settings.keyboardDesign"
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    /// Cautious autocorrect on space. On by default.
    var autocorrect: Bool {
        get { defaults?.object(forKey: Key.autocorrect) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.autocorrect) }
    }

    /// Swipe typing over the letters. On by default; off keeps sliding as slide-to-key.
    var swipeTyping: Bool {
        get { defaults?.object(forKey: Key.swipeTyping) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Key.swipeTyping) }
    }

    /// The bottom row's globe where iOS needs one. Switches keyboards by default.
    var globeKey: GlobeKey {
        get { defaults?.string(forKey: Key.globeKey).flatMap(GlobeKey.init(rawValue:)) ?? .switches }
        nonmutating set { defaults?.set(newValue.rawValue, forKey: Key.globeKey) }
    }

    /// The keys around the space bar. Space then Typr, no period key, by default.
    var bottomRow: BottomRow {
        get {
            let order = (defaults?.stringArray(forKey: Key.bottomRowOrder) ?? []).compactMap(BottomKey.init(rawValue:))
            return BottomRow(
                order: BottomKey.arranged(order),
                periodKey: defaults?.object(forKey: Key.periodKey) as? Bool ?? false
            )
        }
        nonmutating set {
            defaults?.set(newValue.order.map(\.rawValue), forKey: Key.bottomRowOrder)
            defaults?.set(newValue.periodKey, forKey: Key.periodKey)
        }
    }

    /// 1 to 0 above the letters. Off by default.
    var numberRow: Bool {
        get { defaults?.object(forKey: Key.numberRow) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.numberRow) }
    }

    /// Two halves under the thumbs on the iPhone Duo open and sideways. Off by default.
    var splitKeyboard: Bool {
        get { defaults?.object(forKey: Key.splitKeyboard) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.splitKeyboard) }
    }

    /// The split keyboard's letters in straight columns instead of staggered rows. Off by default.
    var splitColumns: Bool {
        get { defaults?.object(forKey: Key.splitColumns) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.splitColumns) }
    }

    /// The split keyboard's left half moved out so both halves sit equally far from the centre. Off by default.
    var splitMirrored: Bool {
        get { defaults?.object(forKey: Key.splitMirrored) as? Bool ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.splitMirrored) }
    }

    var design: KeyboardDesign {
        get { defaults?.string(forKey: Key.design).flatMap(KeyboardDesign.init(rawValue:)) ?? .standard }
        nonmutating set { defaults?.set(newValue.rawValue, forKey: Key.design) }
    }
}
