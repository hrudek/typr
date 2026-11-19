import Foundation

/// Delete restores the last automatic correction only this long after it went in.
nonisolated struct KeyboardUndoWindow: Equatable, Sendable {
    static let duration: TimeInterval = 3

    let closesAt: TimeInterval

    init(openedAt: TimeInterval) {
        closesAt = openedAt + Self.duration
    }

    func isOpen(at now: TimeInterval) -> Bool { now < closesAt }
}
