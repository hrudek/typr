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

    def only(self, predicate, index: int = 0) -> dict:
        """The fixture with one of its words, the `index`th that `predicate` accepts."""
        export = copy.deepcopy(self.fixture)
        export["words"] = [[w for w in export["words"] if predicate(w)][index]]
        return export

    def test_fixture_reproduces_what_the_keyboard_committed(self):
        report = self.report()
        self.assertEqual(report["exported"], 32)
        self.assertEqual(report["replayed"], 26)
        self.assertEqual(report["skipped"], {"learning state uncertain": 4, "swipe": 1, "tap without point": 1})
        reproduction = report["reproduction"]
        self.assertEqual((reproduction["commitMatches"], reproduction["commits"], reproduction["picked"]), (24, 24, 1))
        self.assertEqual((reproduction["literalMatches"], reproduction["literals"]), (26, 26))

    def test_reproduction_leads_the_report(self):
        lines = self.run_tool().stdout.splitlines()
        self.assertEqual(lines[1], "Reproduction: committed word matches the iPhone for 24/24 words, 100.0%")
        self.assertEqual(lines[2], "  not compared: 0 fixed by system spelling, 1 picked from the strip")

    def fresh_fixture(self) -> dict:
        fresh = self.dir / "fresh.json"
        made = subprocess.run([self.binary, "--make-fixture", str(fresh)], capture_output=True, text=True, timeout=60)
        self.assertEqual(made.returncode, 0, made.stderr)
        return json.loads(fresh.read_text())

    def test_a_fresh_fixture_reproduces_with_the_current_keyboard_code(self):
        reproduction = self.report(export=self.fresh_fixture())["reproduction"]
        self.assertEqual(reproduction["commitMatches"], reproduction["commits"])
        self.assertEqual(reproduction["literalMatches"], reproduction["literals"])

    def test_taps_and_sentence_context_choose_the_correction(self):
        export = self.fresh_fixture()
        start = next(i for i, w in enumerate(export["words"]) if w["meant"] == "most")
        export["words"] = export["words"][start:start + 5]
        export["learning"]["layouts"] = {}
        for word in export["words"]:
            word["commit"]["text"] = word["literal"]
        report = self.report("--show-words", export=export)
        self.assertEqual([line["replayed"] for line in report["words"]], ["of", "if", "In"])

    def test_an_edge_miss_types_the_likeliest_key_without_learned_taps(self):
        # `arou` and a tap 2 points inside m, towards n: n is typed as the tap lands.
        retyped = self.only(lambda w: w["meant"] == "around" and w["literal"] == "around")
        self.assertEqual([c["kind"] for c in retyped["words"][0]["corrections"]], ["backspace"])
        retyped["learning"]["layouts"] = {}
        report = self.report(export=retyped)
        self.assertEqual(report["reproduction"]["literalMatches"], 1)
        self.assertEqual(report["score"]["known"]["wordErrors"], 0)

    def test_edits_replay_in_order_up_to_the_first_boundary(self):
        # `around`: the last letter deleted and typed again.
        retyped = self.only(lambda w: w["meant"] == "around" and w["literal"] == "around")
        self.assertEqual([c["kind"] for c in retyped["words"][0]["corrections"]], ["backspace"])
        self.assertEqual(self.report(export=retyped)["reproduction"]["commitMatches"], 1)
        # `fine`, then the space deleted and the word retyped as `great`: the boundary saw `fine`.
        reopened = self.only(lambda w: w["meant"] == "great")
        self.assertEqual(reopened["words"][0]["commit"]["text"], "fine")
        report = self.report(export=reopened)
        self.assertEqual(report["reproduction"]["commitMatches"], 1)
        self.assertEqual(report["score"]["known"]["wordErrors"], 1)
        # Erased taps the log cannot place are not guessed.
        reopened["words"][0]["corrections"][1]["erased"] = []
        self.assertEqual(self.report(export=reopened)["skipped"], {"edits not replayable": 1})

    def test_earlier_learning_is_not_dated_from_the_log(self):
        # Kept before the log began; replaying without that keep would give `I've`.
        kept = self.only(lambda w: w["meant"] == "Ive")
        self.assertEqual(self.report(export=kept)["skipped"], {"learning state uncertain": 1})
        del kept["learning"]["kept"]["ive"]
        unkept = self.report("--show-words", export=kept)
        self.assertEqual([line["replayed"] for line in unkept["words"]], ["I've"])
        # Kept before the log began: not counted as an unknown word.
        brisolde = self.only(lambda w: w["meant"] == "Brisolde")
        self.assertEqual(self.report(export=brisolde)["skipped"], {"learning state uncertain": 1})
        # Imported names are protected the same way.
        kalvenor = self.only(lambda w: w["meant"] == "Kalvenor")
        self.assertEqual(self.report(export=kalvenor)["skipped"], {"learning state uncertain": 1})

    def test_only_the_words_own_log_adjusts_learning(self):
        # The first `teh` was autocorrected, so it was not kept or rejected then, although the export
        # keeps it after the undo. The later `teh` cannot be dated and is not compared.
        first = self.report(export=self.only(lambda w: w["meant"] == "teh"))
        self.assertEqual(first["reproduction"]["commitMatches"], 1)
        self.assertEqual(first["score"]["unknown"]["wordErrors"], 1)
        later = self.report(export=self.only(lambda w: w["meant"] == "teh", 1))
        self.assertEqual(later["skipped"], {"learning state uncertain": 1})

    def test_scores_against_the_meant_word(self):
        scores = self.report()["score"]
        # Misses: `fine` before the user rewrote it as `great`, and the undone `teh` -> `the`.
        # Unknown: the two compounds, `I` (not in the lists) and the first `teh`.
        self.assertEqual((scores["known"]["wordErrors"], scores["known"]["letterErrors"]), (1, 5))
        self.assertEqual((scores["unknown"]["wordErrors"], scores["unknown"]["letterErrors"]), (1, 2))
        self.assertEqual((scores["known"]["words"], scores["unknown"]["words"]), (22, 4))

    def test_words_are_listed_only_on_request(self):
        export = copy.deepcopy(self.fixture)
        word = next(w for w in export["words"] if w["meant"] == "quiet")
        word["commit"]["text"] = "quiets"
        self.assertNotIn("words", self.report(export=export))
        self.assertNotIn("quiet", self.run_tool(export=export).stdout)
        report = self.report("--show-words", export=export)
        self.assertEqual(report["reproduction"]["commitMatches"], 23)
        self.assertEqual([line["meant"] for line in report["words"]], ["teh", "quiet", "great"])

    def test_spelling_corrections_and_unavailable_picks_are_not_compared(self):
        export = copy.deepcopy(self.fixture)
        word = next(w for w in export["words"] if w["meant"] == "don't")
        word["commit"]["correction"] = "spelling"
        reproduction = self.report(export=export)["reproduction"]
        self.assertEqual((reproduction["systemSpelling"], reproduction["commits"]), (1, 23))
        picked = self.only(lambda w: (w.get("commit") or {}).get("kind") == "pick")
        picked["words"][0]["corrections"][0]["to"] = "arbitrary"
        self.assertEqual(self.report(export=picked)["skipped"], {"pick not offered": 1})

    def test_unusable_layouts_are_skipped(self):
        export = copy.deepcopy(self.fixture)
        export["words"][0]["layout"]["orientation"] = "sideways"
        export["words"][1]["layout"]["metrics"]["gap"] += 1
        del export["words"][2]["layout"]
        export["words"][3]["taps"] *= 50
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

    def test_prints_the_report_and_writes_nothing(self):
        empty = self.dir / "cwd"
        empty.mkdir(exist_ok=True)
        temporary = self.dir / "tmp"
        temporary.mkdir(exist_ok=True)
        temporary.chmod(0o500)
        self.addCleanup(temporary.chmod, 0o700)
        result = subprocess.run([self.binary, str(FIXTURE)], capture_output=True, text=True, cwd=empty,
                                env={**os.environ, "TMPDIR": str(temporary)}, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Vs meant word", result.stdout)
        self.assertEqual(list(empty.iterdir()), [])
        self.assertEqual(list(temporary.iterdir()), [])
        rejected = self.run_tool("--out", str(empty / "report.txt"), cwd=empty)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("Usage:", rejected.stderr)
        self.assertEqual(list(empty.iterdir()), [])

    def test_build_refuses_a_directory_in_a_checkout_or_through_a_symlink(self):
        result = subprocess.run(["bash", str(TOOL / "build.sh"), str(TOOL / "build")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("inside a Git checkout", result.stderr)
        link = self.dir / "build-link"
        link.unlink(missing_ok=True)
        link.symlink_to(self.dir)
        result = subprocess.run(["bash", str(TOOL / "build.sh"), str(link / "build")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("symbolic link", result.stderr)



if __name__ == "__main__":
    unittest.main()
