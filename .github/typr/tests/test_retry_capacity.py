"""Capacity retries without GitHub calls, real waits, credentials or macOS."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_typr import module, REPO as ROOT

capacity = module('typr_capacity', 'retry-capacity.py')
REPO = 'hrudek/typr'


class CapacityTests(unittest.TestCase):
    def setUp(self):
        self.run = {
            'id': 42, 'repository': {'full_name': REPO},
            'head_repository': {'full_name': REPO},
            'path': '.github/workflows/typr-ci.yml', 'event': 'push',
            'status': 'completed', 'conclusion': 'failure', 'run_attempt': 1,
            'head_sha': 'a' * 40, 'head_branch': 'dev', 'html_url': 'https://example/run/42',
        }
        self.job = {'id': 9, 'name': 'Simulator tests', 'runner_id': 0,
                    'steps': [], 'labels': ['xcode-27'], 'conclusion': 'cancelled'}
        self.annotations = [{'annotation_level': 'failure', 'message': capacity.CAPACITY_ERROR}]

    def test_only_failed_same_repo_allowlisted_runs_with_budget(self):
        self.assertTrue(capacity.eligible_run(self.run, REPO))
        self.assertTrue(capacity.eligible_run(
            {**self.run, 'path': '.github/workflows/typr-simulator.yml'}, REPO))
        self.assertFalse(capacity.eligible_run(
            {**self.run, 'path': '.github/workflows/typr-checks.yml'}, REPO))
        for change in (
            {'repository': {'full_name': 'other/repo'}}, {'head_repository': None},
            {'path': '.github/workflows/typr-retry.yml'}, {'event': 'workflow_run'},
            {'event': 'pull_request'},
            {'status': 'in_progress'}, {'conclusion': 'success'}, {'conclusion': 'cancelled'},
            {'run_attempt': 0}, {'run_attempt': 4},
        ):
            with self.subTest(change=change):
                self.assertFalse(capacity.eligible_run({**self.run, **change}, REPO))

    def test_requires_exact_failure_and_no_runner_or_executed_steps(self):
        self.assertTrue(capacity.eligible_job(self.job, self.annotations))
        self.assertTrue(capacity.eligible_job({**self.job, 'labels': ['macos-26']}, self.annotations))
        for change in ({'runner_id': 123}, {'steps': [{'name': 'Run tests'}]},
                       {'labels': ['self-hosted', 'macOS']}, {'labels': ['ubuntu-latest']},
                       {'conclusion': 'success'}):
            with self.subTest(change=change):
                self.assertFalse(capacity.eligible_job({**self.job, **change}, self.annotations))
        for annotations in ([], [{'message': 'Test assertion failed', 'annotation_level': 'failure'}],
                            [{'message': capacity.CAPACITY_ERROR, 'annotation_level': 'notice'}]):
            self.assertFalse(capacity.eligible_job(self.job, annotations))

    def test_three_backoffs_and_only_selected_job_is_rerun(self):
        for attempt, delay in enumerate((300, 600, 1200), 1):
            run = {**self.run, 'run_attempt': attempt}
            with self.subTest(attempt=attempt), \
                    patch.object(capacity, 'api', side_effect=[run, run, None]) as api, \
                    patch.object(capacity, 'pages', side_effect=[[self.job], self.annotations]), \
                    patch.object(capacity, 'current_source', return_value=True), \
                    patch.object(capacity.time, 'sleep') as sleep, \
                    patch.object(capacity, 'report'):
                capacity.retry(REPO, '42')
                sleep.assert_called_once_with(delay)
                self.assertEqual(api.call_args.args, (REPO, 'actions/jobs/9/rerun'))
                self.assertEqual(api.call_args.kwargs, {'method': 'POST'})

    def test_test_only_retry_does_not_rerun_skipped_release_jobs(self):
        skipped = [dict(self.job, id=10, name='Unsigned archive', conclusion='skipped'),
                   dict(self.job, id=11, name='Sign ()', conclusion='skipped')]
        with patch.object(capacity, 'api', side_effect=[self.run, self.run, None]) as api, \
                patch.object(capacity, 'pages', side_effect=[skipped + [self.job], [], [], self.annotations]), \
                patch.object(capacity, 'current_source', return_value=True), \
                patch.object(capacity.time, 'sleep'), patch.object(capacity, 'report'):
            capacity.retry(REPO, '42')
            self.assertEqual(api.call_args.args, (REPO, 'actions/jobs/9/rerun'))
            self.assertEqual(api.call_args.kwargs, {'method': 'POST'})

    def test_rejects_real_test_failures_without_wait_or_retry(self):
        job = {**self.job, 'runner_id': 1, 'steps': [{'name': 'Tests'}], 'conclusion': 'failure'}
        with patch.object(capacity, 'api', return_value=self.run) as api, \
                patch.object(capacity, 'pages', return_value=[job]) as pages, \
                patch.object(capacity, 'current_source', return_value=True), \
                patch.object(capacity.time, 'sleep') as sleep, patch.object(capacity, 'report'):
            capacity.retry(REPO, '42')
            sleep.assert_not_called()
            self.assertEqual(api.call_count, 1)
            self.assertEqual(pages.call_count, 1)

    def test_source_or_attempt_changes_during_wait_prevent_rerun(self):
        for updated in ({**self.run, 'run_attempt': 2}, {**self.run, 'status': 'in_progress'},
                        {**self.run, 'conclusion': 'cancelled'}, self.run):
            with self.subTest(updated=updated), \
                    patch.object(capacity, 'api', side_effect=[self.run, updated]) as api, \
                    patch.object(capacity, 'pages', side_effect=[[self.job], self.annotations]), \
                    patch.object(capacity, 'current_source', side_effect=[True, False]), \
                    patch.object(capacity.time, 'sleep'), patch.object(capacity, 'report'):
                capacity.retry(REPO, '42')
                self.assertEqual(api.call_count, 2)

    def test_exhausted_budget_never_fetches_jobs_or_waits(self):
        with patch.object(capacity, 'api', return_value={**self.run, 'run_attempt': 4}), \
                patch.object(capacity, 'pages') as pages, \
                patch.object(capacity.time, 'sleep') as sleep, patch.object(capacity, 'report'):
            capacity.retry(REPO, '42')
            pages.assert_not_called()
            sleep.assert_not_called()

    def test_only_unmoved_branch_is_current(self):
        with patch.object(capacity, 'api', return_value={'commit': {'sha': 'b' * 40}}):
            self.assertFalse(capacity.current_source(REPO, self.run))
        with patch.object(capacity, 'api', return_value={'commit': {'sha': self.run['head_sha']}}):
            self.assertTrue(capacity.current_source(REPO, self.run))

    def test_pagination(self):
        with patch.object(capacity, 'api', side_effect=[{'jobs': list(range(100))}, {'jobs': [100]}]):
            self.assertEqual(len(capacity.pages(REPO, 'actions/runs/42/jobs', 'jobs')), 101)

    def test_workflow_uses_trusted_code_and_bounded_linux_wait(self):
        source = (ROOT / '.github/workflows/typr-retry.yml').read_text()
        self.assertIn('workflows: ["TestFlight", "Simulator tests"]', source)
        self.assertIn('ref: dev', source)
        self.assertIn('runs-on: ubuntu-latest', source)
        self.assertIn('timeout-minutes: 25', source)
        self.assertIn('cancel-in-progress: false', source)
        self.assertNotIn('secrets.', source)
        self.assertNotIn('github.event.workflow_run.head_sha }}', source)


if __name__ == '__main__':
    unittest.main()
