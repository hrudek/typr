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
            ('ios/TyprTests/Example.swift', True, False),
            ('ios/TestFixtures/sample.wav', True, False),
            ('ios/Typr/App.swift', True, True),
            ('ios/project.yml', True, True),
            ('ios/unknown-config.xcconfig', True, True),
            ('.github/typr/app.json', True, True),
            ('README.md', False, False),
            ('ios/Typr/README.md', False, False),
            ('ios/tools/offline.py', False, False),
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
        for distribution, sign in (('simulator', ''), ('testflight', 'testflight')):
            with self.subTest(distribution=distribution):
                self.assertEqual(self.decide(base, 'workflow_dispatch', distribution),
                                 {'test': 'true', 'build': 'true', 'sign': sign})


if __name__ == '__main__':
    unittest.main()
