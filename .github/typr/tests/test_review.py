import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / '.github/workflows'
SOURCE = (WORKFLOWS / 'typr-review.yml').read_text()


class ReviewWorkflowTest(unittest.TestCase):
    def test_reviews_every_new_commit_and_cancels_the_older_review(self):
        self.assertIn('pull_request_target:', SOURCE)
        self.assertIn('types: [opened, synchronize, reopened, ready_for_review]', SOURCE)
        self.assertIn('group: typr-review-${{ github.event.pull_request.number }}', SOURCE)
        self.assertIn('cancel-in-progress: true', SOURCE)

    def test_only_same_repository_prs_without_branch_exclusions(self):
        self.assertIn('github.event.pull_request.head.repo.full_name == github.repository', SOURCE)
        self.assertIn("if: github.event.pull_request.head.repo.full_name == github.repository", SOURCE)

    def test_reviewer_reads_only(self):
        self.assertIn('persist-credentials: false', SOURCE)
        self.assertIn('--disallowedTools "Edit,MultiEdit,Write', SOURCE)
        self.assertNotIn('contents: write', SOURCE)

    def test_verdict_follows_findings(self):
        self.assertIn("count=$(jq '.findings | length'", SOURCE)
        self.assertIn('if (( count == 0 )); then\n              verdict=pass', SOURCE)

    def test_only_the_review_uses_claude(self):
        users = sorted(p.name for p in WORKFLOWS.glob('typr-*.yml')
                       if 'claude-code-action' in p.read_text())
        self.assertEqual(users, ['typr-review.yml'])

    def test_no_agent_starts_from_issues_or_comments(self):
        for path in WORKFLOWS.glob('typr-*.yml'):
            text = path.read_text()
            self.assertNotIn('issue_comment', text, path.name)
            self.assertNotIn('\n  issues:', text, path.name)


if __name__ == '__main__':
    unittest.main()
