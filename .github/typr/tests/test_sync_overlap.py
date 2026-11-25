from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'sync-overlap.py'
WORKFLOW = (ROOT.parent / 'workflows' / 'typr-sync.yml').read_text()

FAKE_CLAUDE = '''#!/usr/bin/env bash
echo called >> "$FAKE_LOG"
printf '%s' "$2" > "$FAKE_LOG.prompt"
cat "$FAKE_REPLY"
'''
FAKE_GH = '''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
[[ -z "${FAKE_GH_FAIL:-}" ]] || { printf '%s\n' "$FAKE_GH_FAIL" >&2; exit 1; }
case "$1 $2" in
  'issue list') cat "$FAKE_ISSUES" ;;
  'issue create') cat > "$FAKE_BODY"; echo https://github.com/hrudek/typr/issues/99 ;;
esac
'''


class Overlap(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.repo = self.tmp / 'repo'
        self.repo.mkdir()
        for name, text in (('claude', FAKE_CLAUDE), ('gh', FAKE_GH)):
            (self.tmp / name).write_text(text)
            (self.tmp / name).chmod(0o755)
        (self.tmp / 'issues.json').write_text('[]')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 't')
        self.git('config', 'user.email', 't@t')
        self.commit('base', {'ios/kb.swift': 'k\n', 'android/a.kt': 'a\n'})
        self.git('branch', 'base')
        self.git('switch', '-q', '-c', 'upstream')
        self.mech_up = self.commit('iOS: mechanical key style (#2850)', {'ios/kb.swift': 'k2\n'})
        self.other = self.commit('Android: clipboard (#2810)', {'android/a.kt': 'a2\n'})
        self.git('switch', '-q', '-c', 'dev')
        self.commit('ci(typr): build\n\n- feat(typr): rebrand Hex to Typr\n\nPRs: #2, #11\n\n'
                    'Typr-Feature: ci', {'.github/ci.yml': '1\n'})
        self.commit('feat(typr): mechanical keyboard\n\n- Mechanical design\n\nPRs: #1, #9\n\n'
                    'Typr-Feature: mechanical-keyboard', {'ios/TyprMech.swift': 'm\n'})

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

    def run_overlap(self, matches=None, raw=None, dry_run=False, base='base', **env):
        if matches is not None:
            raw = json.dumps({'structured_output': {'matches': [
                {'feature': f, 'commit': c[:12], 'confidence': p, 'reason': r}
                for f, c, p, r in matches]}})
        (self.tmp / 'reply.json').write_text(raw or '')
        env = {**os.environ, 'CLAUDE_BIN': str(self.tmp / 'claude'), 'GH_BIN': str(self.tmp / 'gh'),
               'FAKE_LOG': str(self.tmp / 'ai'), 'FAKE_REPLY': str(self.tmp / 'reply.json'),
               'FAKE_GH_LOG': str(self.tmp / 'gh.log'), 'FAKE_ISSUES': str(self.tmp / 'issues.json'),
               'FAKE_BODY': str(self.tmp / 'body.md'), 'GH_REPO': 'hrudek/typr',
               'GITHUB_STEP_SUMMARY': str(self.tmp / 'summary'), **env}
        args = ['--dry-run'] if dry_run else []
        run = subprocess.run(['python3', str(SCRIPT), *args, base, 'upstream', 'dev'],
                             cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return run

    def ai_calls(self):
        path = self.tmp / 'ai'
        return len(path.read_text().splitlines()) if path.exists() else 0

    def created(self):
        path = self.tmp / 'gh.log'
        lines = path.read_text().splitlines() if path.exists() else []
        return [line for line in lines if line.startswith('issue create')]

    def summary(self):
        return (self.tmp / 'summary').read_text()

    def test_a_confident_match_opens_one_labelled_issue(self):
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.9, 'Same key style')])
        [create] = self.created()
        self.assertIn('Upstream overlap: mechanical keyboard ↔ hex#2850', create)
        self.assertIn('--label upstream-overlap', create)
        body = (self.tmp / 'body.md').read_text()
        self.assertTrue(body.startswith('<!-- typr-overlap: mechanical-keyboard 2850 -->'))
        self.assertNotIn('/commit/' + self.git('rev-parse', 'dev'), body)
        for text in ('https://github.com/anomalyco/hex/pull/2850', 'Typr-Feature: mechanical-keyboard',
                     f'https://github.com/anomalyco/hex/commit/{self.mech_up}',
                     '[#1](https://github.com/hrudek/typr/pull/1)', 'Same key style', '0.90',
                     '- [ ] compare behaviour', '- [ ] remove Typr feature', '- [ ] keep Typr feature'):
            self.assertIn(text, body)
        self.assertIn('label create upstream-overlap', (self.tmp / 'gh.log').read_text())
        self.assertIn('Opened: ', self.summary())

    def test_low_confidence_opens_no_issue(self):
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.5, 'Maybe')])
        self.assertEqual(self.ai_calls(), 1)
        self.assertEqual(self.created(), [])
        self.assertIn('no issue', self.summary())

    def test_invalid_answers_open_no_issue(self):
        for raw in ('not json', json.dumps({'structured_output': {'nope': []}}),
                    json.dumps({'structured_output': {'matches': 'x'}})):
            with self.subTest(raw=raw):
                run = self.run_overlap(raw=raw)
                self.assertIn('::warning::Upstream overlap check failed', run.stderr)
                self.assertEqual(self.created(), [])
        for bad in (('unknown-feature', self.mech_up, 0.9, 'x'),
                    ('mechanical-keyboard', 'f' * 40, 0.9, 'unknown commit'),
                    ('mechanical-keyboard', self.mech_up, 7, 'out of range'),
                    ('mechanical-keyboard', self.mech_up, 'high', 'not a number')):
            with self.subTest(match=bad):
                run = self.run_overlap([bad])
                self.assertIn('Ignoring invalid match', run.stderr)
                self.assertEqual(self.created(), [])

    def test_an_existing_issue_open_or_closed_is_not_repeated(self):
        marker = '<!-- typr-overlap: mechanical-keyboard 2850 -->'
        (self.tmp / 'issues.json').write_text(json.dumps([{'body': 'other'}, {'body': marker + '\nx'}]))
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.95, 'Same')])
        self.assertIn('issue list --state all', (self.tmp / 'gh.log').read_text())
        self.assertEqual(self.created(), [])
        self.assertIn('Skipped, issue exists', self.summary())

    def test_matches_of_one_pair_make_one_issue(self):
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.8, 'a'),
                          ('mechanical-keyboard', self.mech_up, 0.9, 'b')])
        self.assertEqual(len(self.created()), 1)

    def test_no_ai_call_without_new_upstream_commits(self):
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.9, 'x')], base='upstream')
        self.assertEqual(self.ai_calls(), 0)
        self.assertNotIn('gh.log', os.listdir(self.tmp))
        self.assertIn('no AI call', self.summary())

    def test_ai_or_gh_failure_exits_zero_without_issues(self):
        run = self.run_overlap(raw='{}', CLAUDE_BIN='/nonexistent/claude')
        self.assertIn('the sync is not affected', run.stderr)
        run = self.run_overlap([('mechanical-keyboard', self.mech_up, 0.9, 'x')], FAKE_GH_FAIL='gh broke')
        self.assertIn('gh broke', run.stderr)
        self.assertEqual(self.created(), [])
        self.assertIn('(CalledProcessError: gh broke); the sync is not affected.', self.summary())

    def test_disabled_issues_are_named_in_the_summary(self):
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.9, 'x')],
                         FAKE_GH_FAIL="the 'hrudek/typr' repository has disabled issues")
        self.assertIn('Issues are disabled on hrudek/typr; no overlap issue opened.', self.summary())
        self.assertEqual(self.created(), [])

    def test_dry_run_prints_issues_without_gh(self):
        run = self.run_overlap([('mechanical-keyboard', self.mech_up, 0.9, 'x')], dry_run=True)
        self.assertIn('--- Upstream overlap: mechanical keyboard ↔ hex#2850', run.stdout)
        self.assertNotIn('gh.log', os.listdir(self.tmp))

    def test_ci_feature_is_compared_only_by_its_user_visible_changes(self):
        self.run_overlap([('ci', self.mech_up, 0.9, 'x')], dry_run=True)
        prompt = (self.tmp / 'ai.prompt').read_text()
        self.assertIn('rebrand Hex to Typr', prompt)
        self.assertNotIn('.github/ci.yml', prompt)
        self.assertIn('Would open: Upstream overlap: build', self.summary())

    def test_untrusted_text_cannot_ping_link_or_forge_a_marker(self):
        reason = ('@octocat [x](https://evil) <!-- typr-overlap: ci 1 --> `code` #12 '
                  'https://evil.example/a WWW.evil.example &commat;octocat GH-5 gh-5 [r](/relative)')
        self.run_overlap([('mechanical-keyboard', self.mech_up, 0.9, reason)])
        body = (self.tmp / 'body.md').read_text()
        self.assertNotRegex(body, r'@\w')
        why = next(line for line in body.splitlines() if 'Why (Claude' in line)
        self.assertNotRegex(why, r'(?i)://|www\.')
        self.assertNotRegex(why, r'(?i)(?<!\\)&|\bgh-\d|\]\(')
        self.assertEqual(re.findall(r'<!-- typr-overlap', body), ['<!-- typr-overlap'])
        self.assertNotRegex(why, r'#\d')


def job(name):
    return re.search(rf'^  {name}:\n(.*?)(?=^  \S|\Z)', WORKFLOW, re.M | re.S).group(1)


class Workflow(unittest.TestCase):
    def test_overlap_runs_after_the_push_and_cannot_fail_the_sync(self):
        overlap = job('overlap')
        self.assertIn('needs: [rebase, validate, push]', overlap)
        self.assertIn("needs.push.result == 'success'", overlap)
        self.assertIn('needs.rebase.outputs.base != needs.rebase.outputs.upstream', overlap)
        self.assertIn('continue-on-error: true', overlap)
        self.assertNotIn('overlap', ''.join(re.findall(r'needs: .*', WORKFLOW.replace(overlap, ''))))

    def test_only_the_overlap_job_may_write_issues(self):
        self.assertIn('issues: write', job('overlap'))
        self.assertNotIn('TYPR_SYNC_DEPLOY_KEY', job('overlap'))
        self.assertNotIn('issues: write', WORKFLOW.replace(job('overlap'), ''))


if __name__ == '__main__':
    unittest.main()
