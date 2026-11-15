"""Trusted merge controller contracts, with no GitHub writes or credentials."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('auto_merge', ROOT / '.github/typr/auto-merge.py')
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)
REPO = 'hrudek/typr'
SHA = 'a' * 40
MERGED = 'b' * 40
PARENT = 'c' * 40


class AutoMergeTests(unittest.TestCase):
    def setUp(self):
        self.pr = {'number': 7, 'state': 'open', 'draft': False, 'labels': [],
                   'base': {'ref': 'main', 'repo': {'full_name': REPO}},
                   'head': {'ref': 'feature/test', 'sha': SHA, 'repo': {'full_name': REPO}}}
        self.env = {'GH_REPO': REPO, 'SOURCE_BRANCH': 'feature/test', 'SOURCE_SHA': SHA}
        self.merged = {**self.pr, 'state': 'closed', 'merged': True,
                       'merged_by': {'login': 'github-actions[bot]'}, 'merge_commit_sha': MERGED}

    def test_eligibility_excludes_drafts_forks_old_commits_and_opt_out(self):
        self.assertTrue(merge.eligible(self.pr, REPO, 'feature/test', SHA))
        for fields in ({'draft': True}, {'labels': [{'name': 'no-auto-merge'}]},
                       {'head': {**self.pr['head'], 'sha': 'd' * 40}},
                       {'head': {**self.pr['head'], 'repo': None}},
                       {'head': {**self.pr['head'], 'repo': {'full_name': 'other/repo'}}},
                       {'base': {**self.pr['base'], 'ref': 'other'}}):
            with self.subTest(fields=fields):
                self.assertFalse(merge.eligible({**self.pr, **fields}, REPO, 'feature/test', SHA))

    def test_checks_require_both_green_and_respect_all_other_requirements(self):
        passing = [{'name': name, 'state': 'SUCCESS'} for name in merge.REQUIRED]
        for checks, code, expected in ((passing, 0, True), ([], 0, False),
                                      (passing[:1], 0, False), (passing, 8, False),
                                      (passing + [{'name': 'Extra', 'state': 'FAILURE'}], 0, False)):
            with self.subTest(checks=checks, code=code), patch.object(
                    merge.subprocess, 'run', return_value=subprocess.CompletedProcess(
                        [], code, json.dumps(checks), '')):
                self.assertEqual(merge.checks_pass(7), expected)

    def run_main(self, responses, green=True):
        with patch.dict(os.environ, self.env), patch.object(merge, 'api', side_effect=responses) as api, \
                patch.object(merge, 'checks_pass', return_value=green), \
                patch.object(merge.subprocess, 'run') as run:
            merge.main()
            return api, run

    def test_merge_pins_sha_and_explicitly_dispatches_after_bot_merge(self):
        api, run = self.run_main([[self.pr], self.pr, {'merged': True}, self.merged,
                                 {'workflow_runs': []}, {'workflow_runs': []},
                                 {'parents': [{'sha': PARENT}]}, {'workflow_runs': []}])
        self.assertEqual(api.call_args_list[2].args,
                         ('pulls/7/merge', 'PUT'))
        self.assertEqual(api.call_args_list[2].kwargs,
                         {'sha': SHA, 'merge_method': 'squash'})
        self.assertEqual([call.args[0][3] for call in run.call_args_list],
                         ['typr-checks.yml', 'typr-simulator.yml', 'typr-ci.yml'])
        command = run.call_args.args[0]
        self.assertIn('distribution=automatic', command)
        self.assertIn(f'base_sha={PARENT}', command)
        self.assertTrue(run.call_args.kwargs['check'])

    def test_target_review_uses_trusted_run_name_not_base_head_metadata(self):
        self.env.update(SOURCE_EVENT='pull_request_target', SOURCE_BRANCH='main',
                        SOURCE_SHA='d' * 40,
                        SOURCE_TITLE=f'Typr review · PR #7 · {SHA}')
        api, run = self.run_main([self.pr, self.pr, {'merged': True}, self.merged,
                                 {'workflow_runs': []}, {'workflow_runs': []},
                                 {'parents': [{'sha': PARENT}]}, {'workflow_runs': []}])
        self.assertEqual(api.call_args_list[0].args, ('pulls/7',))
        self.assertEqual(api.call_args_list[2].kwargs['sha'], SHA)
        self.assertEqual(run.call_count, 3)
        moved = copy.deepcopy(self.pr)
        moved['head']['sha'] = 'e' * 40
        api, run = self.run_main([moved])
        self.assertEqual(api.call_count, 1)
        run.assert_not_called()

    def test_target_review_rejects_missing_or_malformed_run_name(self):
        for title in ('', f'Untrusted PR #7 · {SHA}', 'Typr review · PR #7 · bad'):
            self.env.update(SOURCE_EVENT='pull_request_target', SOURCE_TITLE=title)
            with self.subTest(title=title), self.assertRaises(ValueError):
                self.run_main([])

    def test_pending_checks_never_merge_or_dispatch(self):
        api, run = self.run_main([[self.pr], self.pr], green=False)
        self.assertEqual(api.call_count, 2)
        run.assert_not_called()

    def test_revalidation_rejects_head_change_and_closed_unmerged_pr(self):
        moved = copy.deepcopy(self.pr)
        moved['head']['sha'] = 'd' * 40
        for pr in (moved, {**self.pr, 'state': 'closed', 'merged': False}):
            api, run = self.run_main([[self.pr], pr])
            self.assertEqual(api.call_count, 2)
            run.assert_not_called()

    def test_dispatch_recovery_and_duplicate_suppression(self):
        _, run = self.run_main([[self.merged], self.merged,
                               {'workflow_runs': []}, {'workflow_runs': []},
                                 {'parents': [{'sha': PARENT}]}, {'workflow_runs': []}])
        self.assertEqual(run.call_count, 3)
        for event in ('push', 'workflow_dispatch'):
            api, run = self.run_main([[self.merged], self.merged,
                                     *([{'workflow_runs': [{'event': event}]}] * 3)])
            self.assertEqual(api.call_count, 5)
            run.assert_not_called()

    def test_partial_dispatch_recovery_only_starts_missing_simulator(self):
        _, run = self.run_main([[self.merged], self.merged,
                               {'workflow_runs': [{'event': 'workflow_dispatch'}]},
                               {'workflow_runs': []}, {'parents': [{'sha': PARENT}]},
                               {'workflow_runs': [{'event': 'workflow_dispatch'}]}])
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0][3], 'typr-simulator.yml')
        self.assertIn(f'base_sha={PARENT}', run.call_args.args[0])

    def test_human_merge_does_not_dispatch_duplicate_push_ci(self):
        human = {**self.merged, 'merged_by': {'login': 'hrudek'}}
        _, run = self.run_main([[human], human])
        run.assert_not_called()

    def test_workflow_uses_trusted_code_and_completed_check_events(self):
        workflow = (ROOT / '.github/workflows/typr-auto-merge.yml').read_text()
        self.assertIn('workflow_run:', workflow)
        self.assertIn('workflows: [Checks, Typr review]', workflow)
        self.assertIn('types: [completed]', workflow)
        self.assertIn('ref: main', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('head_repository.full_name == github.repository', workflow)
        self.assertIn('SOURCE_EVENT: ${{ github.event.workflow_run.event }}', workflow)
        self.assertIn('SOURCE_TITLE: ${{ github.event.workflow_run.display_title }}', workflow)
        self.assertIn("workflow_run.conclusion == 'success'", workflow)
        self.assertNotIn('--admin', workflow)
        self.assertNotIn('secrets.', workflow)


if __name__ == '__main__':
    unittest.main()
