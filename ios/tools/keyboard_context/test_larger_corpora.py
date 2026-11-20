"""Stdlib regression tests; python3 -I -m unittest discover -s <this-dir>."""
import gzip
import io
import json
from pathlib import Path
import runpy
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest

API = runpy.run_path(str(Path(__file__).parent/'tools/larger_corpora.py'))


class LargerCorporaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self, members):
        path = self.root/'input.tar.gz'
        with tarfile.open(path, 'w:gz') as f:
            for name, data, kind in members:
                m = tarfile.TarInfo(name)
                m.type = kind
                m.size = len(data) if kind == tarfile.REGTYPE else 0
                f.addfile(m, io.BytesIO(data) if m.size else None)
        return path

    def testArchivesNeverExtractOrExecute(self):
        path = self.archive([('../escape.py', b'raise Exception()', tarfile.REGTYPE),
            ('x/import.sql', b'drop table x;', tarfile.REGTYPE),
            ('x/fake-sentences.txt', b'', tarfile.SYMTYPE),
            ('../../safe-sentences.txt', b'1\tHello world.\n', tarfile.REGTYPE)])
        self.assertEqual(list(API['lines'](path, 'leipzig')), ['Hello world.\n'])
        self.assertFalse((self.root.parent/'escape.py').exists())
        self.assertEqual(list(self.root.iterdir()), [path])

    def testUnexpectedSchemaFailsClosed(self):
        path = self.archive([('x-sentences.txt', b'not TSV\n', tarfile.REGTYPE)])
        with self.assertRaises(ValueError):
            list(API['lines'](path, 'leipzig'))

    def testMissingAndMultipleSentenceMembersFail(self):
        path = self.archive([('import.sql', b'ignored', tarfile.REGTYPE)])
        with self.assertRaises(ValueError):
            list(API['lines'](path, 'leipzig'))
        path = self.archive([('a-sentences.txt', b'1\tHello.\n', tarfile.REGTYPE),
                             ('b-sentences.txt', b'1\tWorld.\n', tarfile.REGTYPE)])
        with self.assertRaises(ValueError):
            list(API['lines'](path, 'leipzig'))

    def testCanonicalDedupeAndPartitionMatchRoundOne(self):
        round_one = runpy.run_path(str(Path(__file__).parent/'tools/build_d3b.py'))
        one = API['digest'](['HELLO', 'Straße', None, 'World'])
        self.assertEqual(one, API['digest'](['hello', 'straße', None, 'world']))
        self.assertNotEqual(one, API['digest'](['hello', 'strasse', None, 'world']))
        for i in range(100):
            d = API['digest']([str(i), 'Wort'])
            self.assertEqual(d, round_one['digest_sentence']([str(i), 'Wort']))
            self.assertEqual(API['partition'](d), round_one['partition'](d))

    def testHashAndExclusiveCacheGuards(self):
        source = self.root/'source.gz'
        with gzip.open(source, 'wt') as f:
            f.write('Hello world.\n')
        spec = self.root/'spec.json'
        spec.write_text(json.dumps([dict(path=str(source), sha256='wrong')]))
        cache = self.root/'cache.sqlite'
        with self.assertRaises(ValueError):
            API['prepare'](spec, cache)
        with self.assertRaises(FileExistsError):
            API['prepare'](spec, cache)

    def testValidPreparationHonorsLineLimitAndDeduplicates(self):
        import hashlib
        path = self.root/'source.gz'
        with gzip.open(path, 'wt') as f:
            f.write('Hello world.\nHELLO WORLD.\nExcluded third line.\n')
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        spec = self.root/'spec.json'
        spec.write_text(json.dumps([dict(path=str(path), sha256=sha, kind='opus',
            language='en', source='opus', max_lines=2)]))
        cache = self.root/'cache.sqlite'
        API['prepare'](spec, cache)
        with sqlite3.connect(cache) as db:
            rows = db.execute('SELECT digest,part,tokens FROM sentences').fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(rows[0][2]), ['Hello', 'world'])
        self.assertEqual(rows[0][1], API['partition'](rows[0][0]))

    def testEvaluatorCLIReplaysCurrentReferenceAndComparesSamePacks(self):
        root = Path(__file__).parent
        data = root.parents[1]/'TyprShared/FullKeyboard/WordData'
        old, cache = self.root/'old.sqlite', self.root/'new.sqlite'
        with sqlite3.connect(old) as db:
            db.execute('CREATE TABLE sentences(lang,digest,part,mask,tokens,PRIMARY KEY(lang,digest)) WITHOUT ROWID')
        with sqlite3.connect(cache) as db:
            db.execute('CREATE TABLE sentences(lang,digest,part,source,tokens,PRIMARY KEY(lang,digest,source)) WITHOUT ROWID')
        for lang in ('de', 'en'):
            shutil.copyfile(data/f'keyboard-{lang}.tbg', self.root/f'keyboard-{lang}.tbg')
        command = [sys.executable, '-I', str(root/'tools/evaluate_r2.py'),
            str(root/'tools/larger_corpora.py'), str(cache), str(old), str(data),
            str(self.root), str(data/'context-heldout-cc0.json'), str(data/'swift-reference-vectors.json')]
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        result = json.loads((self.root/'evaluation.json').read_text())
        self.assertEqual(result['de_round1_64']['before'], result['de_round1_64']['after'])
        self.assertEqual(json.loads((self.root/'swift-reference-vectors.json').read_text()),
                         json.loads((data/'swift-reference-vectors.json').read_text()))

    def testOldAndNewDedupWithStableDisplayRepresentative(self):
        old, new = self.root/'old.sqlite', self.root/'new.sqlite'
        db = sqlite3.connect(old)
        db.execute('CREATE TABLE sentences(lang,digest,part,mask,tokens,PRIMARY KEY(lang,digest)) WITHOUT ROWID')
        d = API['digest'](['old', 'sentence'])
        db.execute('INSERT INTO sentences VALUES(?,?,?,?,?)', ('en', d, 'train', 1, '["old","sentence"]'))
        db.commit(); db.close()
        db = sqlite3.connect(new)
        db.execute('CREATE TABLE sentences(lang,digest,part,source,tokens,PRIMARY KEY(lang,digest,source)) WITHOUT ROWID')
        db.execute('INSERT INTO sentences VALUES(?,?,?,?,?)', ('en', d, 'train', 'wiki', '["OLD","sentence"]'))
        d = API['digest'](['new', 'sentence'])
        for source, text in [('wiki','NEW'), ('news','New'), ('opus','new')]:
            db.execute('INSERT INTO sentences VALUES(?,?,?,?,?)', ('en',d,'train',source,json.dumps([text,'sentence'])))
        db.commit(); db.close()
        sentences = API['Sentences'](new, old, 'en', 'train', ['opus','wiki','news'])
        self.assertEqual(list(sentences), [['old','sentence'],['New','sentence']])
        self.assertEqual(list(sentences), list(sentences))

    def testCreditsOnlyCopyValidatedWikipediaLinks(self):
        credits = runpy.run_path(str(Path(__file__).parent/'tools/corpus_credits.py'))
        path = self.archive([('import.sql', b'ignored', tarfile.REGTYPE),
            ('x-sources.txt', b'1\thttp://en.wikipedia.org/wiki/Test\t2016-01-01\n', tarfile.REGTYPE)])
        output = self.root/'credits.gz'
        credits['collect'](path, output)
        self.assertEqual(gzip.decompress(output.read_bytes()), b'1\thttp://en.wikipedia.org/wiki/Test\t2016-01-01\n')
        with self.assertRaises(FileExistsError):
            credits['collect'](path, output)
        second = self.root/'second.gz'
        credits['collect'](path, second)
        self.assertEqual(output.read_bytes(), second.read_bytes())

    def testCreditsRejectUnexpectedMetadata(self):
        credits = runpy.run_path(str(Path(__file__).parent/'tools/corpus_credits.py'))
        path = self.archive([('x-sources.txt', b'1\thttp://other.org\t2016\n', tarfile.REGTYPE)])
        with self.assertRaises(ValueError):
            credits['collect'](path, self.root/'credits.gz')

    def testPublicNewFixtureIsOnlyTestPartitionAndDisjointFromOld(self):
        root = Path(__file__).parent
        data = root.parents[1]/'TyprShared/FullKeyboard/WordData'
        old = json.loads((data/'context-heldout-cc0.json').read_text())['sentences']
        new = json.loads((data/'context-heldout-r2.json').read_text())['sentences']
        old_digests = {API['digest'](s) for sentences in old.values() for s in sentences}
        for sentences in new.values():
            self.assertEqual(len(sentences), 64)
            for sentence in sentences:
                d = API['digest'](sentence)
                self.assertEqual(API['partition'](d), 'test')
                self.assertNotIn(d, old_digests)

    def testEmptyAndKnownMetrics(self):
        class Model:
            def suggest(self, context):
                return [('a', 'a', .6), ('b', 'b', .3), ('c', 'c', .1)]
        self.assertEqual(API['measure'](Model(), {}), dict(pairs=0, recall1=0, recall3=0))
        got = API['measure'](Model(), {('h','a'): 1, ('h','b'): 2, ('h','d'): 1})
        self.assertEqual(got, dict(pairs=4, recall1=.25, recall3=.75))


if __name__ == '__main__':
    unittest.main()
