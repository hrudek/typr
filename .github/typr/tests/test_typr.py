"""Linux-runnable checks for Typr's CI scripts: python3 -m unittest discover -s .github/typr/tests"""
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
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
identity = module('typr_identity', 'identity.py')
signing = module('typr_signing', 'signing-entitlements.py')


class ConfigTests(unittest.TestCase):
    def test_apple_configuration_matches_committed_identity(self):
        config = config_module.load()
        asc = json.loads((REPO / 'ios/appstoreconnect.json').read_text())
        self.assertEqual(asc['bundleId'], config['bundle_id'])
        self.assertEqual(asc['teamId'], identity.TEAM_ID)
        self.assertEqual(asc['project'], config['project'])
        self.assertEqual(asc['scheme'], config['scheme'])
        self.assertEqual(asc['name'], 'Typr Keyboard')
        self.assertEqual(asc['appId'], '6832515139')
        self.assertEqual(asc['internalGroup'], 'Typr Internal')
        export = plistlib.loads((REPO / 'ios/ExportOptions.plist').read_bytes())
        self.assertEqual(export['teamID'], identity.TEAM_ID)

    def test_entitlements_per_target(self):
        config = config_module.load()
        group = {'com.apple.security.application-groups': ['group.dev.rudek.typr']}
        inference = 'com.apple.developer.background-tasks.continued-processing.inference'
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr'), {**group, inference: True})
        committed = plistlib.loads((REPO / 'ios/Typr/Typr.entitlements').read_bytes())
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr'), committed)
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr.keyboard'), group)
        self.assertEqual(signing.required_entitlements(config, 'dev.rudek.typr.widgets'), {})
        with self.assertRaises(ValueError):
            signing.required_entitlements(config, 'com.unreviewed.app')

    def test_background_inference_cannot_be_stripped_from_app_signature(self):
        config = config_module.load()
        required = signing.required_entitlements(config, 'dev.rudek.typr')
        actual = {**required, 'application-identifier': identity.TEAM_ID + '.dev.rudek.typr',
                  'com.apple.developer.team-identifier': identity.TEAM_ID, 'get-task-allow': False}
        signing.validate_entitlements(actual, required, 'dev.rudek.typr', identity.TEAM_ID)
        for value in (None, False):
            with self.subTest(value=value):
                changed = dict(actual)
                key = 'com.apple.developer.background-tasks.continued-processing.inference'
                if value is None:
                    changed.pop(key)
                else:
                    changed[key] = value
                with self.assertRaisesRegex(ValueError, 'Missing or unexpected signed entitlement'):
                    signing.validate_entitlements(changed, required, 'dev.rudek.typr', identity.TEAM_ID)


