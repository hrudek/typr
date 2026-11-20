import CoreGraphics

/// A downward swipe that starts off every key hides the keyboard.
nonisolated enum KeyboardDismissSwipe {
    static let minimumDrop: CGFloat = 40
    /// Downward travel must be at least this many times the sideways travel.
    static let minimumSteepness: CGFloat = 2

    static func dismisses(translation: CGSize) -> Bool {
        translation.height >= minimumDrop && translation.height >= abs(translation.width) * minimumSteepness
    }
}
