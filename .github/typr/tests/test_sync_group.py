from contextlib import redirect_stderr
from pathlib import Path
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'sync-group.py'
spec = importlib.util.spec_from_file_location('sync_group', SCRIPT)
sync_group = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync_group)

FAKE = '''#!/usr/bin/env bash
echo called >> "$FAKE_LOG"
sleep "${FAKE_SLEEP:-0}"
cat "$FAKE_REPLY"
'''


class Repo(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.repo = self.tmp / 'repo'
        self.repo.mkdir()
        self.fake = self.tmp / 'claude'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.log = self.tmp / 'calls'
        self.reply = self.tmp / 'reply.json'
        self.git('init', '-q', '-b', 'dev')
        self.git('config', 'user.name', 't')
        self.git('config', 'user.email', 't@t')
        self.commit('upstream base', {'AGENTS.md': 'upstream\n', 'app.swift': 'a\n', 'kb.swift': 'k\n'})
        self.git('branch', 'upstream')
        self.ci = self.commit('ci(typr): build as Typr', {'AGENTS.md': 'typr\n', '.github/ci.yml': '1\n'})
        self.mech = self.commit('feat(typr): Mechanical keys (#1)', {'kb.swift': 'k mech\n', 'TyprMech.swift': 'm\n'})
        self.brand = self.commit('feat(typr): rebrand (#11)', {'app.swift': 'a typr\n', '.github/brand.py': 'b\n'})
        self.git('commit', '-q', '--allow-empty', '-m', 'chore(typr): upstream sync [skip ci]')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message, files):
        for name, text in files.items():
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / name).write_text(text)
        self.git('add', '-A')
        self.git('commit', '-qm', message)
        return self.git('rev-parse', 'HEAD')

    def group(self, groups=None, raw=None, **env):
        if groups is not None:
            raw = json.dumps({'structured_output': {'groups': [
                {'slug': slug, 'title': title, 'commits': [c[:12] for c in shas]}
                for slug, title, shas in groups]}})
        self.reply.write_text(raw if raw is not None else '')
        env = {**os.environ, 'CLAUDE_BIN': str(self.fake), 'FAKE_LOG': str(self.log),
               'FAKE_REPLY': str(self.reply), 'GITHUB_STEP_SUMMARY': str(self.tmp / 'summary'), **env}
        before = self.git('rev-parse', 'HEAD')
        run = subprocess.run(['python3', str(SCRIPT), 'group', 'upstream', 'HEAD'], cwd=self.repo,
                             env=env, capture_output=True, text=True, check=True)
        head = run.stdout.strip()
        subprocess.run(['git', '-C', str(self.repo), 'diff', '--quiet', before, head], check=True)
        self.git('reset', '-q', '--hard', head)
        return head

    def stack(self):
        """[(subject, files, slug, prs)] from the bottom up."""
        out = []
        for sha in self.git('rev-list', '--reverse', 'upstream..HEAD').split():
            message = self.git('log', '-1', '--format=%B', sha)
            files = sorted(self.git('diff-tree', '--no-commit-id', '-r', '--name-only', sha).split())
            trailer = [line.split(': ', 1)[1] for line in message.splitlines()
                       if line.startswith('Typr-Feature: ')]
            prs = [line for line in message.splitlines() if line.startswith('PRs: ')]
            out.append((message.splitlines()[0], files, trailer[0] if trailer else None,
                        prs[0] if prs else None))
        return out

    def bootstrap(self):
        return self.group([('ci', 'ci(typr): build as Typr', [self.ci]),
                           ('mechanical', 'feat(typr): Mechanical keyboard', [self.mech]),
                           ('branding', 'feat(typr): brand the app as Typr', [self.brand])])

    def calls(self):
        return len(self.log.read_text().splitlines()) if self.log.exists() else 0