class IdentityTests(unittest.TestCase):
    """Validate the real committed ios/ tree without mutating it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ios = Path(self.tmp.name) / 'ios'
        shutil.copytree(REPO / 'ios', self.ios)
        self.config = config_module.load()

    def tearDown(self):
        self.tmp.cleanup()

    def test_validates_real_checkout_without_changes(self):
        before = {p.relative_to(self.ios): p.read_bytes()
                  for p in self.ios.rglob('*') if p.is_file()}
        identity.validate(self.ios, self.config, identity.TEAM_ID)
        after = {p.relative_to(self.ios): p.read_bytes()
                 for p in self.ios.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_fails_closed_when_committed_identity_changes(self):
        for marker in ('2ZNGF24932', 'dev.rudek.typr.keyboard',
                       'CFBundleDisplayName: Typr', '- typr'):
            with self.subTest(marker=marker):
                project = self.ios / 'project.yml'
                original = project.read_text()
                project.write_text(original.replace(marker, 'invalid'))
                with self.assertRaises(ValueError):
                    identity.validate(self.ios, self.config, identity.TEAM_ID)
                project.write_text(original)

    def test_rejects_invalid_or_different_team(self):
        for team in ('bad\\nTEAM', 'TEAM123456'):
            with self.subTest(team=team), self.assertRaises(ValueError):
                identity.validate(self.ios, self.config, team)

    def test_rejects_drift_in_build_config(self):
        for key, value in (('bundle_id', 'dev.other.app'), ('url_scheme', 'other'),
                           ('display_name', 'Other'), ('scheme', 'Other'),
                           ('project', 'Other.xcodeproj')):
            with self.subTest(key=key), self.assertRaises(ValueError):
                identity.validate(self.ios, {**self.config, key: value}, identity.TEAM_ID)

    def test_rejects_plist_or_entitlement_drift(self):
        project = (self.ios / 'project.yml').read_text()
        paths = re.findall(r'^\s+(?:path|CODE_SIGN_ENTITLEMENTS): (.+(?:Info.plist|entitlements))$',
                           project, re.MULTILINE)
        self.assertTrue(paths)
        for raw in paths:
            path = self.ios / raw
            original = path.read_bytes()
            value = plistlib.loads(original)
            key = ('com.apple.security.application-groups' if path.suffix == '.entitlements'
                   else 'CFBundleDisplayName')
            value[key] = ['group.invalid'] if path.suffix == '.entitlements' else 'Other'
            path.write_bytes(plistlib.dumps(value))
            with self.subTest(path=raw), self.assertRaises(ValueError):
                identity.validate(self.ios, self.config, identity.TEAM_ID)
            path.write_bytes(original)

class ScopeTests(unittest.TestCase):
    """Every .github/ change needs infra; every new Markdown file needs docs."""

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
        for path in ('ios/TyprShared/A.swift', 'ios/notes.txt', 'src/main.rs'):
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
        for path in ('.github/typr/x.sh', '.github/workflows/x.yml',
                     '.github/ISSUE_TEMPLATE/x.yml', '.github/other.txt'):
            with self.subTest(path=path):
                self.assertEqual(self.run_scope([path]), 1)
                self.assertEqual(self.run_scope([path], 'feature,infra'), 0)

    def test_no_changes_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(['git', 'init', '-q', tmp], check=True)
            subprocess.run(['git', '-C', tmp, '-c', 'user.name=t', '-c', 'user.email=t@t',
                            'commit', '-q', '--allow-empty', '-m', 'base'], check=True)
            result = subprocess.run(['bash', str(HERE / 'scope.sh'), 'HEAD', 'HEAD'], cwd=tmp,
                                    capture_output=True, text=True, check=True)
            self.assertIn('Scope OK (0 files)', result.stdout)


class ProjectPathsTests(unittest.TestCase):
    def test_project_paths_are_self_contained_and_exist(self):
        # Parse path keys anywhere, plus bare list entries in each sources block.
        # Keep this Linux check independent of PyYAML / XcodeGen.
        ios = REPO / 'ios'
        paths = []
        sources_indent = None
        for line in (ios / 'project.yml').read_text().splitlines():
            indent = len(line) - len(line.lstrip())
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if sources_indent is not None and indent <= sources_indent:
                sources_indent = None
            if stripped == 'sources:':
                sources_indent = indent
            match = re.match(r'(?:-\s+)?path:\s*(.+)$', stripped)
            if match:
                paths.append(match.group(1))
            elif sources_indent is not None:
                match = re.match(r'-\s+([^:]+)$', stripped)
                if match:
                    paths.append(match.group(1))
        self.assertGreater(len(paths), 0)
        self.assertIn('AppIcon.icon', paths)
        self.assertIn('TestFixtures/term-hex-1.wav', paths)
        for raw in paths:
            value = raw.strip('"\'')
            with self.subTest(path=value):
                self.assertNotIn('..', value)
                self.assertFalse(Path(value).is_absolute())
                self.assertTrue((ios / value).exists(), value)


class InfraLabelTests(unittest.TestCase):
    """Adding "infra" must approve without a manual close/reopen or a label-triggered macOS run."""
    WORKFLOWS = HERE.parent / 'workflows'

    def test_scope_reads_live_labels_not_the_event_payload(self):
        ci = (self.WORKFLOWS / 'typr-checks.yml').read_text()
        self.assertNotIn('github.event.pull_request.labels', ci)
        self.assertIn('gh api "repos/$GH_REPO/pulls/$PR"', ci)
        self.assertIn('pull-requests: read', ci)
        self.assertIn('types: [opened, synchronize, reopened, ready_for_review]', ci)


if __name__ == '__main__':
    unittest.main()
