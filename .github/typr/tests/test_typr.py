import importlib.util
from pathlib import Path
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
signing = module('typr_signing', 'signing-entitlements.py')
TEAM = '2ZNGF24932'


class ConfigTests(unittest.TestCase):
    def test_typr_identity(self):
        config = config_module.load()
        self.assertEqual(config['bundle_ids'], ['dev.rudek.typr', 'dev.rudek.typr.keyboard',
                                                'dev.rudek.typr.widgets'])
        self.assertEqual((config['team_id'], config['app_group'], config['display_name']),
                         (TEAM, 'group.dev.rudek.typr', 'Typr'))
        self.assertEqual((config['asc_app_id'], config['asc_app_name'], config['testflight_group']),
                         ('6832515139', 'Typr Keyboard', 'Typr Internal'))
        self.assertGreater(1 + config['build_number_offset'], 519)
        self.assertTrue((HERE / 'AppIcon.icon/icon.json').is_file())

    def test_entitlements_per_target(self):
        config = config_module.load()
        group = {'com.apple.security.application-groups': ['group.dev.rudek.typr']}
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr'), group)
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr.keyboard'), group)
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr.widgets'), {})
        with self.assertRaises(ValueError):
            signing.required_entitlements(config, 'com.unreviewed.app')

    def test_signed_app_group_cannot_go_missing(self):
        config = config_module.load()
        required = signing.required_entitlements(config, 'dev.rudek.typr')
        actual = {**required, 'application-identifier': TEAM + '.dev.rudek.typr',
                  'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False}
        signing.validate_entitlements(actual, required, 'dev.rudek.typr', TEAM)
        del actual['com.apple.security.application-groups']
        with self.assertRaisesRegex(ValueError, 'Missing or unexpected signed entitlement'):
            signing.validate_entitlements(actual, required, 'dev.rudek.typr', TEAM)


class OverlayTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        files = subprocess.check_output(
            ['git', '-C', str(REPO), 'ls-files', '-z', 'ios/*.swift', 'ios/*.yml',
             'ios/*.entitlements', 'ios/*.plist'])
        packed = subprocess.run(['tar', '-C', str(REPO), '--null', '-T', '-', '-cf', '-'],
                                input=files, capture_output=True, check=True).stdout
        subprocess.run(['tar', '-C', str(self.root), '-xf', '-'], input=packed, check=True)
        self.ios = self.root / 'ios'
        self.config = config_module.load()

    def test_upstream_becomes_typr(self):
        overlay.apply(self.root, self.config)
        project = (self.ios / 'project.yml').read_text()
        self.assertEqual(sorted(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER: (\S+)', project)),
                         ['dev.rudek.typr', 'dev.rudek.typr.keyboard', 'dev.rudek.typr.tests',
                          'dev.rudek.typr.widgets'])
        self.assertEqual(re.findall(r'CFBundleDisplayName: (.+)', project), ['Typr'] * 3)
        self.assertIn('DEVELOPMENT_TEAM: 2ZNGF24932', project)
        self.assertIn('- path: ../.github/typr/AppIcon.icon', project)
        self.assertIn('- hex-dictation', project)
        bridge = (self.ios / 'HEXShared/KeyboardBridge.swift').read_text()
        self.assertIn('static let appGroup = "group.dev.rudek.typr"', bridge)
        setup = (self.ios / 'HEXMobile/KeyboardSetup.swift').read_text()
        self.assertIn('static let keyboardBundleID = "dev.rudek.typr.keyboard"', setup)
        for name in ('HEXMobile/HEXMobile.entitlements', 'HEXKeyboard/HEXKeyboard.entitlements'):
            self.assertIn('<string>group.dev.rudek.typr</string>', (self.ios / name).read_text())
        self.assertEqual((self.ios / 'HEXMobile/Feedback.local.xcconfig').read_text(),
                         'BELLHOP_REPORT_KEY =\n')

    def test_fails_closed_when_upstream_moves(self):
        for path, old, new in (
            ('project.yml', 'DEVELOPMENT_TEAM: 5NZ4Q7NXJ4', 'DEVELOPMENT_TEAM: OTHERTEAM1'),
            ('project.yml', 'PRODUCT_BUNDLE_IDENTIFIER: anomaly.hex.mobile.widgets',
             'PRODUCT_BUNDLE_IDENTIFIER: anomaly.hex.mobile.widget'),
            ('project.yml', '../app/AppIcon.icon', '../app/Icon.icon'),
            ('HEXShared/KeyboardBridge.swift', '"group.anomaly.hex.mobile"', 'Group.id'),
            ('HEXMobile/KeyboardSetup.swift', '"anomaly.hex.mobile.keyboard"', 'Keyboard.id'),
        ):
            with self.subTest(old=old):
                self.setUp()
                target = self.ios / path
                text = target.read_text()
                self.assertIn(old, text)
                target.write_text(text.replace(old, new))
                with self.assertRaises(ValueError):
                    overlay.apply(self.root, self.config)

    def test_new_app_group_literal_is_caught(self):
        (self.ios / 'HEXShared/New.swift').write_text('let g = "x"; let h = "group.anomaly.hex.mobile.v2"\n')
        with self.assertRaisesRegex(ValueError, 'App Group left'):
            overlay.apply(self.root, self.config)


class ScopeTests(unittest.TestCase):

    def run_scope(self, files, labels='', existing=()):
        with tempfile.TemporaryDirectory() as tmp:
            git = ['git', '-C', tmp, '-c', 'user.name=t', '-c', 'user.email=t@t']
            subprocess.run(git[:3] + ['init', '-q'], check=True)
            for name in existing:
                Path(tmp, name).parent.mkdir(parents=True, exist_ok=True)
                Path(tmp, name).write_text('old')
            subprocess.run(git + ['add', '-A'], check=True)
            subprocess.run(git + ['commit', '-q', '--allow-empty', '-m', 'base'], check=True)
            for name in files:
                path = Path(tmp, name)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('x')
            subprocess.run(git + ['add', '-A'], check=True)
            subprocess.run(git + ['commit', '-q', '-m', 'change'], check=True)
            return subprocess.run(['bash', str(HERE / 'scope.sh'), 'HEAD~1', 'HEAD'], cwd=tmp,
                                  env={'PATH': '/usr/bin:/bin', 'LABELS': labels},
                                  capture_output=True, text=True).returncode

    def test_non_automation_paths_pass(self):
        for path in ('ios/HEXShared/A.swift', 'ios/notes.txt', 'src/main.rs'):
            with self.subTest(path=path):
                self.assertEqual(self.run_scope([path]), 0)

    def test_new_markdown_needs_docs_label(self):
        for path in ('TASKS.md', 'reports/task.md', 'ios/Feature.md'):
            with self.subTest(path=path):
                self.assertEqual(self.run_scope([path]), 1)
                self.assertEqual(self.run_scope([path], 'feature,docs'), 0)

    def test_editing_existing_markdown_passes(self):
        self.assertEqual(self.run_scope(['README.md'], existing=['README.md']), 0)

    def test_all_automation_needs_infra_label(self):
        for path in ('.github/typr/x.sh', '.github/workflows/x.yml', '.github/other.txt'):
            with self.subTest(path=path):
                self.assertEqual(self.run_scope([path]), 1)
                self.assertEqual(self.run_scope([path], 'feature,infra'), 0)

    def test_scope_reads_live_labels_not_the_event_payload(self):
        ci = (REPO / '.github/workflows/typr-checks.yml').read_text()
        self.assertNotIn('github.event.pull_request.labels', ci)
        self.assertIn('gh api "repos/$GH_REPO/pulls/$PR"', ci)


if __name__ == '__main__':
    unittest.main()
