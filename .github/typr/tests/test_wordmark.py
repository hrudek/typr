import importlib.util
import json
from pathlib import Path
import struct
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
wordmark = module('typr_wordmark', 'wordmark.py')


def png_size(path):
    header = path.read_bytes()[:24]
    assert header[:8] == b'\x89PNG\r\n\x1a\n', path
    return struct.unpack('>II', header[16:24])


class WordmarkAssetTests(unittest.TestCase):
    def test_imageset_is_a_template_with_matching_2x_and_3x_pngs(self):
        contents = json.loads((wordmark.IMAGESET / 'Contents.json').read_text())
        self.assertEqual(contents['properties']['template-rendering-intent'], 'template')
        points = set()
        for image in contents['images']:
            scale = int(image['scale'].rstrip('x'))
            width, height = png_size(wordmark.IMAGESET / image['filename'])
            points.add((round(width / scale), round(height / scale)))
        self.assertEqual(sorted(i['scale'] for i in contents['images']), ['2x', '3x'])
        self.assertEqual(len(points), 1, points)


class WordmarkOverlayTests(unittest.TestCase):
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
        self.view = self.ios / wordmark.VIEW
        self.config = config_module.load()

    def test_headers_show_the_wordmark_and_running_text_keeps_the_name(self):
        overlay.apply(self.root, self.config)
        view = self.view.read_text()
        self.assertEqual(view.count('Image("TyprWordmark")\n'), wordmark.HEADERS)
        self.assertEqual(view.count('.accessibilityLabel("Typr")'), wordmark.HEADERS)
        self.assertNotIn('Text("Typr")', view)
        self.assertIn('.navigationTitle("Typr")', view)
        self.assertIn('Text("Typr")', (self.ios / 'HEXWidgets/HexDictationControl.swift').read_text())
        self.assertIn('OnboardingTitle("Setting up Typr")', (self.ios / 'HEXMobile/Onboarding.swift').read_text())
        imageset = self.ios / wordmark.CATALOG / 'TyprWordmark.imageset'
        self.assertEqual(sorted(p.name for p in imageset.iterdir()),
                         sorted(p.name for p in wordmark.IMAGESET.iterdir()))

    def test_changed_upstream_header_fails_loudly(self):
        text = self.view.read_text()
        self.view.write_text(text.replace('.tracking(-0.2)', '.tracking(-0.3)', 1))
        with self.assertRaisesRegex(ValueError, 'expected 2 header name'):
            overlay.apply(self.root, self.config)


if __name__ == '__main__':
    unittest.main()
