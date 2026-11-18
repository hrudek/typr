"""No repair or conflict agent runs in CI: red runs and conflicts are fixed locally."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / '.github/workflows'


class NoRepairAgents(unittest.TestCase):
    def test_fix_and_conflict_workflows_are_gone(self):
        for name in ('typr-fix.yml', 'typr-conflicts.yml', 'typr-agent.yml'):
            self.assertFalse((WORKFLOWS / name).exists(), name)
        for name in ('conflicts.py', 'fix-triage.py'):
            self.assertFalse((ROOT / '.github/typr' / name).exists(), name)

    def test_only_the_review_uses_claude(self):
        users = sorted(p.name for p in WORKFLOWS.glob('typr-*.yml')
                       if 'claude-code-action' in p.read_text())
        self.assertEqual(users, ['typr-review.yml'])

    def test_nothing_dispatches_a_removed_workflow(self):
        for path in [*WORKFLOWS.glob('typr-*.yml'), *(ROOT / '.github/typr').glob('*.py')]:
            text = path.read_text()
            self.assertNotIn('typr-fix', text, path.name)
            self.assertNotIn('typr-conflicts', text, path.name)

    def test_sync_files_and_runtime_references_are_gone(self):
        for name in ('typr-sync.yml', 'typr-gate.yml', 'typr-upstream-pr.yml'):
            self.assertFalse((WORKFLOWS / name).exists(), name)
        scripts = ROOT / '.github/typr'
        for name in ('verify-sync-run.py', 'ours.txt'):
            self.assertFalse((scripts / name).exists(), name)
        # Do not scan tests: negative assertions deliberately name removed inputs.
        paths = [*WORKFLOWS.glob('*.yml')]
        for pattern in ('*.py', '*.sh', '*.json'):
            paths.extend(scripts.glob(pattern))
        for path in paths:
            for removed in ('sync/upstream', 'upstream-pr', 'SYNC_TOKEN',
                            'typr-gate', 'typr-sync', 'verify-sync-run', 'ours.txt'):
                self.assertNotIn(removed, path.read_text(), str(path))


if __name__ == '__main__':
    unittest.main()
