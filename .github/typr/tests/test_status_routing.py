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
        with patch.object(status, 'runs', return_value=runs) as listing, \
                patch.object(status, 'gh_json', side_effect=jobs), \
                patch.object(status, 'ago', return_value='yesterday'):
            self.assertEqual(status.last_testflight('owner/repo'), '✅ [yesterday](release)')
            listing.assert_called_once_with('typr-ci.yml', branch='main')

    def test_independent_lane_rows_include_automatic_dispatch_failures(self):
        def listing(workflow, **filters):
            return [dict(status='completed', conclusion='failure' if 'simulator' in workflow else 'success',
                         url=workflow, displayTitle='automatic main', event='workflow_dispatch',
                         createdAt='2026-01-02T00:00:00Z')]
        with patch.dict(status.os.environ, {'GH_REPO': 'owner/repo'}), \
                patch.object(status, 'find_issue', return_value={'number': 1}), \
                patch.object(status, 'runs', side_effect=listing), \
                patch.object(status, 'gh_json', return_value=[]), \
                patch.object(status, 'last_testflight', return_value='last upload'), \
                patch.object(status, 'ago', return_value='now'), \
                patch.object(status, 'gh') as gh, patch('builtins.print'):
            status.main()
            body = gh.call_args.args[-1]
            self.assertIn('[Simulator tests failed](typr-simulator.yml)', body)
            self.assertIn('| Checks | ✅ |', body)
            self.assertIn('| Simulator tests | ❌ |', body)
            self.assertIn('| TestFlight / device build | ✅ |', body)

    def test_failed_test_only_run_is_reported(self):
        run = dict(status='completed', conclusion='failure', url='tests',
                   displayTitle='test-only merge')
        self.assertIn('[main CI failed](tests)', status.red_runs(run)[0])
        self.assertEqual(status.red_runs({**run, 'conclusion': 'success'}), [])


if __name__ == '__main__':
    unittest.main()
