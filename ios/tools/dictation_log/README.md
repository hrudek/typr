# Local dictation archive import and report (C)

Dependency-free **Python 3.10+ on Linux/macOS** (`sqlite3` and `fcntl` from the
standard library). This is an explicit desktop command, not an iPhone feature or
background service: no network, uploads, inference, audio, paid evaluation, replay,
automatic regression comparison, package installation or app configuration changes.
Nothing under this directory is added to Xcode targets or `project.yml`.

## Use

Export JSON from Typr › History & feedback › Export full log (JSON), then explicitly choose a private,
**non-synced directory outside every Git checkout**, including linked worktrees:

```sh
python3 ios/tools/dictation_log/cli.py --store "$HOME/.local/share/typr-feedback" import /path/to/export.json
python3 ios/tools/dictation_log/cli.py --store "$HOME/.local/share/typr-feedback" report
python3 ios/tools/dictation_log/cli.py --store "$HOME/.local/share/typr-feedback" report --json
# Deliberately exposes private stages/reference/note/vocabulary on stdout:
python3 ios/tools/dictation_log/cli.py --store "$HOME/.local/share/typr-feedback" report --json --show-text
```

`--store` is required; there is no automatic data discovery. Paths are resolved
through symlinks, then all ancestors are checked for `.git` directories **or
files**. The tool refuses a checkout rather than risking a committed dataset.
An existing nonempty directory must already contain a recognized Typr store; otherwise
it is rejected **before chmod or file creation**, so a mistaken `--store ~` or
Documents path is untouched. New/empty directories are accepted for import.
Report refuses a nonexistent store instead of silently creating an empty one.
Exit status: 0 success (including disclosed conflicts/skipped future entries),
2 invalid input, unsupported format, busy store or local I/O failure. Warnings
and counters must be read; success is not proof of a complete export.

Synthetic smoke check (contains only invented sentences and vocabulary):

```sh
STORE=$(mktemp -d /tmp/typr-feedback-example.XXXXXX)
python3 ios/tools/dictation_log/cli.py --store "$STORE" import ios/tools/dictation_log/examples/synthetic.json --json
python3 ios/tools/dictation_log/cli.py --store "$STORE" report --json
# Exactly two records: good=1, bad=1, references=1, Good without reference=1;
# final-output/reference word edit rate=1/3 for one eligible pair, NOT ASR WER.
# Reimport: inserted=0, unchanged=2, no duplicate records.
python3 ios/tools/dictation_log/cli.py --store "$STORE" import ios/tools/dictation_log/examples/synthetic.json --json
```

## Storage and privacy

- `archive.sqlite3` holds the store; `exports/<SHA256>.json` keeps **byte-exact
  copies of every accepted input**, including all private text. Not anonymous,
  not encrypted. Only synthetic examples belong in Git.
- Settings and vocabulary fingerprints use a per-store HMAC key (not encryption),
  comparable only within one store.
- Directories are 0700, files 0600; commands are serialized with `flock`.
- No secure erase or backup/sync control: use a private, non-synced, encrypted location.

There is intentionally no per-entry forget that would leave its text in raw
snapshots. To remove **everything**, stop commands, verify the exact store path,
and delete that directory and all its contents, e.g.:

```sh
# DESTRUCTIVE: substitute and verify your actual local store path first.
rm -rf -- /your/verified/private/typr-feedback-store
```

This removes SQLite, journals, HMAC key and **all** raw copies/orphans in that
store. It does not delete the original export, iPhone Files copies, the iPhone
archive, backups or files already shared with another recipient. Never point this
command at the repository or a directory containing other work.

## Import and reports

- Export v1 entries merge by `(archiveID, entryID)` and whole-entry revision; equal
  revisions with different content warn and keep the current entry. Unknown formats
  fail without partial commit; unknown entry schemas are skipped and kept raw.
- Export scope is unknown; absent entries are never deleted.
- Default reports omit all text and vocabulary; only `--show-text` prints it.
  Groups with n < 5 say **too few data**; no rankings or significance claims.
- `final-output→reference word edit rate` (NFC, whitespace tokens, ≤ 1000 tokens per
  side) is **not ASR WER** or semantic quality.

## Verification

```sh
python3 -m unittest discover -s ios/tools/dictation_log/tests -v
```

Tests are synthetic; they are not device or model-quality proof.
