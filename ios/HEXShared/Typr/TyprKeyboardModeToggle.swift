import SwiftUI

/// Typr: the keyboard's temporary switch to the minimal dictation-only keyboard, for a field
/// that wants the full keyboard otherwise. It lives for the keyboard process, never writes
/// `FullKeyboardSettings`, and `reset` (each time the keyboard appears) puts the Settings
/// choice back in charge.
@MainActor
final class TyprKeyboardModeToggle {
    static let shared = TyprKeyboardModeToggle()

    /// True while a swipe has switched a full-keyboard setting to the minimal keyboard.
    private(set) var forcesMinimal = false
    /// The keyboard remounts its surface here.
    var onChange: (() -> Void)?

    /// Upstream's choice (`FullKeyboardSettings.isEnabled`, or Full Access missing) unless the
    /// swipe overrode it.
    func wantsFull(setting: Bool, hasFullAccess: Bool) -> Bool {
        (setting && !forcesMinimal) || !hasFullAccess
    }

    func switchToMinimal() { set(true) }
    func switchToFull() { set(false) }

    /// The keyboard appeared: back to the Settings value, without a remount (the caller mounts).
    func reset() { forcesMinimal = false }

    private func set(_ value: Bool) {
        guard value != forcesMinimal else { return }
        forcesMinimal = value
        onChange?()
    }
}

/// The minimal keyboard's extra key, back to the full keyboard. `style` is the neighbour keys'.
struct TyprFullKeyboardKey<Style: ButtonStyle>: View {
    let style: Style
    let ink: Color
    let glyphOpacity: Double
    let onFeedback: () -> Void

    var body: some View {
        Button {
            onFeedback()
            TyprKeyboardModeToggle.shared.switchToFull()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(ink)
                .opacity(glyphOpacity)
                .frame(width: 38, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(style)
        .accessibilityLabel("Full keyboard")
    }
}
