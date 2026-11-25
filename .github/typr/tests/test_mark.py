import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


config_module = module('typr_config', 'config.py')
overlay = module('typr_overlay', 'overlay.py')
mark = module('typr_mark', 'mark.py')


class MarkOverlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        files = subprocess.check_output(
            ['git', '-C', str(REPO), 'ls-files', '-z', 'ios/*.swift', 'ios/*.yml', 'ios/*.entitlements',
             'ios/*.plist', 'ios/*.xcstrings', 'ios/*.strings', 'ios/HEXMobile/Assets.xcassets'])
        packed = subprocess.run(['tar', '-C', str(REPO), '--null', '-T', '-', '-cf', '-'],
                                input=files, capture_output=True, check=True).stdout
        subprocess.run(['tar', '-C', str(self.root), '-xf', '-'], input=packed, check=True)
        self.ios = self.root / 'ios'
        self.config = config_module.load()

    def read(self, relative):
        return (self.ios / relative).read_text()

    def test_every_hexagon_mark_draws_the_typr_mark(self):
        overlay.apply(self.root, self.config)
        theme = self.read(mark.THEME)
        self.assertEqual(theme.count('enum TyprMark {'), 1)
        self.assertIn('context.fill(Path(mark.dot), with: .color(coreColor ?? color))', theme)
        self.assertIn('.frame(width: size, height: size)\n        .accessibilityHidden(true)', theme)
        palette = self.read(mark.PALETTE)
        self.assertIn('let mark = TyprMark.paths(in: rect)', palette)
        self.assertNotIn('strokePath', palette)
        self.assertIn('path.addArc(', self.read(mark.ONBOARDING))
        for source in mark.SOURCES:
            for path in (self.ios / source).rglob('*.swift'):
                self.assertIsNone(mark.HEXAGON_CODE.search(path.read_text()), path)

    def test_widgets_compile_the_mark_with_the_view_that_uses_it(self):
        overlay.apply(self.root, self.config)
        project = self.read('project.yml')
        widgets = project[project.index('  HEXWidgets:'):project.index('  HEXMobileTests:')]
        self.assertIn(f'- {mark.THEME}', widgets)

    def test_changed_upstream_mark_fails_loudly(self):
        theme = self.ios / mark.THEME
        theme.write_text(theme.read_text().replace('var coreColor: Color? = nil', 'var coreColor: Color?', 1))
        with self.assertRaisesRegex(ValueError, 'HexTheme.swift: expected 1'):
            overlay.apply(self.root, self.config)

    def test_changed_progress_hexagon_fails_loudly(self):
        pieces = self.ios / mark.ONBOARDING
        pieces.write_text(pieces.read_text().replace('for i in 0...6', 'for i in 0..<7', 1))
        with self.assertRaisesRegex(ValueError, 'OnboardingPieces.swift: expected 1'):
            overlay.apply(self.root, self.config)

    def test_new_upstream_hexagon_fails_loudly(self):
        (self.ios / 'HEXKeyboard/NewMark.swift').write_text(
            'let corner = CGPoint(x: 32, y: 4)\nlet icon = Image(systemName: "hexagon.fill")\n')
        with self.assertRaisesRegex(ValueError, 'Hexagon drawing left'):
            overlay.apply(self.root, self.config)


if __name__ == '__main__':
    unittest.main()
