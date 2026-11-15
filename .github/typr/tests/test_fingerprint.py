"""Real Git-tree comparisons: infrastructure/docs never request an app build."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'fingerprint.sh'


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.change('ios/Typr/App.swift', 'app')
        self.change('.github/typr/app.json', 'identity')
        self.commit()
        self.base = self.fingerprint()

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

    def test_pipeline_documentation_and_offline_tools_do_not_build(self):
        pipeline_before = self.fingerprint('pipeline')
        for path in ('.github/workflows/typr-ci.yml', '.github/typr/build.sh',
                     '.github/typr/auto-merge.py', '.github/typr/tests/test_ci.py',
                     'README.md', 'AGENTS.md', 'ios/TyprShared/WordData/README.md',
                     'ios/tools/dictation_log/cli.py'):
            self.change(path, 'changed')
            self.commit()
            with self.subTest(path=path):
                self.assertEqual(self.base, self.fingerprint())
        self.assertNotEqual(pipeline_before, self.fingerprint('pipeline'))

    def test_source_project_resources_tests_and_identity_do_build(self):
        for path in ('ios/Typr/App.swift', 'ios/project.yml', 'ios/Typr/Info.plist',
                     'ios/TyprKeyboard/Keyboard.swift', 'ios/TyprWidgets/Widget.swift',
                     'ios/TyprShared/WordData/words.bin', '.github/typr/app.json'):
            before = self.fingerprint()
            self.change(path, 'new content')
            self.commit()
            with self.subTest(path=path):
                self.assertNotEqual(before, self.fingerprint())

    def test_tests_and_fixtures_only_change_simulator_and_pipeline(self):
        for path in ('ios/TyprTests/Test.swift', 'ios/TestFixtures/audio.wav'):
            for operation in ('add', 'edit', 'rename', 'delete'):
                before = {mode: self.fingerprint(mode) for mode in ('app', 'test', 'pipeline')}
                if operation in ('add', 'edit'):
                    self.change(path, operation)
                elif operation == 'rename':
                    self.git('mv', path, path + '.renamed')
                else:
                    self.git('rm', path + '.renamed')
                self.commit()
                with self.subTest(path=path, operation=operation):
                    self.assertEqual(before['app'], self.fingerprint('app'))
                    for mode in ('test', 'pipeline'):
                        self.assertNotEqual(before[mode], self.fingerprint(mode))

    def test_deletion_and_rename_change_fingerprint(self):
        self.git('mv', 'ios/Typr/App.swift', 'ios/Typr/Renamed.swift')
        self.commit()
        renamed = self.fingerprint()
        self.assertNotEqual(self.base, renamed)
        self.git('rm', 'ios/Typr/Renamed.swift')
        self.commit()
        self.assertNotEqual(renamed, self.fingerprint())


if __name__ == '__main__':
    unittest.main()
