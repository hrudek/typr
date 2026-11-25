from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'sync.sh'
WORKFLOW = (SCRIPT.parents[2] / '.github/workflows/typr-sync.yml').read_text()


class SyncTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self.out = self.repo / '.out'
        self.git('init', '-q', '-b', 'dev')
        self.git('config', 'user.name', 't')
        self.git('config', 'user.email', 't@t')
        self.git('config', 'rerere.enabled', 'false')
        self.commit('upstream base', {'AGENTS.md': 'upstream guide\n', 'app.swift': 'a\nb\nc\n'})
        self.git('branch', 'upstream')
        self.commit('typr guide', {'AGENTS.md': 'typr guide\n'})
        self.commit('typr hook', {'app.swift': 'a\nb typr\nc\n', 'Typr.swift': 'typr\n'})
        self.git('switch', '-q', 'upstream')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message, files):
        for name, text in files.items():
            (self.repo / name).write_text(text)
        self.git('add', '-A')
        self.git('commit', '-qm', message)

    def sync(self, *args, start='dev', upstream='upstream'):
        self.out.write_text('')
        env = dict(os.environ, GITHUB_OUTPUT=str(self.out), GIT_EDITOR='true',
                   START=self.git('rev-parse', start), UPSTREAM=self.git('rev-parse', upstream))
        run = subprocess.run(['bash', str(SCRIPT), *args], cwd=self.repo, env=env,
                             capture_output=True, text=True)
        outputs = dict(line.split('=', 1) for line in self.out.read_text().splitlines())
        return run.returncode, outputs

    def test_nothing_new_upstream_or_typr_is_a_noop(self):
        self.git('switch', '-q', 'dev')
        self.git('reset', '-q', '--hard', 'upstream')
        self.commit('feat(typr): hook\n\nTypr-Feature: hook', {'Typr.swift': 'typr\n'})
        self.git('commit', '-q', '--allow-empty', '-m', 'chore(typr): upstream sync [skip ci]')
        status, outputs = self.sync('plan', 'dev', 'upstream')
        self.assertEqual((status, outputs['new'], outputs['noop']), (0, '0', 'true'))
        self.commit('fix(typr): hook (#3)', {'Typr.swift': 'typr fixed\n'})
        status, outputs = self.sync('plan', 'dev', 'upstream')
        self.assertEqual((status, outputs['new'], outputs['noop']), (0, '1', 'false'))

    def test_new_typr_commits_alone_rebase_and_drop_the_marker(self):
        self.git('switch', '-q', 'dev')
        self.git('commit', '-q', '--allow-empty', '-m', 'chore(typr): upstream sync [skip ci]')
        status, outputs = self.sync('rebase')
        self.assertEqual(status, 0)
        self.assertEqual(self.git('log', '--format=%s', 'upstream..HEAD'), 'typr hook\ntypr guide')

    def test_rebase_keeps_the_typr_agents_md(self):
        self.commit('upstream news', {'AGENTS.md': 'new upstream guide\n', 'other.rs': 'x\n'})
        self.assertEqual(self.sync('plan', 'dev', 'upstream')[1]['noop'], 'false')
        status, outputs = self.sync('rebase')
        self.assertEqual(status, 0)
        self.assertEqual(outputs['head'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(self.git('show', 'HEAD:AGENTS.md'), 'typr guide')
        self.assertEqual(self.git('rev-list', '--count', 'upstream..HEAD'), '2')
        self.assertEqual(self.git('show', 'HEAD:other.rs'), 'x')

    def test_the_skip_ci_marker_of_the_last_sync_is_dropped(self):
        self.git('switch', '-q', 'dev')
        self.git('commit', '-q', '--allow-empty', '-m', 'chore(typr): upstream sync [skip ci]')
        self.git('switch', '-q', 'upstream')
        self.commit('upstream news', {'other.rs': 'x\n'})
        self.assertEqual(self.sync('rebase')[0], 0)
        self.assertEqual(self.git('log', '--format=%s', 'upstream..HEAD'), 'typr hook\ntypr guide')

    def test_other_conflicts_stop_with_their_files(self):
        self.commit('upstream edit', {'app.swift': 'a\nb upstream\nc\n'})
        status, outputs = self.sync('rebase')
        self.assertEqual((status, outputs['conflicts']), (3, 'app.swift'))
        (self.repo / 'app.swift').write_text('a\nb upstream typr\nc\n')
        status, outputs = self.sync('resume')
        self.assertEqual(status, 0)
        self.assertEqual(self.git('show', 'HEAD:app.swift'), 'a\nb upstream typr\nc')


def job(name):
    return re.search(rf'^  {name}:\n(.*?)(?=^  \S|\Z)', WORKFLOW, re.M | re.S).group(1)


class WorkflowJobTests(unittest.TestCase):
    def test_jobs_after_a_skipped_resolve_still_run(self):
        for name, needs in (('group', 'resolve'), ('validate', 'group'), ('push', 'validate')):
            with self.subTest(job=name):
                condition = re.search(r'^    if: >-\n((?:      .+\n)+)', job(name), re.M).group(1)
                self.assertIn('!cancelled()', condition)
                self.assertIn("needs.rebase.result == 'success'", condition)
                self.assertIn("needs.rebase.outputs.noop == 'false'", condition)
                self.assertIn(f"needs.{needs}.result == 'success'", condition)

    def test_regrouping_keeps_the_tree_so_lanes_follow_the_inputs_only(self):
        self.assertIn('git diff --quiet rebased "$head"', job('group'))
        self.assertIn('fingerprint.sh . "$START" "$mode"', job('validate'))
        self.assertIn('fingerprint.sh . HEAD "$mode"', job('validate'))
        self.assertIn('[skip ci]', job('push'))


class WorkflowFilterTests(unittest.TestCase):
    def jq(self, name, document):
        expression = re.search(rf"^      {name}: '(.+)'$", WORKFLOW, re.M).group(1)
        run = subprocess.run(['jq', '-r', expression], input=json.dumps(document),
                             capture_output=True, text=True, check=True)
        return run.stdout.split()

    def test_only_active_upstream_workflows_are_disabled(self):
        workflows = [(1, 'active', '.github/workflows/release.yml'),
                     (2, 'disabled_manually', '.github/workflows/deploy.yml'),
                     (3, 'active', '.github/workflows/typr-ci.yml'),
                     (4, 'active', 'dynamic/pages/pages-build-deployment'),
                     (5, 'active', '.github/workflows/new-macos.yaml')]
        document = {'workflows': [{'id': i, 'state': state, 'path': path} for i, state, path in workflows]}
        self.assertEqual(self.jq('UPSTREAM_WORKFLOWS', document),
                         ['1', '.github/workflows/release.yml', '5', '.github/workflows/new-macos.yaml'])

    def test_only_unfinished_upstream_runs_are_cancelled(self):
        runs = [(1, 'queued', '.github/workflows/new-macos.yml'),
                (2, 'completed', '.github/workflows/release.yml'),
                (3, 'in_progress', '.github/workflows/typr-ci.yml')]
        document = {'workflow_runs': [{'id': i, 'status': status, 'path': path} for i, status, path in runs]}
        self.assertEqual(self.jq('UPSTREAM_RUNS', document), ['1'])


if __name__ == '__main__':
    unittest.main()
