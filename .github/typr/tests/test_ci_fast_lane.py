"""Scheduling contracts: parallel latest-dev work, protected signing."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
SOURCE = (ROOT / '.github/workflows/typr-ci.yml').read_text()
SIMULATOR = (ROOT / '.github/workflows/typr-simulator.yml').read_text()
CHECKS = (ROOT / '.github/workflows/typr-checks.yml').read_text()
DECIDE = (ROOT / '.github/typr/decide-lanes.sh').read_text()


def job(name):
    source = SIMULATOR if name == 'test' else SOURCE
    return re.split(r'\n  \S', source.split(f'\n  {name}:\n', 1)[1], maxsplit=1)[0]


def condition(name, event, changed='true', only_testing='', test_changed=None):
    # Evaluate the actual single-line scheduling expression, not a copied policy.
    expression = re.search(r'^    if: (.+)$', job(name), re.M).group(1)
    values = {
        'github.event_name': event,
        'needs.decide.outputs.build': changed,
        'needs.decide.outputs.test': changed if test_changed is None else test_changed,
        'inputs.only_testing': only_testing,
    }
    for key, value in values.items():
        expression = expression.replace(key, repr(value))
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression)
    return eval(expression.strip(), {'__builtins__': {}}, {})


class FastLaneContracts(unittest.TestCase):
    def test_three_distinct_workflow_results(self):
        for source, name in ((CHECKS, 'Checks'), (SIMULATOR, 'Simulator tests'),
                             (SOURCE, 'TestFlight')):
            self.assertIn(f'\nname: {name}\n', source)
            self.assertIn('branches: [dev]', source)
        self.assertNotIn('macos-', CHECKS)
        self.assertNotIn('secrets.', SIMULATOR)
        self.assertNotIn('ARTIFACT_AGE_RECIPIENT', SIMULATOR)
        self.assertNotIn('only_testing:', SOURCE)

    def test_post_merge_keeps_tests_and_device_builds(self):
        self.assertTrue(condition('test', 'push'))
        self.assertTrue(condition('build', 'push'))
        self.assertFalse(condition('test', 'push', changed='false'))
        self.assertFalse(condition('build', 'push', changed='false'))
        self.assertIn('needs: [decide, build]', job('sign'))

    def test_nothing_is_scheduled_and_manual_preview_has_no_device_archive(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            self.assertNotRegex(path.read_text(), re.compile(r'^  schedule:', re.M), path.name)
        self.assertTrue(condition('test', 'workflow_dispatch'))
        self.assertFalse(condition('test', 'workflow_dispatch', only_testing='none'))
        self.assertIn('DISTRIBUTION: simulator', SIMULATOR)
        self.assertIn('simulator) ;;', DECIDE)

    def test_only_dev_pushes_and_required_job_names_stay_stable(self):
        push = re.search(r'^  push:\n(.*?)(?=^  \S)', SOURCE, re.M | re.S).group(1)
        self.assertEqual(push.strip(), 'branches: [dev]')
        for key, expected in (('decide', 'Decide'), ('build', 'Unsigned archive')):
            self.assertEqual(re.search(r'^    name: (.+)$', job(key), re.M).group(1), expected)
        checks_linux = CHECKS.split('\n  linux:\n')[1].split('\n  labels:')[0]
        self.assertIn('    name: Linux checks\n', checks_linux)
        self.assertNotRegex(checks_linux, re.compile(r'^    if:', re.M))
        self.assertIn('python3 -m unittest discover -s ios/tools/dictation_log/tests -v', checks_linux)

    def test_dev_runs_do_not_serialize_but_jobs_supersede_old_work(self):
        workflow_concurrency = SOURCE.split('\nconcurrency:\n')[1].split('\njobs:')[0]
        self.assertIn('github.run_id', workflow_concurrency)
        for name in ('build', 'test'):
            self.assertIn('concurrency:', job(name))
            self.assertIn("&& 'push'", job(name))
            self.assertIn("cancel-in-progress: ${{ github.event_name == 'push' }}", job(name))
            self.assertIn('needs: decide', job(name))
        self.assertIn('group: typr-ci-sign-${{ needs.decide.outputs.sign }}', job('sign'))
        self.assertIn('cancel-in-progress: false', job('sign'))

    def test_push_compares_app_and_test_inputs(self):
        self.assertIn('DISTRIBUTION: testflight', job('decide'))
        self.assertIn('for mode in app test', DECIDE)
        self.assertIn('exit 1', DECIDE.split('Cannot compare app inputs;', 1)[1])

    def test_test_only_merges_skip_archive_but_keep_simulator(self):
        self.assertTrue(condition('test', 'push', changed='false', test_changed='true'))
        self.assertFalse(condition('build', 'push', changed='false', test_changed='true'))
        self.assertFalse(condition('test', 'push', changed='false',
                                   test_changed='true', only_testing='none'))

    def test_manual_testflight_still_builds(self):
        self.assertTrue(condition('build', 'workflow_dispatch'))

    def test_screenshots_are_manual_artifacts_not_pr_comments(self):
        simulator = job('test')
        self.assertIn("github.event_name == 'workflow_dispatch' && !cancelled()", simulator)
        self.assertIn('SCENES: ${{ inputs.scenes }}', simulator)
        self.assertIn('name: typr-screenshots-${{ github.run_id }}', simulator)
        self.assertNotIn('\n  screenshots:\n', SOURCE)
        self.assertNotIn('contents: write', SOURCE)

    def test_tests_never_hold_up_testflight_and_no_repair_agent_runs(self):
        # TestFlight follows the archive alone; red tests are fixed locally afterwards.
        self.assertIn("if: needs.decide.outputs.sign != '' && needs.build.result == 'success'", job('sign'))
        self.assertNotIn('typr-fix', SOURCE)
        self.assertNotIn('\n  test:\n', SOURCE)
        self.assertNotIn('\n  build:\n', SIMULATOR)
        self.assertNotIn('environment: typr-', SIMULATOR)
        for source in (SOURCE, SIMULATOR):
            self.assertNotIn('  pull_request:', source)
            self.assertIn('run: bash .github/typr/decide-lanes.sh', source)


if __name__ == '__main__':
    unittest.main()
