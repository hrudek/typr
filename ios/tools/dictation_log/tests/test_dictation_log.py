import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from archive import Invalid, canonical, read_export, validate_entry
from cli import main
from report import edit_metric, fingerprint, make_report, settings
from store import Store, outside_checkout

ARCHIVE = "77777777-7777-7777-7777-777777777777"
ENTRY = "11111111-1111-1111-1111-111111111111"
SECRET = "SyntheticPrivateNameNeverPrint"


def text(value):
    return {"text": value, "truncated": False, "originalUTF8Bytes": len(value.encode()), "wordCount": len(value.split())}


def entry(**changes):
    value = {"id": ENTRY, "schemaVersion": 2, "revision": 1, "status": "finished", "rating": "bad",
             "context": {"createdAt": "2026-11-08T12:00:00Z", "appVersion": "2.0", "appBuild": "164.1",
                         "speechEngine": "synthetic", "speechLanguage": "de-DE", "style": "Polished",
                         "cleanupPath": "typr", "vocabularyEnabled": True, "upstreamCleanupEnabled": False,
                         "typrCleanupEnabled": True, "vocabularySnapshot": text(SECRET)},
             "promptRevision": "synthetic-v1", "guardRevision": "synthetic-v1", "issues": ["misheard"],
             "recognized": text(SECRET), "finalText": text("a c"), "expectedText": text("a b"),
             "asrMilliseconds": 10, "stopToFinalMilliseconds": 20}
    value.update(changes)
    return value


