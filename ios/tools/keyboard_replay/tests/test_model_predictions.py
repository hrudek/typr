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
        cls.output = run.stdout + run.stderr

    def test_count_predictions_show_first_and_model_words_merge_for_the_same_context(self):
        counted = self.report["noProvider"]
        answer = self.report["answer"]
        self.assertEqual(len(counted), 3)
        self.assertEqual(answer["immediate"], counted)
        self.assertEqual(answer["merged"], ["the", "go", "visit"])
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

    def test_cloud_without_a_key_sends_nothing(self):
        cloud = self.report["cloud"]
        for case in ("noKey", "emptyKey", "secure"):
            self.assertEqual(cloud[case]["requests"], 0, case)
        self.assertEqual(cloud["noKey"]["bar"], self.report["noProvider"])

    def test_cloud_success_merges_and_sends_only_the_bounded_context(self):
        success = self.report["cloud"]["success"]
        self.assertEqual(success["bar"], ["the", "go", "see"])
        self.assertEqual(success["requests"], 1)
        self.assertEqual(success["sent"], ["I would like to "])
        self.assertEqual(success["model"], "claude-haiku-5-5")
        self.assertEqual(success["url"], "https://api.anthropic.com/v1/messages")
        self.assertTrue(success["keyHeader"])

    def test_cloud_failures_keep_local_predictions(self):
        for case in ("rateLimited", "overloaded", "malformed", "timeout"):
            result = self.report["cloud"][case]
            self.assertEqual(result["requests"], 1, case)
            self.assertEqual(result["bar"], self.report["noProvider"], case)

    def test_key_never_printed(self):
        self.assertNotIn("sk-ant-replay-key", self.output)

    def test_on_device_model_runs_only_when_available_for_every_enabled_language(self):
        self.assertEqual(self.report["onDevice"]["source"], {
            "none": "none", "unavailable": "none", "englishOnlyModel": "none",
            "englishOnlyModelEnglishKeyboard": "onDevice", "noLanguages": "none",
            "available": "onDevice", "cloudKey": "cloud",
        })

    def test_unavailable_or_refusing_on_device_model_keeps_count_predictions(self):
        counted = self.report["noProvider"]
        on_device = self.report["onDevice"]
        self.assertEqual(on_device["unavailable"], {"bar": counted, "calls": 0})
        self.assertEqual(on_device["refused"], {"bar": counted, "calls": 1})

    def test_on_device_words_merge_into_the_bar(self):
        answered = self.report["onDevice"]["answered"]
        self.assertEqual(answered["contexts"], ["I would like to "])
        self.assertEqual(answered["bar"], ["Visit", "see", "the"], "Model words first, likeliest in the centre")


if __name__ == "__main__":
    unittest.main()
