"""Stdlib-only offline compiler/reference regression tests; no raw inputs needed."""
import hashlib
import json
from pathlib import Path
import random
import runpy
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parent
API = runpy.run_path(str(ROOT/'tools/build_bigrams.py'))
BUILD = runpy.run_path(str(ROOT/'tools/build_d3b.py'))
DATA = ROOT.parents[1]/'TyprShared/FullKeyboard/WordData'


class ContextBuilderTests(unittest.TestCase):
    def fixture(self, seed=1, n=15):
        rng = random.Random(seed)
        words = ['word'+chr(97+i) for i in range(20)]
        sentences = [[rng.choice(words) for _ in range(6)] for _ in range(100)]
        values = API['train_model'](sentences, n, 3, 1)
        raw = API['compile_model']('de', *values[:5], n, 3, 1)
        return API['Model'](raw), raw, sentences

    def test_tokenization_barriers_unicode_and_german_sharp_s(self):
        self.assertEqual(API['tokenize']("A\u0308pfel, Öl und Straße! Don't I’m rock'n'roll. x42y", 'en'),
                         [['Äpfel', 'Öl', 'und', 'Straße'], ["Don't", "I'm", "rock'n'roll"], ['x', None, 'y']])
        self.assertEqual(list(API['events'](['I', 'have', None, 'cats'])), [('<s>', 'i'), ('i', 'have')])
        self.assertEqual(API['key']('STRAẞE'), 'straße')
        self.assertNotEqual(API['key']('Maße'), API['key']('Masse'))

    def test_deterministic_counts_and_normalized_discount(self):
        m, raw, sentences = self.fixture()
        reverse = API['train_model'](list(reversed(sentences)), 15, 3, 1)
        self.assertEqual(raw, API['compile_model']('de', *reverse[:5], 15, 3, 1))
        for h in m.vocab + ['unknown']:
            self.assertAlmostEqual(sum(m.prob(h, w) for w in m.vocab[1:]), 1, places=12)
        values = API['train_model']([['a', 'b']]*10 + [['a', 'c']]*5 + [['a', 'd']]*2, 4, 1, 3)
        model = API['Model'](API['compile_model']('de', *values[:5], 4, 1, 3))
        self.assertAlmostEqual(model.distribution('a')[0], 1-(10-.5)/17)
        self.assertGreater(model.prob('a', 'd'), 0)

    def test_corrupt_and_truncated_format(self):
        _, raw, _ = self.fixture()
        for corrupted in [raw[:20], raw[:-1], b'NOPE'+raw[4:], raw[:70]+b'x'+raw[71:]]:
            with self.assertRaises(ValueError):
                API['Model'](corrupted)
        bad = bytearray(raw)
        header = list(API['HEADER'].unpack_from(bad))
        bad[header[8]:header[8]+2] = b'\xff\xff'
        header[-2] = zlib.crc32(bad[64:])
        bad[:64] = API['HEADER'].pack(*header)
        with self.assertRaises(ValueError):
            API['Model'](bad)

    def test_exact_mixture_against_exhaustive_sort(self):
        de, _, _ = self.fixture(1, 15)
        en, _, _ = self.fixture(2, 17)
        union = set(de.vocab[1:]) | set(en.vocab[1:])
        for h in sorted(union) + ['unknown', '<s>']:
            for a in [0, .05, .2, .5, .8, .95, 1]:
                full = sorted(union, key=lambda w: (-(a*de.prob(h,w)+(1-a)*en.prob(h,w)), w.encode()))
                for suppressed in [frozenset(), frozenset(full[:2])]:
                    got = API['mixture_suggest'](de, en, h, a, suppress=suppressed)
                    self.assertEqual([w for w, _ in got], [w for w in full if w not in suppressed][:3])
        lm = API['LanguageMixer'](de, en)
        self.assertEqual(lm.consume('unknown'), .5)
        lm.consume('worda'); before = lm.state
        lm.sentence_boundary(); self.assertEqual(lm.state, .5*before)
        lm.reset(); self.assertEqual(lm.state, 0)

    def test_committed_packs_hashes_budget_vectors_and_credits(self):
        models = [API['Model']((DATA/f'keyboard-{l}.tbg').read_bytes()) for l in ['de', 'en']]
        self.assertLessEqual(sum(m.meta['compiled_bytes'] for m in models), 1048576)
        selected = json.loads((ROOT/'selected.json').read_text())
        hashes = {c['language']: c['binary']['sha256'] for c in selected}
        for l, m in zip(['de', 'en'], models):
            self.assertEqual(m.meta['sha256'], hashes[l])
        spec = json.loads((DATA/'swift-reference-vectors.json').read_text())
        state, sequence = None, None
        for v in spec['vectors']:
            if sequence != v['sequence']:
                sequence, state = v['sequence'], API['LanguageMixer'](*models)
            if v['event'] == 'consume':
                state.consume(v['consumed'])
                self.assertAlmostEqual(state.evidence(v['consumed']), v['evidence'], places=12)
            else:
                state.sentence_boundary()
            self.assertAlmostEqual(state.state, v['state'], places=12)
            self.assertAlmostEqual(state.weight_de(), v['weight_de'], places=12)
            for field, suppress in [('top3', frozenset()), ('top3_suppressed', API['SUGGESTION_SUPPRESS'])]:
                got = API['mixture_suggest'](*models, v['context'], state.weight_de(), suppress=suppress)
                self.assertEqual([w for w, _ in got], [w for w, _ in v[field]])
                for (_, p), (_, q) in zip(got, v[field]):
                    self.assertAlmostEqual(p, q, places=12)
        self.assertEqual(hashlib.sha256((ROOT/'credits/tatoeba-training-attribution.tsv.gz').read_bytes()).hexdigest(),
                         '8e440c5fc04efb41b3719c597af755afebf75a7089477d2af6c51cb6097a3376')
        self.assertEqual(len((DATA/'tatoeba-contributors.tsv').read_text().splitlines())-1, 7206)

    def test_unreviewed_input_rejection(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'input.txt'
            path.write_text('unreviewed input')
            with self.assertRaises(ValueError):
                API['load_corpus'](path, 'de')

    def test_cc0_fixture_is_heldout_and_has_no_training_overlap(self):
        fixture = json.loads((DATA/'context-heldout-cc0.json').read_text())
        self.assertEqual(fixture['license'], 'CC0 1.0 Universal')
        for sentences in fixture['sentences'].values():
            self.assertEqual(len(sentences), 64)
            for sentence in sentences:
                self.assertEqual(BUILD['partition'](BUILD['digest_sentence'](sentence)), 'test')


if __name__ == '__main__':
    unittest.main(verbosity=2)
