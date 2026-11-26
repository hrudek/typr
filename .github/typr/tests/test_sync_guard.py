from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
import importlib.util
import os
import re
import subprocess
import tempfile
import unittest

TYPR = Path(__file__).resolve().parents[1]
WORKFLOW = (TYPR.parents[1] / '.github/workflows/typr-sync.yml').read_text()
spec = importlib.util.spec_from_file_location('sync_guard', TYPR / 'sync-guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

BERLIN = ZoneInfo('Europe/Berlin')
MARKER = 'chore(typr): upstream sync to a394af28 [skip ci]'


def at(text):
    return datetime.fromisoformat(text).replace(tzinfo=BERLIN)


class SyncGuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = tmp.name
        self.git('init', '-q', '-b', 'dev')
        self.commit('feat(typr): something', '2026-11-20T12:00:00+01:00')

    def git(self, *args, **env):
        return subprocess.run(['git', '-C', self.repo, '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                              check=True, capture_output=True, text=True, env={**os.environ, **env}).stdout.strip()

    def commit(self, message, when):
        self.git('commit', '-q', '--allow-empty', '-m', message, GIT_COMMITTER_DATE=when, GIT_AUTHOR_DATE=when)

    def decide(self, event, now):
        return guard.decide(event, self.repo, at(now))[0]

    def test_scheduled_run_skips_when_todays_marker_exists(self):
        self.commit(MARKER, '2026-11-26T04:17:00+01:00')
        self.commit('fix(typr): later PR on top', '2026-11-26T09:00:00+01:00')
        for now in ('2026-11-26T05:17:00', '2026-11-26T08:17:00', '2026-11-26T23:59:59'):
            self.assertFalse(self.decide('schedule', now), now)

    def test_scheduled_run_proceeds_without_a_marker_today(self):
        self.assertTrue(self.decide('schedule', '2026-11-26T04:17:00'))
        self.commit(MARKER, '2026-11-25T04:17:00+01:00')
        self.assertTrue(self.decide('schedule', '2026-11-26T04:17:00'))

    def test_berlin_midnight_decides_the_day_not_utc(self):
        # 23:30 UTC on the 25th is 00:30 Berlin on the 26th.
        self.commit(MARKER, '2026-11-25T23:30:00+00:00')
        self.assertFalse(self.decide('schedule', '2026-11-26T04:17:00'))
        self.assertTrue(self.decide('schedule', '2026-11-27T00:05:00'))
        # 22:30 UTC in summer is 00:30 CEST the next day.
        self.commit(MARKER, '2026-07-01T22:30:00+00:00')
        self.assertFalse(self.decide('schedule', '2026-07-02T05:17:00'))
        self.assertTrue(self.decide('schedule', '2026-07-01T23:59:00'))

    def test_dispatch_always_proceeds(self):
        self.commit(MARKER, '2026-11-26T04:17:00+01:00')
        self.assertTrue(self.decide('workflow_dispatch', '2026-11-26T05:17:00'))

    def test_only_sync_markers_count(self):
        self.commit('chore(typr): upstream sync to a394af28', '2026-11-26T04:17:00+01:00')
        self.commit('docs: mention chore(typr): upstream sync to x [skip ci]', '2026-11-26T04:18:00+01:00')
        self.assertTrue(self.decide('schedule', '2026-11-26T05:17:00'))

    def test_marker_text_in_a_commit_body_does_not_count(self):
        self.commit(f'fix(typr): unrelated\n\n{MARKER}', '2026-11-26T04:17:00+01:00')
        self.assertTrue(self.decide('schedule', '2026-11-26T05:17:00'))

    def test_cli_prints_step_output_and_logs_the_reason(self):
        self.commit(MARKER, datetime.now(BERLIN).isoformat())
        out = subprocess.run(['python3', str(TYPR / 'sync-guard.py'), 'schedule', self.repo],
                             check=True, capture_output=True, text=True)
        self.assertEqual(out.stdout, 'run=false\n')
        self.assertIn('Already synced today', out.stderr)

    def test_cli_rejects_wrong_arguments_with_usage(self):
        for args in ([], ['schedule', self.repo, 'extra']):
            out = subprocess.run(['python3', str(TYPR / 'sync-guard.py'), *args], capture_output=True, text=True)
            self.assertEqual(out.returncode, 1)
            self.assertIn('usage: sync-guard.py EVENT [REPO]', out.stderr)
            self.assertNotIn('Traceback', out.stderr)


class WorkflowTests(unittest.TestCase):
    def test_cron_slots_are_off_the_hour_and_numerous(self):
        crons = re.findall(r'^    - cron: "(.+)"$', WORKFLOW, re.M)
        self.assertTrue(crons)
        slots = 0
        for cron in crons:
            minute, hours, *_ = cron.split()
            self.assertNotIn(minute, ('0', '30'), cron)
            slots += len(hours.split(','))
        self.assertGreaterEqual(slots, 3)

    def test_offset_step_is_gone_and_guard_gates_the_sync(self):
        self.assertNotIn('04:00 in Berlin', WORKFLOW)
        self.assertNotIn('+0100', WORKFLOW)
        self.assertIn('sync-guard.py "$EVENT"', WORKFLOW)
        self.assertIn("if: steps.when.outputs.run == 'true'", WORKFLOW)
        self.assertIn('workflow_dispatch:', WORKFLOW)

    def test_guard_and_plan_run_on_the_live_dev_tip(self):
        rebase = WORKFLOW.split('\n  resolve:')[0]
        self.assertRegex(rebase, r'checkout@\S+ # v4\n        with:\n          ref: dev\n')


if __name__ == '__main__':
    unittest.main()
