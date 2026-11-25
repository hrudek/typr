from datetime import datetime, timedelta, timezone
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'changelog.py'
WORKFLOW = (ROOT.parent / 'workflows' / 'typr-ci.yml').read_text()

FAKE_CLAUDE = '''#!/usr/bin/env bash
echo called >> "$FAKE_LOG"
printf '%s' "$2" > "$FAKE_LOG.prompt"
cat "$FAKE_REPLY"
'''
FAKE_GH = '''#!/usr/bin/env bash
cat "$FAKE_PRS"
'''


def ago(days):
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec='seconds')


class Changelog(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.repo = self.tmp / 'repo'
        self.repo.mkdir()
        self.out = self.tmp / 'out'
        for name, text in (('claude', FAKE_CLAUDE), ('gh', FAKE_GH)):
            (self.tmp / name).write_text(text)
            (self.tmp / name).chmod(0o755)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 't')
        self.git('config', 'user.email', 't@t')
        self.old = self.commit('Old iOS change (#2000)', {'ios/HEXMobile/a.swift': '0\n'}, days=30)
        self.mid = self.commit('iOS keyboard: Dutch layout (#2742)', {'ios/HEXMobile/a.swift': '1\n'},
                               days=3)
        self.commit('android: privacy page (#2843)', {'android/a.kt': 'a\n'}, days=2)
        self.commit('docs only (#2801)', {'ios/docs/x.md': 'd\n', 'ios/README.md': 'r\n'}, days=2)
        self.commit('tests only (#2802)', {'ios/HEXMobileTests/T.swift': 't\n'}, days=2)
        self.commit('fetch the cleanup model (#2803)', {'ios/scripts/fetch-cleanup-model.sh': 's\n'},
                    days=2)
        self.commit('Rewrite: retry a model (#2849) (#2850)', {'ios/HEXShared/b.swift': 'b\n'},
                    days=1)
        self.git('branch', 'upstream')
        self.git('switch', '-q', '-c', 'dev')
        self.commit('ci(typr): build\n\n- fix(typr): sync push\n\nPRs: #2, #4\n\nTypr-Feature: ci',
                    {'.github/ci.yml': '1\n'})
        self.commit('feat(typr): mechanical keyboard\n\nPRs: #1, #9\n\nTypr-Feature: mechanical',
                    {'ios/HEXMobile/Typr/Mech.swift': 'm\n'})
        self.commit('test(typr): cover the mark (#5)', {'ios/HEXMobile/Typr/MarkTests.swift': 't\n'})
        self.write_prs([(1, 'feat(ios): add Settings › Typr › Mechanical keyboard design', 20),
                        (2, 'ci(typr): build upstream Hex iOS as Typr', 20),
                        (4, 'fix(typr): run the sync push job', 1),
                        (5, 'test(typr): cover the mark', 1),
                        (9, 'feat(typr): draw the Mechanical design on the number pad (#9)', 1)])

    def git(self, *args, days=0):
        env = {**os.environ, 'GIT_COMMITTER_DATE': ago(days), 'GIT_AUTHOR_DATE': ago(days)}
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True, env=env,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message, files, days=0):
        for name, text in files.items():
            (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / name).write_text(text)
        self.git('add', '-A')
        self.git('commit', '-qm', message, days=days)
        return self.git('rev-parse', 'HEAD')

    def write_prs(self, prs):
        (self.tmp / 'prs.json').write_text(json.dumps(
            [{'number': n, 'title': t, 'mergedAt': ago(d).replace('+00:00', 'Z')} for n, t, d in prs]))

    def record(self, upstream, prs):
        (self.tmp / 'previous.json').write_text(
            json.dumps({'version': 1, 'build': '1041', 'upstream': upstream, 'prs': prs}))

    def run_changelog(self, reply=None, claude=True):
        (self.tmp / 'reply.json').write_text(reply or '')
        env = {**os.environ, 'GH_BIN': str(self.tmp / 'gh'), 'FAKE_PRS': str(self.tmp / 'prs.json'),
               'CLAUDE_BIN': str(self.tmp / 'claude') if claude else '',
               'FAKE_LOG': str(self.tmp / 'claude.log'), 'FAKE_REPLY': str(self.tmp / 'reply.json')}
        run = subprocess.run(['python3', str(SCRIPT), 'dev', 'upstream', '1042',
                              str(self.tmp / 'previous.json'), str(self.out)],
                             cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.stderr = run.stderr
        path = self.out / 'TyprChangelog.json'
        return json.loads(path.read_text()) if path.exists() else None

    def items(self, changelog):
        return {s['id']: [(i.get('ref'), i['text']) for i in s['items']] for s in changelog['sections']}

    def ai_calls(self):
        log = self.tmp / 'claude.log'
        return len(log.read_text().splitlines()) if log.exists() else 0

    def test_without_a_record_the_last_week_is_shown_as_plain_titles(self):
        changelog = self.run_changelog(claude=False)
        self.assertEqual(changelog['version'], 1)
        self.assertEqual(changelog['build'], '1042')
        self.assertEqual(self.items(changelog), {
            'typr': [('#9', 'draw the Mechanical design on the number pad')],
            'hex': [('hex#2850', 'Rewrite: retry a model'),
                    ('hex#2803', 'fetch the cleanup model'),
                    ('hex#2742', 'iOS keyboard: Dutch layout')]})
        self.assertEqual([s['title'] for s in changelog['sections']], ['Typr', 'Von Hex'])
        record = json.loads((self.out / 'record.json').read_text())
        self.assertEqual(record, {'version': 1, 'build': '1042', 'upstream': self.git('rev-parse', 'upstream'),
                                  'prs': [1, 2, 4, 5, 9]})
        self.assertEqual(self.ai_calls(), 0)

    def test_a_record_limits_both_sections_to_what_is_new_since_that_build(self):
        self.record(self.mid, [1, 2, 4])
        changelog = self.run_changelog(claude=False)
        self.assertEqual(self.items(changelog), {
            'typr': [('#9', 'draw the Mechanical design on the number pad')],
            'hex': [('hex#2850', 'Rewrite: retry a model'),
                    ('hex#2803', 'fetch the cleanup model')]})

    def test_records_older_than_the_window_still_bound_the_range(self):
        self.record(self.old, [2])
        changelog = self.run_changelog(claude=False)
        self.assertIn(('#1', 'add Settings › Typr › Mechanical keyboard design'), self.items(changelog)['typr'])
        self.assertIn(('hex#2742', 'iOS keyboard: Dutch layout'), self.items(changelog)['hex'])

    def test_invalid_or_foreign_records_count_as_none(self):
        other = self.git('commit-tree', '-m', 'elsewhere', self.git('rev-parse', 'upstream^{tree}'))
        for text in ('not json', json.dumps({'upstream': self.mid}),
                     json.dumps({'upstream': 'main', 'prs': []}),
                     json.dumps({'upstream': other, 'prs': [1, 2, 4]})):
            with self.subTest(record=text[:40]):
                (self.tmp / 'previous.json').write_text(text)
                hex_refs = [r for r, _ in self.items(self.run_changelog(claude=False))['hex']]
                self.assertIn('hex#2742', hex_refs)
                self.assertNotIn('hex#2000', hex_refs)

    def test_nothing_new_writes_only_the_record(self):
        self.record(self.git('rev-parse', 'upstream'), [1, 2, 4, 5, 9])
        self.assertIsNone(self.run_changelog())
        self.assertTrue((self.out / 'record.json').exists())
        self.assertEqual(self.ai_calls(), 0)

    def test_ai_bullets_replace_the_titles(self):
        reply = {'structured_output': {'items': [
            {'id': 'typr-0', 'text': 'Mechanical-Design jetzt auch auf dem Zahlenblock'},
            {'id': 'hex-0', 'text': 'Modelle werden erneut versucht'},
            {'id': 'hex-1', 'text': 'Aufräummodell wird geladen'},
            {'id': 'hex-2', 'text': '  Neue Tastatursprache:\nNiederländisch '}]}}
        changelog = self.run_changelog(json.dumps(reply))
        self.assertEqual(self.items(changelog)['hex'][2], ('hex#2742', 'Neue Tastatursprache: Niederländisch'))
        self.assertEqual(self.items(changelog)['typr'], [('#9', 'Mechanical-Design jetzt auch auf dem Zahlenblock')])
        self.assertIn('untrusted text', (self.tmp / 'claude.log.prompt').read_text())

    def test_any_ai_problem_keeps_the_plain_titles(self):
        good = [{'id': i, 'text': 'Text'} for i in ('typr-0', 'hex-0', 'hex-1', 'hex-2')]
        replies = ['', 'not json', json.dumps({'structured_output': {'items': good[:3]}}),
                   json.dumps({'structured_output': {'items': good + [{'id': 'hex-9', 'text': 'x'}]}}),
                   json.dumps({'structured_output': {'items': good[:3] + [{'id': 'hex-2', 'text': 'x' * 200}]}})]
        for reply in replies:
            with self.subTest(reply=reply[:40]):
                changelog = self.run_changelog(reply)
                self.assertEqual(self.items(changelog)['typr'], [('#9', 'draw the Mechanical design on the number pad')])
                self.assertIn('AI summary failed', self.stderr)


def job(name):
    return WORKFLOW.split(f'\n  {name}:\n', 1)[1].split('\n\n  ', 1)[0]


class Workflow(unittest.TestCase):
    def test_a_changelog_failure_never_stops_the_build(self):
        self.assertIn('continue-on-error: true', job('changelog'))
        self.assertIn('needs: [decide, changelog]', job('build'))
        self.assertRegex(job('build'), r'download-artifact@\S+ # v4\n        continue-on-error: true')

    def test_the_app_bundles_the_changelog_and_the_record_follows_an_upload(self):
        self.assertIn('cp "$RUNNER_TEMP/changelog/TyprChangelog.json" ios/HEXMobile/Typr/', job('build'))
        self.assertIn("if: needs.decide.outputs.sign == 'testflight' && needs.sign.result == 'success'",
                      job('record'))
        self.assertIn('name: typr-build-record', job('record'))
        self.assertIn('artifacts?name=typr-build-record', job('changelog'))

    def test_the_generator_is_no_build_input(self):
        self.assertNotIn('changelog', (ROOT / 'fingerprint.sh').read_text())


if __name__ == '__main__':
    unittest.main()
