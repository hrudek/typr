from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'fingerprint.sh'
REPO = SCRIPT.parents[2]

NO_BUILD = ('src/main.rs', 'Cargo.toml', 'Cargo.lock', 'android/app/build.gradle', 'site/index.html',
            'app/AppIcon.icon/icon.json', 'app/Info.plist', 'docs/cli.md', 'README.md', 'AGENTS.md',
            '.github/workflows/typr-ci.yml', '.github/workflows/release.yml', '.github/typr/build.sh',
            '.github/typr/sign.sh', '.github/typr/tests/test_x.py', '.github/typr/README.md',
            'ios/README.md', 'ios/docs/keyboard.md', 'ios/benchmark/typing-replay/run.py',
            'ios/ci_scripts/ci_post_clone.sh', 'ios/scripts/build-typing-model.py',
            'ios/appstoreconnect.json', 'ios/ExportOptions.plist',
            'tests/fixtures/meetings/a.json')
BUILD = ('ios/HEXMobile/App.swift', 'ios/project.yml', 'ios/Package.resolved',
         'ios/HEXKeyboard/Info.plist', 'ios/HEXShared/Words.bin', 'ios/HEXWidgets/W.swift',
         'ios/HEXActivity/A.swift', 'ios/HEXMobile/Typr/TyprSettings.swift',
         'ios/scripts/fetch-cleanup-model.sh', 'ios/unknown.xcconfig',
         '.github/typr/app.json', '.github/typr/overlay.py', '.github/typr/prepare.sh',
         '.github/typr/AppIcon.icon/icon.json')
TEST_ONLY = ('ios/HEXMobileTests/T.swift', 'tests/fixtures/vocabulary/audio/term-hex-1.wav',
             'tests/fixtures/hex-words/a.hexwords')


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.change('ios/HEXMobile/App.swift', 'app')
        self.change('.github/typr/app.json', 'identity')
        self.commit()
        self.base = self.fingerprint()
        self.base_test = self.fingerprint('test')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def change(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'change')

    def fingerprint(self, mode='app'):
        return subprocess.check_output(['bash', str(SCRIPT), str(self.root), 'HEAD', mode], text=True)

    def test_upstream_docs_and_pipeline_changes_do_not_build(self):
        for path in NO_BUILD:
            self.change(path, 'changed')
            self.commit()
            with self.subTest(path=path):
                self.assertEqual(self.base, self.fingerprint())
                self.assertEqual(self.base_test, self.fingerprint('test'))

    def test_ios_sources_project_and_overlay_do_build(self):
        for path in BUILD:
            before = self.fingerprint(), self.fingerprint('test')
            self.change(path, 'new content')
            self.commit()
            with self.subTest(path=path):
                self.assertNotEqual(before[0], self.fingerprint())
                self.assertNotEqual(before[1], self.fingerprint('test'))

    def test_tests_and_fixtures_only_change_simulator(self):
        for path in TEST_ONLY:
            for operation in ('add', 'edit', 'rename', 'delete'):
                before = {mode: self.fingerprint(mode) for mode in ('app', 'test')}
                if operation in ('add', 'edit'):
                    self.change(path, operation)
                elif operation == 'rename':
                    self.git('mv', path, path + '.renamed')
                else:
                    self.git('rm', '-q', path + '.renamed')
                self.commit()
                with self.subTest(path=path, operation=operation):
                    self.assertEqual(before['app'], self.fingerprint('app'))
                    self.assertNotEqual(before['test'], self.fingerprint('test'))

    def test_deletion_and_rename_change_fingerprint(self):
        self.git('mv', 'ios/HEXMobile/App.swift', 'ios/HEXMobile/Renamed.swift')
        self.commit()
        renamed = self.fingerprint()
        self.assertNotEqual(self.base, renamed)
        self.git('rm', '-q', 'ios/HEXMobile/Renamed.swift')
        self.commit()
        self.assertNotEqual(renamed, self.fingerprint())


class ProjectReferencesTests(unittest.TestCase):
    def test_every_file_project_yml_reads_outside_ios_is_an_input(self):
        project = (REPO / 'ios/project.yml').read_text()
        outside = re.findall(r'^\s+(?:- )?(?:path: )?\.\./(\S+)$', project, re.MULTILINE)
        self.assertIn('app/AppIcon.icon', outside)
        listed = re.search(r'^test_only=\((.*)\)$', SCRIPT.read_text(), re.MULTILINE).group(1).split()
        for path in outside:
            with self.subTest(path=path):
                if path == 'app/AppIcon.icon':
                    self.assertIn('UPSTREAM_ICON = \'../app/AppIcon.icon\'',
                                  (SCRIPT.parent / 'overlay.py').read_text())
                else:
                    self.assertTrue(any(path.startswith(p + '/') or path == p for p in listed), path)


class SparseCheckoutTests(unittest.TestCase):
    def test_build_jobs_check_out_every_fingerprint_input_outside_github(self):
        listed = re.search(r'^test_only=\((.*)\)$', SCRIPT.read_text(), re.MULTILINE).group(1).split()
        for name in ('typr-simulator.yml', 'typr-ci.yml'):
            text = (REPO / '.github/workflows' / name).read_text()
            block = re.search(r'sparse-checkout: \|\n((?:\s+\S+\n)+)', text).group(1).split()
            for path in ['ios'] + listed:
                with self.subTest(workflow=name, path=path):
                    self.assertTrue(any(path == c or path.startswith(c + '/') for c in block), path)


if __name__ == '__main__':
    unittest.main()
