"""Typr's "t." mark replaces Hex's hexagon mark wherever upstream draws it."""
from pathlib import Path
import re

MARK = Path(__file__).resolve().parent / 'mark/TyprMark.swift'
THEME = 'HEXShared/HexTheme.swift'
PALETTE = 'HEXShared/FullKeyboard/FullKeyboardPalette.swift'
ONBOARDING = 'HEXMobile/OnboardingPieces.swift'

MARK_VIEW_CANVAS = re.compile(
    r'(struct HexMarkView: View \{\n'
    r'    var size: CGFloat = 20\n'
    r'    var color: Color = HexTheme\.textBase\n'
    r'    var coreColor: Color\? = nil\n'
    r'\n'
    r'    var body: some View \{\n'
    r'        Canvas \{ context, canvasSize in\n)'
    r'.*?'
    r'(\n        \}\n'
    r'        \.frame\(width: size, height: size\)\n'
    r'        \.accessibilityHidden\(true\)\n'
    r'    \}\n'
    r'\}\n)', re.DOTALL)
MARK_VIEW_DRAWING = (
    '            let mark = TyprMark.paths(in: CGRect(origin: .zero, size: canvasSize))\n'
    '            context.fill(Path(mark.letter), with: .color(color))\n'
    '            context.fill(Path(mark.dot), with: .color(coreColor ?? color))')

MARK_PATH = re.compile(
    r'enum HexMarkPath \{\n'
    r'.*?'
    r'\n    static func draw\(in context: CGContext, rect: CGRect, color: UIColor, coreColor: UIColor\?\) \{\n'
    r'.*?'
    r'\n    \}\n'
    r'\}\n', re.DOTALL)
MARK_PATH_TYPR = '''enum HexMarkPath {
    static func draw(in context: CGContext, rect: CGRect, color: UIColor, coreColor: UIColor?) {
        let mark = TyprMark.paths(in: rect)
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(mark.letter)
        context.fillPath()
        context.setFillColor((coreColor ?? color).cgColor)
        context.addPath(mark.dot)
        context.fillPath()
        context.restoreGState()
    }
}
'''

PROGRESS_HEXAGON = '''struct OnboardingHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0...6 {
            let angle = Double(i) * .pi / 3 - .pi / 2
            let point = CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
'''
PROGRESS_RING = '''struct OnboardingHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
        return path
    }
}
'''

HEXAGON_CODE = re.compile(r'\.pi / 3|\(32, 4\)|x: 32, y: 4|systemName: "hexagon')
SOURCES = ('HEXMobile', 'HEXShared', 'HEXKeyboard', 'HEXWidgets', 'HEXActivity')


def swap(ios, relative, pattern, replacement):
    path = ios / relative
    text, count = pattern.subn(replacement, path.read_text())
    if count != 1:
        raise ValueError(f'{relative}: expected 1 `{pattern.pattern[:40]}…` to swap for the Typr mark, found {count}')
    path.write_text(text)


def apply(ios):
    ios = Path(ios)
    theme = ios / THEME
    if 'enum TyprMark ' in theme.read_text():
        raise ValueError(f'{THEME} already defines TyprMark')
    swap(ios, THEME, MARK_VIEW_CANVAS, lambda m: m[1] + MARK_VIEW_DRAWING + m[2])
    theme.write_text(theme.read_text() + '\n' + MARK.read_text())
    swap(ios, PALETTE, MARK_PATH, lambda m: MARK_PATH_TYPR)
    swap(ios, ONBOARDING, re.compile(re.escape(PROGRESS_HEXAGON)), lambda m: PROGRESS_RING)
    left = sorted(f'{path.relative_to(ios)}:{match[0]}'
                  for source in SOURCES for path in (ios / source).rglob('*.swift')
                  for match in HEXAGON_CODE.finditer(path.read_text()))
    if left:
        raise ValueError(f'Hexagon drawing left after the Typr mark swap: {left}')
