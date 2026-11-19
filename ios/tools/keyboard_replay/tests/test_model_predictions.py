"""Checks the prediction bar with fake model providers through the keyboard's own engine."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1]


class ModelPredictionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        binary = os.environ.get("KEYBOARD_REPLAY")
        with tempfile.TemporaryDirectory() as scratch:
            if not binary:
                built = subprocess.run(["bash", str(TOOL / "build.sh"), str(Path(scratch) / "build")],
                                       capture_output=True, text=True, check=True)
                binary = built.stdout.strip().splitlines()[-1]
            run = subprocess.run([binary, "--model-predictions"], capture_output=True, text=True,
                                 check=True, timeout=120)
        cls.report = json.loads(run.stdout)

    def test_count_predictions_show_first_and_model_words_merge_for_the_same_context(self):
        counted = self.report["noProvider"]
        answer = self.report["answer"]
        self.assertEqual(len(counted), 3)
        self.assertEqual(answer["immediate"], counted)
        self.assertEqual(answer["merged"], ["Visit", "go", "see"])
        self.assertEqual(answer["republished"], answer["merged"])
        self.assertEqual(answer["contexts"], ["I would like to "], "Republishing must not ask again")

    def test_stale_result_is_dropped_and_the_latest_context_wins(self):
        stale = self.report["stale"]
        self.assertEqual(stale["contexts"], ["I would like to ", "I would like to go "])
        self.assertNotIn("stale", stale["bar"])
        self.assertIn("fresh", stale["bar"])

    def test_timeout_and_failure_keep_count_predictions(self):
        counted = self.report["noProvider"]
        self.assertEqual(self.report["timeout"], {"before": counted, "after": counted})
        self.assertEqual(self.report["failure"], counted)

    def test_restricted_fields_send_nothing(self):
        self.assertEqual(set(self.report["restrictedRequests"].values()), {0})
        self.assertEqual(len(self.report["restrictedRequests"]), 7)

    def test_context_is_the_current_paragraph_and_bounded(self):
        [context] = self.report["boundedContexts"]
        self.assertLessEqual(len(context), 200)
        self.assertNotIn("Secret", context)
        self.assertTrue(context.startswith("along"), "Starts at a whole word")
        self.assertTrue(context.endswith("river "))


if __name__ == "__main__":
    unittest.main()