def envelope(entries=None, **changes):
    value = {"format": "typr.dictation-log", "exportVersion": 1, "dateEncoding": "ISO-8601 UTC",
             "exportedAt": "2026-11-08T12:30:00Z", "archiveID": ARCHIVE, "appBuild": "164.1",
             "unreadableFiles": 0, "legacyMigrationPending": False, "entries": entries if entries is not None else [entry()]}
    value.update(changes)
    return value


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = self.root / "private"
        self.input = self.root / "input.json"

    def tearDown(self):
        self.tmp.cleanup()

    def export(self, value=None):
        self.input.write_text(json.dumps(value if value is not None else envelope()))
        return read_export(self.input)

    def put(self, value=None):
        export = self.export(value)
        with Store(self.store, create=True) as store:
            return store.import_export(export)

    def report(self, show_text=False):
        with Store(self.store) as store:
            return make_report(store, show_text=show_text)

    def test_revision_dedupe_whole_entry_no_feedback_merge(self):
        self.assertEqual(self.put()["inserted"], 1)
        self.assertEqual(self.put()["unchanged"], 1)
        updated = entry(revision=2, rating="good", expectedText=None, finalText=text("new stage"))
        self.assertEqual(self.put(envelope([updated]))["updated"], 1)
        self.assertEqual(self.put()["older"], 1)
        with Store(self.store) as store:
            stored = list(store.records())[0][2]
        self.assertEqual(stored, updated)
        self.assertEqual(self.put(envelope([dict(updated, rating="bad")]))["conflicts"], 1)
        self.assertEqual(self.report()["summary"]["ratings"]["good"], 1)

    def test_archive_lineage_separates_identical_entry_ids(self):
        self.put(); self.put(envelope(archiveID=str(uuid.uuid4())))
        self.assertEqual(self.report()["summary"]["entries"], 2)

    def test_canonical_equal_revision_ignores_key_order(self):
        self.put()
        reversed_entry = dict(reversed(list(entry().items())))
        self.assertEqual(self.put(envelope([reversed_entry]))["unchanged"], 1)

    def test_absence_never_deletes_and_scope_stays_unknown(self):
        self.put(envelope([entry(), entry(id=str(uuid.uuid4()))]))
        self.put()
        archive = self.report()["archives"][0]
        self.assertEqual(archive["retainedEntries"], 2)
        self.assertEqual(archive["absentFromLatestImport"], 1)
        self.assertIsNone(archive["absentFromLastWholeExport"])
        self.assertEqual(archive["latestImportScope"], "unknown")

    def test_explicit_future_whole_scope_is_not_inferred(self):
        self.put(envelope([entry(), entry(id=str(uuid.uuid4()))]))
        self.put(envelope(scope="all"))
        self.assertEqual(self.report()["archives"][0]["absentFromLastWholeExport"], 1)

    def test_raw_bytes_preserved_and_envelope_warnings_reported(self):
        export = self.export(envelope(unreadableFiles=2, legacyMigrationPending=True))
        with Store(self.store, create=True) as store:
            result = store.import_export(export)
        self.assertEqual(len(result["warnings"]), 4)
        blob = self.store / "exports" / (hashlib.sha256(export.raw).hexdigest() + ".json")
        self.assertEqual(blob.read_bytes(), export.raw)
        self.assertIn("export reports pending legacy migration", self.report()["warnings"])

    def test_future_entry_preserves_raw_but_is_skipped(self):
        result = self.put(envelope([entry(schemaVersion=999), entry(id=str(uuid.uuid4()))]))
        self.assertEqual((result["skipped"], result["inserted"]), (1, 1))
        self.assertTrue(any("unsupported entry schema" in line for line in result["warnings"]))

    def test_unknown_format_version_and_bad_fields_leave_prior_store(self):
        self.put()
        for changes in ({"format": "future"}, {"exportVersion": 2}, {"exportVersion": True},
                        {"entries": [entry(revision=0)]}, {"exportedAt": "2026-01-01T12:00:00"},
                        {"entries": [entry(context={"createdAt": "private-invalid"})]}):
            with self.subTest(changes=changes):
                with self.assertRaises(Invalid):
                    self.put(envelope(**changes))
        self.assertEqual(self.report()["summary"]["entries"], 1)

    def test_truncated_invalid_duplicate_nonfinite_json_rejected(self):
        for raw in ('{"secret":', '{"format":1,"format":2}', '{"value":NaN}', '{"value":"\\ud800"}'):
            self.input.write_text(raw)
            with self.assertRaises((Invalid, ValueError)):
                read_export(self.input)

    def test_size_limit_before_json_decode(self):
        self.input.write_bytes(b"x" * 50)
        with mock.patch("archive.MAX_INPUT_BYTES", 10), self.assertRaises(Invalid):
            read_export(self.input)

    def test_checkout_directory_file_and_symlink_rejected(self):
        for kind in ("directory", "file"):
            checkout = self.root / kind; checkout.mkdir()
            git = checkout / ".git"
            git.mkdir() if kind == "directory" else git.write_text("gitdir: elsewhere")
            with self.assertRaises(Invalid):
                outside_checkout(checkout / "private")
        link = self.root / "link"; link.symlink_to(self.root / "directory", target_is_directory=True)
        with self.assertRaises(Invalid):
            outside_checkout(link / "private")

    def test_sqlite_failure_rolls_back_all_entries_and_import_metadata(self):
        self.put()
        export = self.export(envelope([entry(revision=2), entry(id=str(uuid.uuid4()))]))
        with Store(self.store) as store:
            def crash():
                raise OSError("simulated before commit")
            with self.assertRaises(OSError):
                store.import_export(export, before_commit=crash)
            rows = list(store.records())
            self.assertEqual((len(rows), rows[0][2]["revision"]), (1, 1))
            self.assertEqual(len(list(store.imports())), 1)

    def test_atomic_blob_replace_failure_keeps_database_and_no_temporary_files(self):
        self.put()
        export = self.export(envelope([entry(revision=2)]))
        with Store(self.store) as store, mock.patch("store.os.replace", side_effect=OSError("synthetic")):
            with self.assertRaises(OSError):
                store.import_export(export)
        self.assertEqual(self.report()["summary"]["entries"], 1)
        self.assertFalse(list((self.store / "exports").glob(".tmp-*")))

    def test_private_permissions_including_live_journal(self):
        self.put()
        with Store(self.store) as store:
            store.connection.execute("UPDATE entries SET revision=revision+1")
            for path in self.store.rglob("*"):
                expected = 0o700 if path.is_dir() else 0o600
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), expected, path.name)
            store.connection.rollback()
        self.assertEqual(stat.S_IMODE(self.store.stat().st_mode), 0o700)

    def test_hmac_stable_within_store_and_unlinkable_across_stores(self):
        self.put()
        first = self.report()["groups"][0]["settingsHMAC"]
        self.assertEqual(self.report()["groups"][0]["settingsHMAC"], first)
        export = self.export()
        with Store(self.root / "another", create=True) as store:
            store.import_export(export)
            self.assertNotEqual(make_report(store)["groups"][0]["settingsHMAC"], first)

    def test_unknown_is_not_false_and_all_config_components_change_fingerprint(self):
        value = entry()
        baseline = settings(value, b"x" * 32)
        for field in ("speechEngine", "speechLanguage", "style", "cleanupPath", "vocabularyEnabled",
                      "upstreamCleanupEnabled", "typrCleanupEnabled", "vocabularySnapshot"):
            changed = copy.deepcopy(value); changed["context"].pop(field)
            self.assertNotEqual(settings(changed, b"x" * 32), baseline)
        for field in ("promptRevision", "guardRevision"):
            changed = copy.deepcopy(value); changed[field] = "another"
            self.assertNotEqual(fingerprint(b"x" * 32, settings(changed, b"x" * 32)), fingerprint(b"x" * 32, baseline))
        unknown = copy.deepcopy(value); unknown["context"].pop("upstreamCleanupEnabled")
        self.assertEqual(settings(unknown, b"x" * 32)["upstreamCleanupEnabled"], "unknown")
        self.assertIs(settings(value, b"x" * 32)["upstreamCleanupEnabled"], False)

    def test_vocabulary_terms_list_is_validated_private_and_fingerprinted(self):
        value = entry(); value["context"]["vocabularyTerms"] = [SECRET, "herdr pane"]
        value["context"].pop("vocabularySnapshot")
        self.put(envelope([value]))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(["--store", str(self.store), "report", "--json"]), 0)
        self.assertNotIn(SECRET, output.getvalue())
        rows = self.report(show_text=True)["text"]
        self.assertEqual(rows[0]["vocabularyTerms"], [SECRET, "herdr pane"])
        baseline = settings(value, b"x" * 32)
        changed = copy.deepcopy(value); changed["context"]["vocabularyTerms"] = ["other"]
        self.assertNotEqual(settings(changed, b"x" * 32), baseline)
        inactive = copy.deepcopy(value); inactive["context"]["vocabularyEnabled"] = False
        other = copy.deepcopy(inactive); other["context"]["vocabularyTerms"] = ["other"]
        self.assertEqual(settings(inactive, b"x" * 32)["activeVocabulary"],
                         settings(other, b"x" * 32)["activeVocabulary"])
        unknown = copy.deepcopy(value); unknown["context"].pop("vocabularyEnabled")
        self.assertEqual(settings(unknown, b"x" * 32)["activeVocabulary"], "unknown")
        decomposed = copy.deepcopy(value)  # 64 graphemes, 128 code points: valid in the app.
        decomposed["context"]["vocabularyTerms"] = ["e\u0301" * 64, "\U0001F468\u200D\U0001F469\u200D\U0001F467" * 64]
        validate_entry(decomposed, "entry")
        for bad in ("not a list", [1], ["x" * 4001], ["t"] * 101):
            broken = copy.deepcopy(value); broken["context"]["vocabularyTerms"] = bad
            with self.assertRaises(Invalid):
                validate_entry(broken, "entry")

    def test_default_output_and_errors_never_print_synthetic_private_text(self):
        value = entry(rating=SECRET, issues=[SECRET]); value["context"]["appBuild"] = SECRET
        self.put(envelope([value]))
        for command in (["report"], ["report", "--json"]):
            output, errors = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(main(["--store", str(self.store), *command]), 0)
            self.assertNotIn(SECRET, output.getvalue() + errors.getvalue())
        self.input.write_text(json.dumps(envelope([entry(revision=SECRET)])))
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(main(["--store", str(self.store), "import", str(self.input)]), 2)
        self.assertNotIn(SECRET, output.getvalue() + errors.getvalue())
        self.assertIn(SECRET, canonical(self.report(show_text=True)))

    def test_ratings_references_timings_and_metrics_are_separate(self):
        self.put(envelope([entry(), entry(id=str(uuid.uuid4()), rating="good", expectedText=None, asrMilliseconds=None)]))
        result = self.report()["summary"]
        self.assertEqual(result["referencesSupplied"], 1)
        self.assertEqual(result["goodWithoutReference"], 1)
        self.assertEqual(result["ratingCoverage"], 1)
        self.assertEqual(result["timings"]["asrMilliseconds"], {"count": 1, "missing": 1, "medianMilliseconds": 10})
        self.assertEqual(result["finalOutputReferenceMetrics"]["median"], 0.5)
        self.assertEqual(result["finalOutputReferenceMetrics"]["count"], 1)

    def test_metric_exclusions_and_nfc_punctuation_contract(self):
        self.assertEqual(edit_metric(entry(finalText=text("cafe\u0301"), expectedText=text("café")))[1]["edits"], 0)
        self.assertEqual(edit_metric(entry(finalText=text("hello,"), expectedText=text("hello")))[1]["edits"], 1)
        for changes, reason in [({"status": "interrupted"}, "not_finished"), ({"expectedText": None}, "missing_final_or_reference"),
                                ({"expectedText": text("")}, "empty_reference")]:
            self.assertEqual(edit_metric(entry(**changes))[0], reason)
        truncated = dict(text("prefix"), truncated=True, originalUTF8Bytes=9000)
        self.assertEqual(edit_metric(entry(expectedText=truncated))[0], "truncated")
        with mock.patch("report.MAX_METRIC_TOKENS", 1):
            self.assertEqual(edit_metric(entry())[0], "token_limit")

    def test_foreign_directory_unchanged_and_explicit_empty_directory_accepted(self):
        foreign = self.root / "documents"; foreign.mkdir(mode=0o755)
        content = foreign / "unrelated.txt"; content.write_text("untouched")
        before = stat.S_IMODE(foreign.stat().st_mode)
        with self.assertRaises(Invalid):
            with Store(foreign, create=True):
                self.fail("must refuse before mutation")
        self.assertEqual(stat.S_IMODE(foreign.stat().st_mode), before)
        self.assertEqual(list(foreign.iterdir()), [content])
        self.assertEqual(content.read_text(), "untouched")
        empty = self.root / "empty"; empty.mkdir()
        with Store(empty, create=True) as store:
            self.assertEqual(list(store.records()), [])

    def test_missing_legacy_revision_normalizes_to_one_without_inventing_fields(self):
        legacy = entry(schemaVersion=1); legacy.pop("revision")
        self.assertEqual(self.put(envelope([legacy]))["inserted"], 1)
        with Store(self.store) as store:
            self.assertNotIn("revision", list(store.records())[0][2])
        self.assertEqual(self.put(envelope([entry(revision=2)]))["updated"], 1)

    def test_numeric_prefix_private_build_and_null_build_do_not_leak(self):
        value = entry(); value["context"]["appBuild"] = "123" + SECRET; value["context"]["appVersion"] = None
        self.put(envelope([value]))
        build = self.report()["groups"][0]["build"]
        self.assertTrue(build.startswith("unknown/"))
        self.assertNotIn(SECRET, canonical(self.report()))

    def test_lock_timeout_and_exact_metric_boundaries(self):
        self.put()
        with Store(self.store) as outer:
            with mock.patch("store.time.monotonic", side_effect=[0, 3]), self.assertRaises(Invalid):
                with Store(self.store):
                    self.fail("must not bypass another operation's lock")
            self.assertEqual(len(list(outer.records())), 1)
        thousand = text("x " * 1000)
        self.assertEqual(edit_metric(entry(finalText=thousand, expectedText=thousand))[0], "eligible")
        self.assertEqual(edit_metric(entry(finalText=text("x " * 1001), expectedText=thousand))[0], "token_limit")

    def test_store_path_is_required_and_report_does_not_create_empty_store(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            main(["report"])
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            self.assertEqual(main(["--store", str(self.root / "absent"), "report"]), 2)
        self.assertFalse((self.root / "absent").exists())


if __name__ == "__main__":
    unittest.main()
