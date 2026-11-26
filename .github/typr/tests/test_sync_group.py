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
printf '%s' "$2" > "$FAKE_LOG.prompt"
sleep "${FAKE_SLEEP:-0}"
cat "$FAKE_REPLY"
'''
FAKE_GH = '''#!/usr/bin/env bash
[[ -z "${FAKE_GH_FAIL:-}" ]] || exit 1
cat "$FAKE_PRS/$3.json"
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
        self.gh = self.tmp / 'gh'
        self.gh.write_text(FAKE_GH)
        self.gh.chmod(0o755)
        self.prs = self.tmp / 'prs'
        self.prs.mkdir()
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
                {'slug': slug, 'title': title, 'changes': [c if c.startswith('pr') else c[:12] for c in shas]}
                for slug, title, shas in groups]}})
        self.reply.write_text(raw if raw is not None else '')
        env = {**os.environ, 'CLAUDE_BIN': str(self.fake), 'FAKE_LOG': str(self.log),
               'FAKE_REPLY': str(self.reply), 'GITHUB_STEP_SUMMARY': str(self.tmp / 'summary'),
               'GH_BIN': str(self.gh), 'FAKE_PRS': str(self.prs), 'TYPR_REGROUP': '', **env}
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
        return self.group([('mechanical', 'feat(typr): Mechanical keyboard', [self.mech]),
                           ('branding', 'feat(typr): brand the app as Typr', [self.brand])])

    def prompt(self):
        return (self.tmp / 'calls.prompt').read_text()

    def calls(self):
        return len(self.log.read_text().splitlines()) if self.log.exists() else 0



CI_TITLE = 'ci(typr): build upstream Hex iOS as Typr, sync daily, upload to TestFlight'


class GroupTests(Repo):
    def test_bootstrap_groups_per_ai_and_splits_ci_paths(self):
        self.bootstrap()
        self.assertEqual(self.stack(), [
            (CI_TITLE, ['.github/brand.py', '.github/ci.yml', 'AGENTS.md'], 'ci', 'PRs: #11'),
            ('feat(typr): Mechanical keyboard', ['TyprMech.swift', 'kb.swift'], 'mechanical', 'PRs: #1'),
            ('feat(typr): brand the app as Typr', ['app.swift'], 'branding', 'PRs: #11')])
        self.assertIn('feat(typr): rebrand', (self.tmp / 'summary').read_text())
        self.assertNotIn(self.ci[:12], self.prompt())

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

    def test_features_sharing_a_file_stay_separate_when_the_ai_says_so(self):
        self.bootstrap()
        one = self.commit('feat(typr): sounds (#15)', {'TyprSound.swift': 's\n'})
        two = self.commit('feat(typr): haptics (#16)', {'TyprSound.swift': 's h\n', 'TyprHaptics.swift': 'h\n'})
        three = self.commit('feat(typr): branded keys (#17)', {'kb.swift': 'k mech typr\n'})
        self.group([('sounds', 'feat(typr): key sounds', [one]),
                    ('haptics', 'feat(typr): haptics', [two]),
                    ('keys', 'feat(typr): branded keys', [three])])
        self.assertEqual([(s[2], s[1], s[3]) for s in self.stack()[1:]], [
            ('mechanical', ['TyprMech.swift', 'kb.swift'], 'PRs: #1'),
            ('branding', ['app.swift'], 'PRs: #11'),
            ('sounds', ['TyprSound.swift'], 'PRs: #15'),
            ('haptics', ['TyprHaptics.swift', 'TyprSound.swift'], 'PRs: #16'),
            ('keys', ['kb.swift'], 'PRs: #17')])
        self.assertEqual(self.git('show', 'HEAD~2:TyprSound.swift'), 's')
        self.assertIn('Changes that touch the same files can still be separate', self.prompt())

    def test_a_change_moved_below_another_feature_on_the_same_file_is_replayed(self):
        settings = 'header\n' + 'x\n' * 6 + 'footer\n'
        self.commit('feat(typr): settings page (#20)', {'Settings.swift': settings})
        first = self.git('rev-parse', 'HEAD')
        self.bootstrap_with(first)
        news = self.commit('feat(typr): what is new (#21)', {'Settings.swift': settings.replace('footer', 'footer news')})
        mech = self.commit('fix(typr): mechanical row (#22)',
                           {'Settings.swift': settings.replace('header', 'header mech').replace('footer', 'footer news')})
        self.group([('whats-new', 'feat(typr): show what is new', [news]), ('mechanical', 'x', [mech])])
        stack = self.stack()
        self.assertEqual([s[2] for s in stack], ['ci', 'mechanical', 'branding', 'whats-new'])
        self.assertEqual(stack[1][3], 'PRs: #1, #20, #22')
        self.assertEqual(self.git('show', 'HEAD~2:Settings.swift').splitlines()[::7], ['header mech', 'footer'])

    def test_a_conflicting_replay_falls_back_to_area(self):
        self.bootstrap()
        news = self.commit('feat(typr): what is new (#21)', {'kb.swift': 'k news\n'})
        mech = self.commit('fix(typr): mechanical row (#22)', {'kb.swift': 'k news mech\n'})
        self.group([('whats-new', 'feat(typr): show what is new', [news]), ('mechanical', 'x', [mech])])
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'mechanical', 'branding', 'typr'])
        self.assertIn('grouped by Claude discarded: RuntimeError: conflict in kb.swift', (self.tmp / 'summary').read_text())

    def test_bad_ai_output_falls_back_to_area_grouping(self):
        cases = {
            'not json': (None, 'not json'),
            'unknown commit': ([('x', 'feat(typr): x', ['0' * 12])], None),
            'app files in ci': ([('ci', 'ci(typr): all', [self.mech, self.brand])], None),
            'ci title': ([('a', 'ci(typr): x', [self.mech, self.brand])], None),
            'bad title': ([('a', 'rm -rf /', [self.mech, self.brand])], None),
            'missing commit': ([('a', 'feat(typr): x', [self.mech])], None),
            'ci-only commit': ([('a', 'feat(typr): x', [self.ci, self.mech, self.brand])], None),
        }
        for case, (groups, raw) in cases.items():
            with self.subTest(case=case):
                self.git('reset', '-q', '--hard', self.brand)
                self.group(groups, raw)
                self.assertEqual([(s[0], s[2]) for s in self.stack()],
                                 [(CI_TITLE, 'ci'), ('feat(typr): Typr features', 'typr')])
                self.assertIn('grouped by area', (self.tmp / 'summary').read_text())

    def test_ai_failure_and_timeout_fall_back(self):
        self.group(raw='{}', CLAUDE_BIN='/nonexistent/claude')
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'typr'])
        self.git('reset', '-q', '--hard', self.brand)
        self.group(raw='{}', FAKE_SLEEP='5', TYPR_GROUP_TIMEOUT='1')
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'typr'])

    def test_only_ci_commits_need_no_ai(self):
        self.bootstrap()
        self.commit('ci(typr): faster checks (#30)', {'.github/ci.yml': '3\n'})
        self.group(raw='not json')
        self.assertEqual(self.calls(), 1)
        self.assertEqual([s[3] for s in self.stack()], ['PRs: #11, #30', 'PRs: #1', 'PRs: #11'])

    def bootstrap_with(self, settings_commit):
        return self.group([('mechanical', 'feat(typr): Mechanical keyboard', [self.mech, settings_commit]),
                           ('branding', 'feat(typr): brand the app as Typr', [self.brand])])


