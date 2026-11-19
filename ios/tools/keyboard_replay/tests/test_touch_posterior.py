"""Checks the keyboard's touch densities against an independent Normal-Inverse-Wishart computation."""
from __future__ import annotations

import json
import math
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1]
PRIOR_SPREAD, PRIOR_WEIGHT, CENTER_PRIOR = 0.20, 10.0, 1.0


def moments(taps):
    n = len(taps)
    if n == 0:
        return 0, 0.0, 0.0, 0.0, 0.0, 0.0
    mx = sum(x for x, _ in taps) / n
    my = sum(y for _, y in taps) / n
    sxx = sum((x - mx) ** 2 for x, _ in taps)
    sxy = sum((x - mx) * (y - my) for x, y in taps)
    syy = sum((y - my) ** 2 for _, y in taps)
    return n, mx, my, sxx, sxy, syy


def spread(keys):
    weight = PRIOR_WEIGHT - 3
    xx = yy = weight * PRIOR_SPREAD ** 2
    xy, total = 0.0, weight
    for n, mx, my, sxx, sxy, syy in keys:
        shrink = CENTER_PRIOR * n / (CENTER_PRIOR + n)
        xx += sxx + shrink * mx * mx
        xy += sxy + shrink * mx * my
        yy += syy + shrink * my * my
        total += n
    return xx / total, xy / total, yy / total


def posterior(stats, pooled):
    n, mx, my, sxx, sxy, syy = stats
    kappa = CENTER_PRIOR + n
    dof = PRIOR_WEIGHT + n - 1
    shrink = CENTER_PRIOR * n / kappa
    scale = (kappa + 1) / (kappa * dof)
    weight = PRIOR_WEIGHT - 3
    return {
        "offsetX": n / kappa * mx, "offsetY": n / kappa * my, "degrees": dof,
        "xx": (weight * pooled[0] + sxx + shrink * mx * mx) * scale,
        "xy": (weight * pooled[1] + sxy + shrink * mx * my) * scale,
        "yy": (weight * pooled[2] + syy + shrink * my * my) * scale,
    }


def log_t(key, u, v):
    det = key["xx"] * key["yy"] - key["xy"] ** 2
    du, dv = u - key["offsetX"], v - key["offsetY"]
    distance = (key["yy"] * du * du - 2 * key["xy"] * du * dv + key["xx"] * dv * dv) / det
    dof = key["degrees"]
    return (math.lgamma(dof / 2 + 1) - math.lgamma(dof / 2) - math.log(dof * math.pi) - 0.5 * math.log(det)
            - (dof / 2 + 1) * math.log1p(distance / dof))


def aiming(key, kappa, drift):
    count, x, y = drift
    k = CENTER_PRIOR + count
    rescale = (k + 1) / k * kappa / (kappa + 1)
    return {"offsetX": (key["offsetX"] + count * x) / k, "offsetY": (key["offsetY"] + count * y) / k,
            "degrees": key["degrees"], "xx": key["xx"] * rescale, "xy": key["xy"] * rescale,
            "yy": key["yy"] * rescale}


def blend(keys, weights):
    mx = sum(w * k["offsetX"] for k, w in zip(keys, weights))
    my = sum(w * k["offsetY"] for k, w in zip(keys, weights))
    to_scale = (keys[0]["degrees"] - 2) / keys[0]["degrees"]
    return {"offsetX": mx, "offsetY": my, "degrees": keys[0]["degrees"],
            **{name: sum(w * (k[name] + to_scale * (k[a] - m1) * (k[b] - m2)) for k, w in zip(keys, weights))
               for name, a, b, m1, m2 in [("xx", "offsetX", "offsetX", mx, mx), ("xy", "offsetX", "offsetY", mx, my),
                                          ("yy", "offsetY", "offsetY", my, my)]}}


def aimed(taps):
    """iikb KeyTouches: all taps, ~30 and ~3 taps, weighted by how well each predicted every tap."""
    weights, lately, now = [1 / 3] * 3, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)

    def memories(n):
        stats = moments(taps[:n])
        everything = posterior(stats, spread([stats] if n else []))
        return [everything] + [aiming(everything, CENTER_PRIOR + n, d) for d in (lately, now)]

    def add(drift, x, y, memory):
        count = drift[0] * (1 - 1 / memory) + 1
        return count, drift[1] + (x - drift[1]) / count, drift[2] + (y - drift[2]) / count

    for i, (x, y) in enumerate(taps):
        odds = [w * math.exp(log_t(m, x, y)) for w, m in zip(weights, memories(i))]
        weights = [0.99 * o / sum(odds) + 0.01 / 3 for o in odds]
        lately, now = add(lately, x, y, 30), add(now, x, y, 3)
    return blend(memories(len(taps)), weights)


class TouchPosteriorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch = tempfile.TemporaryDirectory()
        binary = os.environ.get("KEYBOARD_REPLAY")
        if not binary:
            built = subprocess.run(["bash", str(TOOL / "build.sh"), str(Path(cls.scratch.name) / "build")],
                                   capture_output=True, text=True, check=True)
            binary = built.stdout.strip().splitlines()[-1]
        result = subprocess.run([binary, "--touch-posterior"], capture_output=True, text=True, timeout=60, check=True)
        cls.report = json.loads(result.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch.cleanup()

    def expected(self, n):
        stats = moments([tuple(t) for t in self.report["taps"][:n]])
        pooled = spread([stats] if n else [])
        f = aimed([tuple(t) for t in self.report["taps"][:n]])
        q = posterior(moments([]), pooled)
        if n:
            centre = posterior(stats, spread([]))
            q["offsetX"], q["offsetY"] = centre["offsetX"], centre["offsetY"]
        return f, q

    def assertKey(self, actual, expected):
        for name, value in [("offsetX", expected["offsetX"]), ("offsetY", expected["offsetY"]),
                            ("degrees", expected["degrees"]), ("sigmaX", math.sqrt(expected["xx"])),
                            ("sigmaY", math.sqrt(expected["yy"])), ("covarianceXY", expected["xy"])]:
            self.assertAlmostEqual(actual[name], value, places=10, msg=name)

    def test_golden_posteriors_after_0_1_3_10_labels(self):
        self.assertEqual([case["n"] for case in self.report["cases"]], [0, 1, 3, 10])
        for case in self.report["cases"]:
            with self.subTest(n=case["n"]):
                f, q = self.expected(case["n"])
                self.assertKey(case["f"], f)
                self.assertKey(case["q"], q)
                for probe, actual in zip(self.report["probes"], case["fDensity"]):
                    self.assertAlmostEqual(actual, log_t(f, *probe), places=9)
                for probe, actual in zip(self.report["probes"], case["qDensity"]):
                    self.assertAlmostEqual(actual, log_t(q, *probe), places=9)

    def test_displaced_taps_move_only_that_key_and_recover(self):
        grip = self.report["grip"]
        before, displaced, recovered = grip["before"], grip["displaced"], grip["recovered"]
        self.assertGreater(displaced["e"][0] - before["e"][0], 0.08)
        self.assertGreater(displaced["e"][1] - before["e"][1], 0.04)
        self.assertGreater(grip["weights"][2], grip["weights"][0], "now predicted the repeated miss best")
        for letter, offset in displaced.items():
            if letter != "e":
                self.assertAlmostEqual(offset[0], before[letter][0], places=12, msg=letter)
                self.assertAlmostEqual(offset[1], before[letter][1], places=12, msg=letter)
        self.assertLess(abs(recovered["e"][0] - before["e"][0]), 0.25 * (displaced["e"][0] - before["e"][0]))
        self.assertEqual(grip["nextScore"][0], grip["nextScore"][1], "a reloaded model scores the next tap the same")
        self.assertTrue(grip["otherLayoutUnchanged"])

    def test_untrained_keys_use_the_prior_not_a_wider_fallback(self):
        prior = self.report["cases"][0]["f"]
        self.assertAlmostEqual(prior["sigmaX"], math.sqrt(2 / 9 * 7 * 0.04), places=12)
        self.assertEqual(prior["degrees"], 9)

    def test_the_first_label_changes_every_key(self):
        cold, first = self.report["cases"][0], self.report["cases"][1]
        self.assertNotEqual(cold["fDensity"], first["fDensity"])
        self.assertNotEqual(cold["qDensity"], first["qDensity"], "unseen keys learn the pooled spread")

    def test_densities_do_not_depend_on_keyboard_size(self):
        for small, large in zip(self.report["cases"], self.report["scaled"]):
            for name in ["f", "q"]:
                for field, value in small[name].items():
                    self.assertAlmostEqual(large[name][field], value, places=9)
            for field in ["fDensity", "qDensity"]:
                for a, b in zip(small[field], large[field]):
                    self.assertAlmostEqual(a, b, places=9)

    def test_malformed_keys_are_dropped_or_bounded(self):
        malformed = self.report["malformed"]
        self.assertTrue(malformed["droppedNaNDegrees"])
        clamped = malformed["clamped"]
        self.assertTrue(all(math.isfinite(v) for v in clamped.values()))
        to_deviation = math.sqrt(clamped["degrees"] / (clamped["degrees"] - 2))
        self.assertGreaterEqual(min(clamped["sigmaX"], clamped["sigmaY"]) * to_deviation, 0.08 - 1e-12)
        self.assertLessEqual(max(clamped["sigmaX"], clamped["sigmaY"]) * to_deviation, 1.0 + 1e-12)
        self.assertTrue(math.isfinite(malformed["farDensity"]))


if __name__ == "__main__":
    unittest.main()
