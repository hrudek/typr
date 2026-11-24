"""Execute the workflow's real Decide shell against committed local Git trees."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_fingerprint
from test_ci_fast_lane import DECIDE, condition


class RoutingTests(unittest.TestCase):
    # Reuse only the temporary Git fixture, not its test methods.
    setUp = test_fingerprint.FingerprintTests.setUp
    git = test_fingerprint.FingerprintTests.git
    change = test_fingerprint.FingerprintTests.change
    commit = test_fingerprint.FingerprintTests.commit
    fingerprint = test_fingerprint.FingerprintTests.fingerprint

    def decide(self, base, event='push', distribution=''):
        script = DECIDE
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'output'
            env = dict(os.environ, EVENT=event, REF='refs/heads/dev', BEFORE=base,
                       AFTER=self.git('rev-parse', 'HEAD'), DISTRIBUTION=distribution, REPO=str(self.root),
                       RUNNER_TEMP=tmp, GITHUB_OUTPUT=str(output),
                       GITHUB_STEP_SUMMARY=str(Path(tmp) / 'summary'))
            result = subprocess.run(['bash', '-c', script], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_routing_matrix(self):
        for path, tests, build in (
            ('ios/HEXMobileTests/Example.swift', True, False),
            ('tests/fixtures/vocabulary/audio/term-hex-1.wav', True, False),
            ('ios/HEXMobile/App.swift', True, True),
            ('ios/project.yml', True, True),
            ('ios/unknown-config.xcconfig', True, True),
            ('.github/typr/app.json', True, True),
            ('README.md', False, False),
            ('ios/docs/keyboard.md', False, False),
            ('src/main.rs', False, False),
            ('android/app/src/Main.kt', False, False),
            ('site/index.html', False, False),
            ('.github/typr/build.sh', False, False),
        ):
            base = self.git('rev-parse', 'HEAD')
            self.change(path, 'routing change')
            self.commit()
            with self.subTest(path=path):
                outputs = self.decide(base)
                self.assertEqual(outputs, {'test': str(tests).lower(),
                                          'build': str(build).lower(),
                                          'sign': 'testflight' if build else ''})
                self.assertEqual(condition('test', changed=outputs['build'],
                                           test_changed=outputs['test']), tests)
                self.assertEqual(condition('build', changed=outputs['build']), build)

    def test_explicit_distributions_ignore_unchanged_baseline(self):
        base = self.git('rev-parse', 'HEAD')
        for distribution, sign in (('simulator', ''), ('testflight', 'testflight'),
                                   ('signed-only', 'signed-only')):
            with self.subTest(distribution=distribution):
                self.assertEqual(self.decide(base, 'workflow_dispatch', distribution),
                                 {'test': 'true', 'build': 'true', 'sign': sign})




class SignedOnlyTests(unittest.TestCase):
    def run_decide(self, ref, distribution):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, EVENT='workflow_dispatch', REF=ref, BEFORE='', AFTER='a' * 40,
                       DISTRIBUTION=distribution, REPO='', RUNNER_TEMP=tmp,
                       GITHUB_OUTPUT=str(Path(tmp) / 'out'), GITHUB_STEP_SUMMARY=str(Path(tmp) / 's'))
            return subprocess.run(['bash', '-c', DECIDE], env=env, capture_output=True, text=True)

    def test_branches_sign_without_upload_but_only_dev_uploads(self):
        self.assertEqual(self.run_decide('refs/heads/feature/x', 'signed-only').returncode, 0)
        self.assertNotEqual(self.run_decide('refs/heads/feature/x', 'testflight').returncode, 0)
        self.assertNotEqual(self.run_decide('refs/heads/dev', 'bogus').returncode, 0)


if __name__ == '__main__':
    unittest.main()