class GroupTests(Repo):
    def test_bootstrap_groups_per_ai_and_splits_ci_paths(self):
        self.bootstrap()
        self.assertEqual(self.stack(), [
            ('ci(typr): build as Typr', ['.github/brand.py', '.github/ci.yml', 'AGENTS.md'], 'ci', 'PRs: #11'),
            ('feat(typr): Mechanical keyboard', ['TyprMech.swift', 'kb.swift'], 'mechanical', 'PRs: #1'),
            ('feat(typr): brand the app as Typr', ['app.swift'], 'branding', 'PRs: #11')])
        self.assertIn('feat(typr): rebrand', (self.tmp / 'summary').read_text())

    def test_no_ai_call_without_new_commits(self):
        head = self.bootstrap()
        self.assertEqual(self.calls(), 1)
        self.assertEqual(self.group(raw='not json'), head)
        self.assertEqual(self.calls(), 1)
        self.assertEqual(subprocess.run(['python3', str(SCRIPT), 'new', 'upstream', 'HEAD'], cwd=self.repo,
                                        capture_output=True, text=True).stdout.strip(), '0')

    def test_new_commits_extend_features_without_regrouping(self):
        self.bootstrap()
        before = self.stack()
        fix = self.commit('fix(typr): number pad keys (#9)', {'TyprPad.swift': 'p\n', '.github/ci.yml': '2\n'})
        self.group([('mechanical', 'ignored', [fix])])
        after = self.stack()
        self.assertEqual(len(after), 3)
        self.assertEqual(after[0][:3], before[0][:3])
        self.assertEqual(after[1], ('feat(typr): Mechanical keyboard', ['TyprMech.swift', 'TyprPad.swift', 'kb.swift'],
                                    'mechanical', 'PRs: #1, #9'))
        self.assertEqual(after[2], before[2])
        self.assertIn('PRs: #9, #11', self.git('log', '-1', '--format=%B', 'HEAD~2'))

    def test_a_new_feature_gets_its_own_commit_on_top(self):
        self.bootstrap()
        new = self.commit('feat(typr): haptics (#15)', {'TyprHaptics.swift': 'h\n'})
        self.group([('haptics', 'feat(typr): haptic key feedback', [new])])
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'mechanical', 'branding', 'haptics'])

    def test_features_sharing_a_file_become_one_commit(self):
        self.bootstrap()
        one = self.commit('feat(typr): sounds (#15)', {'TyprSound.swift': 's\n'})
        two = self.commit('feat(typr): haptics (#16)', {'TyprSound.swift': 's h\n', 'TyprHaptics.swift': 'h\n'})
        three = self.commit('feat(typr): branded keys (#17)', {'kb.swift': 'k mech typr\n'})
        self.group([('sounds', 'feat(typr): key sounds', [one]),
                    ('haptics', 'feat(typr): haptics', [two]),
                    ('keys', 'feat(typr): branded keys', [three])])
        stack = self.stack()
        self.assertEqual([s[2] for s in stack], ['ci', 'mechanical', 'branding', 'sounds'])
        self.assertEqual(stack[1][3], 'PRs: #1, #17')
        self.assertEqual(stack[3][1:], (['TyprHaptics.swift', 'TyprSound.swift'], 'sounds', 'PRs: #15, #16'))

    def test_bad_ai_output_falls_back_to_area_grouping(self):
        cases = {
            'not json': (None, 'not json'),
            'unknown commit': ([('x', 'feat(typr): x', ['0' * 12])], None),
            'app files in ci': ([('ci', 'ci(typr): all', [self.ci, self.mech, self.brand])], None),
            'bad title': ([('ci', 'ci(typr): x', [self.ci]), ('a', 'rm -rf /', [self.mech, self.brand])], None),
            'missing commit': ([('ci', 'ci(typr): x', [self.ci])], None),
        }
        for case, (groups, raw) in cases.items():
            with self.subTest(case=case):
                self.git('reset', '-q', '--hard', self.brand)
                self.group(groups, raw)
                self.assertEqual([(s[0], s[2]) for s in self.stack()],
                                 [('ci(typr): build upstream Hex iOS as Typr, sync daily, upload to TestFlight', 'ci'),
                                  ('feat(typr): Typr features', 'typr')])
                self.assertIn('grouped by area', (self.tmp / 'summary').read_text())

    def test_ai_failure_and_timeout_fall_back(self):
        self.group(raw='{}', CLAUDE_BIN='/nonexistent/claude')
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'typr'])
        self.git('reset', '-q', '--hard', self.brand)
        self.group(raw='{}', FAKE_SLEEP='5', TYPR_GROUP_TIMEOUT='1')
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'typr'])


class TreeGuardTests(Repo):
    def run_in_repo(self, build):
        cwd = os.getcwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, cwd)
        upstream = self.git('rev-parse', 'upstream')
        head = self.git('rev-parse', 'HEAD')
        self.reply.write_text('not json')
        env = {'CLAUDE_BIN': str(self.fake), 'FAKE_LOG': str(self.log), 'FAKE_REPLY': str(self.reply),
               'GITHUB_STEP_SUMMARY': str(self.tmp / 'summary')}
        with mock.patch.dict(os.environ, env), mock.patch.object(sync_group, 'build', build), \
                redirect_stderr(io.StringIO()):
            return head, sync_group.group_head(upstream, head)

    def test_a_tree_mismatch_keeps_the_plain_rebase(self):
        wrong = self.git('rev-parse', 'upstream')
        head, result = self.run_in_repo(lambda *args: wrong)
        self.assertEqual(result, head)
        self.assertIn('kept as rebased', (self.tmp / 'summary').read_text())

    def test_a_tree_mismatch_of_the_ai_grouping_falls_back_to_area(self):
        real, attempts = sync_group.build, []

        def build(upstream, head, groups, workdir):
            attempts.append([g.slug for g in groups])
            return self.git('rev-parse', 'upstream') if len(attempts) == 1 else real(upstream, head, groups, workdir)
        with mock.patch.object(sync_group, 'ask_ai', lambda new, groups: (
                {c.sha: ('ci' if c.sha == self.ci else 'feature') for c in new}, {'feature': 'feat(typr): f'})):
            head, result = self.run_in_repo(build)
        self.assertEqual(attempts, [['ci', 'feature'], ['ci', 'typr']])
        self.git('diff', '--quiet', head, result)


if __name__ == '__main__':
    unittest.main()
