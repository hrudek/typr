"""Scheduling contracts: Linux-only PRs, parallel latest-main work, protected signing."""
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


def condition(name, event, distribution='', changed='true', only_testing='', draft=False,
              ref='refs/heads/main', test_changed=None):
    # Evaluate the actual single-line scheduling expression, not a copied policy.
    expression = re.search(r'^    if: (.+)$', job(name), re.M).group(1)
    values = {
        'github.event_name': event,
        'github.ref': ref,
        'inputs.distribution': distribution,
        'needs.decide.outputs.build': changed,
        'needs.decide.outputs.test': changed if test_changed is None else test_changed,
        'inputs.only_testing': only_testing,
        'github.event.pull_request.draft': draft,
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
            self.assertIn('branches: [main]', source)
        self.assertNotIn('macos-', CHECKS)
        self.assertNotIn('secrets.', SIMULATOR)
        self.assertNotIn('ARTIFACT_AGE_RECIPIENT', SIMULATOR)
        self.assertNotIn('only_testing:', SOURCE)

    def test_prs_never_allocate_macos_or_decide(self):
        for draft in (False, True):
            for name in ('test', 'build', 'decide'):
                with self.subTest(draft=draft, job=name):
                    self.assertFalse(condition(name, 'pull_request', draft=draft))

    def test_post_merge_keeps_tests_and_device_builds(self):
        self.assertTrue(condition('test', 'push'))
        self.assertTrue(condition('build', 'push'))
        self.assertFalse(condition('test', 'push', changed='false'))
        self.assertFalse(condition('build', 'push', changed='false'))
        self.assertIn('needs: [decide, build]', job('sign'))

    def test_nothing_is_scheduled_and_manual_preview_has_no_device_archive(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            self.assertNotRegex(path.read_text(), re.compile(r'^  schedule:', re.M), path.name)
        self.assertTrue(condition('test', 'workflow_dispatch', 'simulator'))
        self.assertFalse(condition('build', 'workflow_dispatch', 'simulator'))
        self.assertFalse(condition('test', 'workflow_dispatch', 'simulator', only_testing='none'))
        self.assertIn('simulator) ;;', DECIDE)

    def test_only_main_pushes_and_required_job_names_stay_stable(self):
        push = re.search(r'^  push:\n(.*?)(?=^  \S)', SOURCE, re.M | re.S).group(1)
        self.assertEqual(push.strip(), 'branches: [main]')
        for key, expected in (('linux', 'Linux checks'), ('decide', 'Decide'),
                              ('build', 'Unsigned archive')):
            self.assertEqual(re.search(r'^    name: (.+)$', job(key), re.M).group(1), expected)
        checks_linux = CHECKS.split('\n  linux:\n')[1].split('\n  labels:')[0]
        self.assertNotRegex(checks_linux, re.compile(r'^    if:', re.M))
        self.assertIn("if: github.event_name != 'pull_request'", job('decide'))
        self.assertIn('python3 -m unittest discover -s ios/tools/dictation_log/tests -v', job('linux'))

    def test_main_runs_do_not_serialize_but_jobs_supersede_old_work(self):
        workflow_concurrency = SOURCE.split('\nconcurrency:\n')[1].split('\njobs:')[0]
        self.assertIn('github.run_id', workflow_concurrency)
        for name in ('build', 'test'):
            self.assertIn('concurrency:', job(name))
            self.assertIn("&& 'main-auto'", job(name))
            self.assertIn("cancel-in-progress: ${{ github.event_name == 'push' || inputs.distribution == 'automatic' }}", job(name))
            self.assertIn('needs: decide', job(name))
        self.assertIn('group: typr-ci-sign-${{ needs.decide.outputs.sign }}', job('sign'))
        self.assertIn('cancel-in-progress: false', job('sign'))

    def test_automatic_dispatch_checks_app_inputs_and_main_ref(self):
        for name in ('test', 'build'):
            self.assertTrue(condition(name, 'workflow_dispatch', 'automatic'))
            self.assertFalse(condition(name, 'workflow_dispatch', 'automatic', changed='false'))
        decide = job('decide') + DECIDE
        self.assertIn('Automatic distribution only from main', decide)
        self.assertIn('BASE_SHA: ${{ inputs.base_sha }}', decide)
        self.assertIn('base=$BASE_SHA', decide)
        self.assertIn('for mode in app test', decide)
        self.assertIn('exit 1', decide.split('Cannot compare app inputs;', 1)[1])

    def test_test_only_merges_skip_archive_but_keep_simulator(self):
        for event, distribution in (('push', ''), ('workflow_dispatch', 'automatic')):
            self.assertTrue(condition('test', event, distribution, changed='false', test_changed='true'))
            self.assertFalse(condition('build', event, distribution, changed='false', test_changed='true'))
            self.assertFalse(condition('test', event, distribution, changed='false',
                                       test_changed='true', only_testing='none'))

    def test_manual_testflight_still_builds(self):
        self.assertTrue(condition('build', 'workflow_dispatch', 'testflight'))

    def test_screenshots_are_manual_artifacts_not_pr_comments(self):
        simulator = job('test')
        self.assertIn("inputs.distribution == 'simulator' && !cancelled()", simulator)
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
