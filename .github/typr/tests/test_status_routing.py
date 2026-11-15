"""A test-only main run is status-worthy, but is not a TestFlight delivery."""
import unittest
from unittest.mock import patch

from test_typr import module

status = module('typr_status_routing', 'status.py')


class StatusRoutingTests(unittest.TestCase):
    def test_test_only_run_does_not_replace_last_testflight(self):
        runs = [dict(databaseId=2, createdAt='2026-01-02T00:00:00Z', url='tests'),
                dict(databaseId=1, createdAt='2026-01-01T00:00:00Z', url='release')]
        jobs = [[{'name': 'Simulator tests', 'conclusion': 'success'},
                 {'name': 'Unsigned archive', 'conclusion': 'skipped'},
                 {'name': 'Sign ()', 'conclusion': 'skipped'}],
                [{'name': 'Sign (testflight)', 'conclusion': 'success'}]]
        with patch.object(status, 'runs', return_value=runs), \
                patch.object(status, 'gh_json', side_effect=jobs), \
                patch.object(status, 'ago', return_value='yesterday'):
            self.assertEqual(status.last_testflight('owner/repo'), '✅ [yesterday](release)')

    def test_failed_test_only_run_is_reported(self):
        run = dict(status='completed', conclusion='failure', url='tests',
                   displayTitle='test-only merge')
        self.assertIn('[main CI failed](tests)', status.red_runs(run)[0])
        self.assertEqual(status.red_runs({**run, 'conclusion': 'success'}), [])


if __name__ == '__main__':
    unittest.main()
