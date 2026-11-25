import importlib.util
import json
from pathlib import Path
import plistlib
import re
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
rebrand = module('typr_rebrand', 'rebrand.py')
archive = module('typr_archive', 'archive.py')


def literals(source):
    return rebrand.swift_literals(source, lambda s: s)[1]


class BrandTests(unittest.TestCase):
    def test_brand_rewrites_the_name_not_identifiers_or_hexadecimal(self):
        for old, new in (('Open Hex', 'Open Typr'), ("Hex's setup", "Typr's setup"),
                         ('Apps › Hex › Keyboards', 'Apps › Typr › Keyboards'),
                         ('Until then, Hex.', 'Until then, Typr.'),
                         ('用 Hex 听写', '用 Typr 听写'), ('文件：Hex 不', '文件：Typr 不'),
                         ('HexInbox', 'HexInbox'), ('anomaly.hex.words', 'anomaly.hex.words'),
                         ('Hex.swift', 'Hex.swift'), ('hex-dictation', 'hex-dictation'),
                         ('a hex colour like #ff0000', 'a hex colour like #ff0000'),
                         ('Hexagon', 'Hexagon'), ('which Hex on a Mac, a PC', 'which Hex on a Mac, a PC')):
            with self.subTest(old=old):
                self.assertEqual(rebrand.brand(old), new)

    def test_swift_literals_skip_code_comments_and_interpolations(self):
        source = ('// Hex in a comment\n'
                  'let a = Text("Switch to Hex with \\(Image(systemName: "globe")) or \\(Hex.name)")\n'
                  '/* Hex /* nested */ Hex */ let b = "line\\nHex"\n'
                  'let c = #"raw "Hex" \\#(Hex.x)"#\n'
                  'let d = """\n    Hex sums \\\n    the counts\n    """\n')
        result, _ = rebrand.swift_literals(source, rebrand.brand)
        self.assertEqual(result, (
            '// Hex in a comment\n'
            'let a = Text("Switch to Typr with \\(Image(systemName: "globe")) or \\(Hex.name)")\n'
            '/* Hex /* nested */ Hex */ let b = "line\\nTypr"\n'
            'let c = #"raw "Typr" \\#(Hex.x)"#\n'
            'let d = """\n    Typr sums \\\n    the counts\n    """\n'))


class RebrandOverlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        files = subprocess.check_output(
            ['git', '-C', str(REPO), 'ls-files', '-z', 'ios/*.swift', 'ios/*.yml', 'ios/*.entitlements',
             'ios/*.plist', 'ios/*.xcstrings', 'ios/*.strings'])
        packed = subprocess.run(['tar', '-C', str(REPO), '--null', '-T', '-', '-cf', '-'],
                                input=files, capture_output=True, check=True).stdout
        subprocess.run(['tar', '-C', str(self.root), '-xf', '-'], input=packed, check=True)
        self.ios = self.root / 'ios'
        self.config = config_module.load()

    def catalog(self, name='HEXMobile/Localizable.xcstrings'):
        return json.loads((self.ios / name).read_text())['strings']

    def edit(self, name, change):
        path = self.ios / name
        path.write_text(change(path.read_text()))

    def test_no_user_visible_hex_is_left(self):
        overlay.apply(self.root, self.config)
        self.assertEqual(rebrand.find_leftovers(self.ios), [])

    def test_lookup_keys_and_swift_literals_stay_in_step(self):
        keys = set(self.catalog())
        before = {text for path in self.ios.rglob('*.swift') for text in literals(path.read_text())
                  if text in keys and 'Hex' in text}
        self.assertGreater(len(before), 50)
        overlay.apply(self.root, self.config)
        keys = self.catalog()
        after = {text for path in self.ios.rglob('*.swift') for text in literals(path.read_text())}
        for text in before:
            with self.subTest(literal=text):
                self.assertIn(rebrand.brand(text), keys)
                self.assertIn(rebrand.brand(text), after)

    def test_shipped_strings_read_typr(self):
        overlay.apply(self.root, self.config)
        strings = self.catalog()
        self.assertEqual(strings['Typr key']['localizations']['zh-Hans']['stringUnit']['value'], 'Typr 键')
        self.assertIn('Typr', strings['Open Typr']['localizations']['zh-Hans']['stringUnit']['value'])
        self.assertIn('Dictate with Typr', self.catalog('HEXWidgets/Localizable.xcstrings'))
        project = (self.ios / 'project.yml').read_text()
        self.assertIn('NSMicrophoneUsageDescription: Typr turns what you say', project)
        self.assertIn('CFBundleTypeName: Typr words file', project)
        self.assertIn('"Typr words file" = "Typr 词语文件";',
                      (self.ios / rebrand.INFO_PLIST_STRINGS).read_text())
        self.assertIn('static let title: LocalizedStringResource = "Dictate with Typr"',
                      (self.ios / 'HEXMobile/HexIntents.swift').read_text())
        tests = (self.ios / 'HEXMobileTests/CustomVocabularyTests.swift').read_text()
        self.assertIn('VocabularySpelling.apply(["Hex"], to: "hex")', tests)

    def test_allowlisted_strings_keep_hex(self):
        overlay.apply(self.root, self.config)
        kept = [key for key in self.catalog() if 'Hex on a Mac' in key]
        self.assertEqual(len(kept), 1)
        self.assertIn('hex-words.hexwords', kept[0])
        self.assertIn('Hex', self.catalog()[kept[0]]['localizations']['zh-Hans']['stringUnit']['value'])
        project = (self.ios / 'project.yml').read_text()
        self.assertIn('- hex-dictation', project)
        self.assertIn('- anomaly.hex.words', project)

    def test_new_upstream_sentence_is_rebranded(self):
        self.edit('HEXMobile/ContentView.swift', lambda t: t + '\nlet newCopy = Text("Hex learned a new trick")\n')
        overlay.apply(self.root, self.config)
        self.assertIn('Text("Typr learned a new trick")', (self.ios / 'HEXMobile/ContentView.swift').read_text())

    def test_new_hex_the_rewrite_cannot_place_fails_loudly(self):
        for name, change in (
            ('HEXMobile/ContentView.swift', lambda t: t + '\nlet newCopy = Text("Turn on HexBoost here")\n'),
            ('HEXWidgets/Localizable.xcstrings', lambda t: t.replace('"strings" : {', '"strings" : {\n    "HexBoost" : {},', 1)),
            ('HEXMobile/Info.plist', lambda t: t.replace('<string>$(DEVELOPMENT_LANGUAGE)</string>',
                                                          '<string>HexBoost</string>', 1)),
        ):
            with self.subTest(name=name):
                self.setUp()
                self.edit(name, change)
                with self.assertRaisesRegex(ValueError, 'User-visible Hex left'):
                    overlay.apply(self.root, self.config)

    def test_new_identifier_literal_passes(self):
        self.edit('HEXMobile/ContentView.swift', lambda t: t + '\nlet cache = "HexBoostCache"\n')
        overlay.apply(self.root, self.config)

    def test_keyboard_is_named_like_the_app_and_the_text_says_so(self):
        overlay.apply(self.root, self.config)
        project = (self.ios / 'project.yml').read_text()
        self.assertEqual(re.findall(r'^\s+CFBundleDisplayName: (.+)$', project, re.MULTILINE), ['Typr'] * 3)
        onboarding = (self.ios / 'HEXMobile/Onboarding.swift').read_text()
        self.assertIn('Keyboards  ›  Typr  ›  Allow Full Access', onboarding)
        self.assertIn('title: "Typr",', onboarding)
        self.assertIn('title: "Typr",', (self.ios / 'HEXMobile/KeyboardSetup.swift').read_text())
        self.assertNotIn('Typr Keyboard', onboarding)
        catalog = self.catalog()
        self.assertIn('Keyboards  ›  Typr  ›  Allow Full Access', catalog)
        self.assertIn('Typr', catalog['Keyboards  ›  Typr  ›  Allow Full Access']['localizations']['zh-Hans']['stringUnit']['value'])
        self.assertIn('Warm Typr Keyboard', catalog)
        self.assertEqual(rebrand.brand('Open Hex Keyboard'), 'Open Typr')

    def test_archive_expects_the_app_name_for_every_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Products/Applications/Typr.app'
            for path, identifier, name in ((app, 'dev.rudek.typr', 'Typr'),
                                           (app / 'PlugIns/K.appex', 'dev.rudek.typr.keyboard', 'Typr')):
                path.mkdir(parents=True)
                (path / 'Info.plist').write_bytes(plistlib.dumps(
                    {'CFBundleIdentifier': identifier, 'CFBundleDisplayName': name}))
            ids = ['dev.rudek.typr', 'dev.rudek.typr.keyboard']
            archive.validate(tmp, ids, 'Typr')
            with self.assertRaisesRegex(ValueError, 'Unexpected display name'):
                archive.validate(tmp, ids, 'Other')
            (app / 'PlugIns/K.appex/Info.plist').write_bytes(plistlib.dumps(
                {'CFBundleIdentifier': 'dev.rudek.typr.keyboard', 'CFBundleDisplayName': 'Typr Keyboard'}))
            with self.assertRaisesRegex(ValueError, 'Unexpected display name'):
                archive.validate(tmp, ids, 'Typr')

    def test_fails_loudly_when_upstream_moves(self):
        for name, old, new in (
            ('HEXMobile/Localizable.xcstrings', '"Open Hex" :', '"Open the app" :'),
            ('project.yml', 'UTTypeDescription: Hex words file', 'UTTypeDescription: Words file'),
            (rebrand.INFO_PLIST_STRINGS, '"Hex words file" =', '"Words file" ='),
        ):
            with self.subTest(old=old):
                self.setUp()
                self.edit(name, lambda t: t.replace(old, new))
                with self.assertRaises(ValueError):
                    overlay.apply(self.root, self.config)


if __name__ == '__main__':
    unittest.main()
