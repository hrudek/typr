from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'sync.sh'


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

    def test_nothing_new_upstream_is_a_noop(self):
        status, outputs = self.sync('plan', 'dev', 'upstream')
        self.assertEqual((status, outputs['noop']), (0, 'true'))

    def test_rebase_keeps_the_typr_agents_md(self):
        self.commit('upstream news', {'AGENTS.md': 'new upstream guide\n', 'other.rs': 'x\n'})
        self.assertEqual(self.sync('plan', 'dev', 'upstream')[1]['noop'], 'false')
        status, outputs = self.sync('rebase')
        self.assertEqual(status, 0)
        self.assertEqual(outputs['head'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(self.git('show', 'HEAD:AGENTS.md'), 'typr guide')
        self.assertEqual(self.git('rev-list', '--count', 'upstream..HEAD'), '2')
        self.assertEqual(self.git('show', 'HEAD:other.rs'), 'x')

    def test_other_conflicts_stop_with_their_files(self):
        self.commit('upstream edit', {'app.swift': 'a\nb upstream\nc\n'})
        status, outputs = self.sync('rebase')
        self.assertEqual((status, outputs['conflicts']), (3, 'app.swift'))
        (self.repo / 'app.swift').write_text('a\nb upstream typr\nc\n')
        status, outputs = self.sync('resume')
        self.assertEqual(status, 0)
        self.assertEqual(self.git('show', 'HEAD:app.swift'), 'a\nb upstream typr\nc')


if __name__ == '__main__':
    unittest.main()
