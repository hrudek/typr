"""Offline checks that all Typr surfaces share the source logo."""
import importlib.util
import json
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[3]
BRANDING = ROOT / 'ios/Branding'
spec = importlib.util.spec_from_file_location('branding', BRANDING / 'generate.py')
branding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(branding)


class BrandingTests(unittest.TestCase):
    def test_vector_matches_outlined_source_and_is_linked_to_all_products(self):
        self.assertEqual((BRANDING / 'TyprWordmark.swift').read_text(), branding.swift_source())
        root, path, commands, bounds = branding.geometry()
        self.assertEqual(root.find('{http://www.w3.org/2000/svg}rect').get('fill'), '#040000')
        self.assertEqual(path.get('fill'), 'white')
        self.assertGreater(len(commands), 50)
        self.assertAlmostEqual((bounds[2] - bounds[0]) / (bounds[3] - bounds[1]), 2.373, places=3)
        project = (ROOT / 'ios/project.yml').read_text()
        self.assertEqual(project.count('- Branding/TyprWordmark.swift'), 3)
        self.assertIn('- path: AppIcon.icon', project)
        self.assertIn('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon', project)

    def test_icon_has_a_high_resolution_alpha_layer_and_solid_background(self):
        icon = ROOT / 'ios/AppIcon.icon'
        data = (icon / 'Assets/Image.png').read_bytes()
        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        width, height, depth, color_type = struct.unpack('>IIBB', data[16:26])
        self.assertEqual((width, height, depth, color_type), (2048, 2048, 8, 6))
        config = json.loads((icon / 'icon.json').read_text())
        self.assertEqual(config['fill'], {'solid': 'srgb:0.015686,0.000000,0.000000,1.000000'})
        group = config['groups'][0]
        self.assertEqual(group['shadow']['opacity'], 0)
        self.assertFalse(group['translucency']['enabled'])
        self.assertEqual(group['layers'][0]['position']['scale'], 0.5)
        # The optical offset is baked into the PNG by generate.py; a second
        # translation here would apply it twice.
        self.assertEqual(group['layers'][0]['position']['translation-in-points'], [0, 0])

    def test_optical_offset_shifts_right_and_down_by_a_small_amount(self):
        dx, dy = branding.OPTICAL_OFFSET
        _, _, _, (x0, y0, x1, y1) = branding.geometry()
        self.assertTrue(0 < dx / (x1 - x0) < 0.05 and 0 < dy / (y1 - y0) < 0.05)


if __name__ == '__main__':
    unittest.main()
