"""Builds keyboard-replay (or uses $KEYBOARD_REPLAY) and checks it on the synthetic fixture."""
from __future__ import annotations

import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1]
FIXTURE = TOOL / "fixture" / "synthetic.json"


class ReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.scratch.name)
        binary = os.environ.get("KEYBOARD_REPLAY")
        if not binary:
            built = subprocess.run(["bash", str(TOOL / "build.sh"), str(cls.dir / "build")],
                                   capture_output=True, text=True, check=True)
            binary = built.stdout.strip().splitlines()[-1]
        cls.binary = binary
        cls.fixture = json.loads(FIXTURE.read_text())

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch.cleanup()

    def run_tool(self, *args: str, export: dict | None = None, cwd: Path | None = None):
        path = FIXTURE
        if export is not None:
            path = self.dir / "export.json"
            path.write_text(json.dumps(export))
        return subprocess.run([self.binary, str(path), *args], capture_output=True, text=True,
                              cwd=cwd or self.dir, timeout=120)

    def report(self, *args: str, export: dict | None = None) -> dict:
        result = self.run_tool("--json", *args, export=export)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_fixture_reproduces_what_the_keyboard_committed(self):
        report = self.report()
        self.assertEqual(report["exported"], 26)
        self.assertEqual(report["replayed"], 24)
        self.assertEqual(report["skipped"], {"swipe": 1, "tap without point": 1})
        reproduction = report["reproduction"]["standard"]
        self.assertEqual(reproduction["literalMatches"], reproduction["literals"])
        self.assertEqual(reproduction["literals"], 24)
        self.assertEqual(reproduction["commitMatches"], reproduction["commits"])
        self.assertEqual(reproduction["commits"], 21)
        self.assertEqual(reproduction["commitsNotComparable"], 2)

    def test_reproduction_leads_the_report(self):
        lines = self.run_tool().stdout.splitlines()
        self.assertEqual(lines[1], "Reproduction (Standard): committed word matches the iPhone for 21/21 words, 100.0%")
        self.assertEqual(lines[2], "  not compared: 0 fixed by system spelling, 2 picked or edited after the separator")

    def test_a_fresh_fixture_reproduces_with_the_current_keyboard_code(self):
        fresh = self.dir / "fresh.json"
        made = subprocess.run([self.binary, "--make-fixture", str(fresh)], capture_output=True, text=True, timeout=60)
        self.assertEqual(made.returncode, 0, made.stderr)
        reproduction = self.report(export=json.loads(fresh.read_text()))["reproduction"]["standard"]
        self.assertEqual(reproduction["commitMatches"], reproduction["commits"])
        self.assertEqual(reproduction["literalMatches"], reproduction["literals"])

    def test_imported_words_are_protected_as_on_the_iphone(self):
        export = copy.deepcopy(self.fixture)
        export["protectedWords"] = []
        report = self.report("--show-words", export=export)
        self.assertEqual(report["reproduction"]["standard"]["commitMatches"], 20)
        self.assertEqual([(line["meant"], line["replayed"]["standard"]) for line in report["words"]], [("Ive", "I've")])

    def test_learning_from_an_undo_applies_only_after_it(self):
        export = copy.deepcopy(self.fixture)
        first = next(w for w in export["words"] if w["meant"] == "teh")
        self.assertEqual(first["commit"]["text"], "the")
        first["corrections"] = []
        report = self.report("--show-words", export=export)
        self.assertEqual([(line["meant"], line["replayed"]["standard"]) for line in report["words"]], [("teh", "teh")])

    def test_scores_both_settings_against_the_meant_word(self):
        report = self.report()
        # Misses: the undone `teh` -> `the` and the edge miss `aroumd`, fixed on the iPhone with a pick.
        # Unknown: the two compounds, Brisolde (nobody taught it), `I` (not in the lists) and the first
        # `teh`, typed before the undo kept it.
        for setting in ["standard", "adaptive"]:
            scores = report["variants"][setting]
            self.assertEqual(scores["known"]["wordErrors"], 1)
            self.assertEqual(scores["known"]["letterErrors"], 1)
            self.assertEqual(scores["unknown"]["wordErrors"], 1)
            self.assertEqual(scores["unknown"]["letterErrors"], 2)
            self.assertEqual(scores["unknown"]["words"], 5)
            self.assertEqual(scores["known"]["words"] + scores["unknown"]["words"], 24)
        self.assertEqual(report["changes"], {"standard->adaptive": {"fixed": {"known": 0, "unknown": 0},
                                                                    "broken": {"known": 0, "unknown": 0}}})

    def test_words_are_listed_only_on_request(self):
        export = copy.deepcopy(self.fixture)
        word = next(w for w in export["words"] if w["meant"] == "Kalvenor")
        word["commit"]["text"] = "Kalvenors"
        self.assertNotIn("words", self.report(export=export))
        self.assertNotIn("Kalvenor", self.run_tool(export=export).stdout)
        report = self.report("--show-words", export=export)
        self.assertEqual(report["reproduction"]["standard"]["commitMatches"], 20)
        self.assertEqual([line["meant"] for line in report["words"]], ["Kalvenor"])

    def test_spelling_corrections_are_not_compared(self):
        export = copy.deepcopy(self.fixture)
        word = next(w for w in export["words"] if w["meant"] == "don't")
        word["commit"]["correction"] = "spelling"
        reproduction = self.report(export=export)["reproduction"]["standard"]
        self.assertEqual(reproduction["systemSpelling"], 1)
        self.assertEqual(reproduction["commits"], 20)

    def test_unusable_layouts_are_skipped(self):
        export = copy.deepcopy(self.fixture)
        export["words"][0]["layout"]["orientation"] = "sideways"
        export["words"][1]["layout"]["metrics"]["gap"] += 1
        del export["words"][2]["layout"]
        export["words"][3]["taps"] *= 30
        report = self.report(export=export)
        self.assertEqual(report["skipped"]["over bounds"], 1)
        self.assertEqual(report["skipped"]["unknown layout"], 2)
        self.assertEqual(report["skipped"]["layout drift"], 1)

    def test_rejects_other_files(self):
        cases = {
            "not json": "{",
            "not an object": "[]",
            "other format": json.dumps({"format": "x", "version": 1}),
            "older version": json.dumps({**self.fixture, "version": 1}),
            "newer version": json.dumps({**self.fixture, "version": 3}),
            "invalid learning": json.dumps({**self.fixture, "learning": {**self.fixture["learning"], "schemaVersion": 99}}),
            "bad word": json.dumps({**self.fixture, "words": [{"at": "yesterday"}]}),
        }
        for name, text in cases.items():
            with self.subTest(name):
                path = self.dir / "bad.json"
                path.write_text(text)
                result = subprocess.run([self.binary, str(path)], capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr.startswith("keyboard-replay: "), result.stderr)

    def test_writes_nothing_by_default_and_refuses_output_in_a_checkout(self):
        empty = self.dir / "cwd"
        empty.mkdir(exist_ok=True)
        self.assertEqual(self.run_tool(cwd=empty).returncode, 0)
        self.assertEqual(list(empty.iterdir()), [])

        checkout = self.dir / "checkout"
        (checkout / ".git").mkdir(parents=True, exist_ok=True)
        link = self.dir / "link"
        link.unlink(missing_ok=True)
        link.symlink_to(checkout)
        for out in [checkout / "report.txt", checkout / "sub" / "report.txt", link / "report.txt"]:
            with self.subTest(str(out)):
                result = self.run_tool("--out", str(out))
                self.assertEqual(result.returncode, 1)
                self.assertIn("inside a Git checkout", result.stderr)
                self.assertFalse(out.exists())

        out = self.dir / "report.txt"
        self.assertEqual(self.run_tool("--out", str(out)).returncode, 0)
        self.assertIn("Standard vs meant word", out.read_text())
        self.assertEqual(out.stat().st_mode & 0o777, 0o600)

    def test_build_refuses_a_directory_in_a_checkout(self):
        result = subprocess.run(["bash", str(TOOL / "build.sh"), str(TOOL / "build")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("inside a Git checkout", result.stderr)


if __name__ == "__main__":
    unittest.main()