class RegroupTests(Repo):
    """dev holds one squashed feature with PRs #1 and #19 that share Settings.swift."""

    def setUp(self):
        super().setUp()
        self.git('reset', '-q', '--hard', 'upstream')
        self.ci = self.commit('ci(typr): build as Typr (#2)', {'.github/ci.yml': '1\n'})
        settings = 'top\n' + 'x\n' * 6 + 'bottom\n'
        pr1 = self.commit('feat(typr): Mechanical keys (#1)', {'Settings.swift': settings, 'kb.swift': 'k mech\n'})
        pr19 = self.commit('feat(typr): show what is new (#19)',
                           {'Settings.swift': settings.replace('bottom', 'bottom news'), 'TyprNews.swift': 'n\n'})
        for number, sha, title in ((1, pr1, 'feat(typr): Mechanical keys'),
                                   (19, pr19, 'feat(typr): show what is new')):
            (self.prs / f'{number}.json').write_text(json.dumps(
                {'title': title, 'body': f'body of #{number}', 'mergeCommit': {'oid': sha}}))
        self.group([('mechanical', 'feat(typr): Mechanical keyboard', [pr1, pr19])])
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'mechanical'])
        self.squashed = self.git('rev-parse', 'HEAD')

    def test_regroup_splits_an_existing_feature_by_pr(self):
        self.assertEqual(subprocess.run(['python3', str(SCRIPT), 'new', 'upstream', 'HEAD'], cwd=self.repo,
                                        env={**os.environ, 'TYPR_REGROUP': 'true'},
                                        capture_output=True, text=True).stdout.strip(), '2')
        self.group([('mechanical-keyboard', 'feat(typr): Mechanical keyboard design', [self.squashed]),
                    ('whats-new', 'feat(typr): show what is new after an update', ['pr19'])], TYPR_REGROUP='true')
        self.assertEqual(self.stack(), [
            (CI_TITLE, ['.github/ci.yml'], 'ci', 'PRs: #2'),
            ('feat(typr): Mechanical keyboard design', ['Settings.swift', 'kb.swift'], 'mechanical-keyboard', 'PRs: #1'),
            ('feat(typr): show what is new after an update', ['Settings.swift', 'TyprNews.swift'], 'whats-new',
             'PRs: #19')])
        self.assertIn(f'- {self.squashed[:12]}: feat(typr): Mechanical keys; body of #1', self.prompt())
        self.assertIn('- pr19: feat(typr): show what is new; body of #19', self.prompt())
        self.assertNotIn(self.ci[:12], self.prompt())
        self.assertIn('regrouped by Claude', (self.tmp / 'summary').read_text())

    def test_without_regroup_existing_features_are_kept(self):
        self.assertEqual(self.group(raw='not json'), self.squashed)
        self.assertEqual(self.calls(), 1)

    def test_regroup_falls_back_to_the_current_features(self):
        self.group(raw='not json', TYPR_REGROUP='true')
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'mechanical'])
        self.assertIn('grouped by area', (self.tmp / 'summary').read_text())

    def test_without_pr_data_regroup_keeps_the_feature_whole(self):
        self.group([('mechanical', 'feat(typr): Mechanical keyboard', [self.squashed])],
                   TYPR_REGROUP='true', FAKE_GH_FAIL='1')
        self.assertEqual([s[2] for s in self.stack()], ['ci', 'mechanical'])
        self.assertNotIn('pr19', self.prompt())


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

        def build(upstream, groups):
            attempts.append([g.slug for g in groups])
            return self.git('rev-parse', 'upstream') if len(attempts) == 1 else real(upstream, groups)
        with mock.patch.object(sync_group, 'ask_ai', lambda todo, groups, regroup: (
                {c.id: 'feature' for c in todo}, {'feature': 'feat(typr): f'})):
            head, result = self.run_in_repo(build)
        self.assertEqual(attempts, [['ci', 'feature'], ['ci', 'typr']])
        self.git('diff', '--quiet', head, result)


if __name__ == '__main__':
    unittest.main()
