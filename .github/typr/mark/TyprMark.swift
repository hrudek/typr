/// Typr's "t." mark: the "t" and "." of the typr. wordmark, centred in a square and 7/8 of its
/// height, the span of the hexagon mark it replaces.
enum TyprMark {
    private static let width: CGFloat = 350.05
    private static let height: CGFloat = 429.3

    static func paths(in rect: CGRect) -> (letter: CGPath, dot: CGPath) {
        let scale = min(rect.width, rect.height) * 0.875 / height
        let transform = CGAffineTransform(translationX: rect.midX - width * scale / 2,
                                          y: rect.midY - height * scale / 2)
            .scaledBy(x: scale, y: scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }

        let letter = CGMutablePath()
        letter.move(to: point(40.55, 0))
        for (x, y) in [(127.19, 0), (127.19, 84), (203.4, 84), (203.4, 154.75), (127.19, 154.75), (127.19, 326.25)] {
            letter.addLine(to: point(x, y))
        }
        letter.addCurve(to: point(161, 351.85), control1: point(127.19, 346), control2: point(144.25, 351.85))
        for (x, y) in [(203.4, 351.85), (203.4, 424.3), (133.75, 424.3)] {
            letter.addLine(to: point(x, y))
        }
        letter.addCurve(to: point(40.55, 326.5), control1: point(77.75, 424.3), control2: point(40.55, 381.5))
        for (x, y) in [(40.55, 154.75), (0, 154.75), (0, 84), (40.55, 84)] {
            letter.addLine(to: point(x, y))
        }
        letter.closeSubpath()

        let dot = CGPath(ellipseIn: CGRect(x: 243.45, y: 327.8, width: 106.6, height: 101.5).applying(transform),
                         transform: nil)
        return (letter, dot)
    }
}
