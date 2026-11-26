import CoreGraphics
import Foundation

/// Typr: a swipe down on the full keyboard's Typr key switches to the minimal keyboard
/// (`TyprKeyboardModeToggle`). `HexKeyControl` asks `decide` at each move while the press is
/// still pending, before upstream's `HexKeyGesture` would open the style menu on it. Only a
/// move whose first direction is within `maxAngleFromDown` of straight down is claimed; every
/// other move is upstream's, and once the menu is open or the hold has fired nothing is claimed.
nonisolated struct TyprKeySwipe: Equatable, Sendable {
    /// How far from straight down (degrees, either side) a move still counts as down.
    static let maxAngleFromDown: CGFloat = 30
    /// The downward travel that makes the swipe: a little past upstream's slop.
    static let minDistance: CGFloat = HexKeyGesture.slop + 6

    enum Decision: Equatable, Sendable {
        /// Not ours: upstream's gesture handles the move.
        case upstream
        /// Down, but short of `minDistance`: keep pressing, open no menu yet.
        case wait
        /// Switch keyboards; the press is over.
        case claim
    }

    private var origin: CGPoint = .zero

    mutating func begin(at point: CGPoint) {
        origin = point
    }

    func decide(at point: CGPoint, state: HexKeyGesture.State) -> Decision {
        guard state == .pressing else { return .upstream }
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        guard hypot(dx, dy) > HexKeyGesture.slop, dy > 0 else { return .upstream }
        let angle = atan2(abs(dx), dy) * 180 / .pi
        guard angle <= Self.maxAngleFromDown else { return .upstream }
        return dy >= Self.minDistance ? .claim : .wait
    }
}
