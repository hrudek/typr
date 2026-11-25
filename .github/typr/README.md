# Typr CI

Builds upstream Hex's `ios/` as Typr. Nothing here changes upstream files in Git:
`prepare.sh` runs `overlay.py` (identity, icon, no Bellhop feedback key, `wordmark.py`,
`mark.py`, `rebrand.py`), upstream's cleanup model fetch and `xcodegen` on the CI checkout.

```text
Checks (typr-checks.yml): script tests, ShellCheck, actionlint; scope + labels on PRs
Simulator tests (typr-simulator.yml): push to dev with changed test inputs; manual + screenshots
TestFlight (typr-ci.yml): push to dev with changed app inputs → changelog → unsigned archive → sign
  → upload → build record
  manual: upload=true (dev only) or upload=false (archive + sign, any branch*)
Runner retry (typr-retry.yml): re-runs macOS jobs that never got a runner (5/10/20 min)
Review (typr-review.yml): Claude reviews each PR commit; skipped while CLAUDE_CODE_OAUTH_TOKEN is unset
Upstream sync (typr-sync.yml): dispatched daily at 04:00 Europe/Berlin by a T3 Code scheduled task (`gh workflow run typr-sync.yml -R hrudek/typr --ref dev`); manual dispatch works too → rebase Typr commits onto upstream dev
  → squash them by feature → Linux checks + overlay check → push dev [skip ci] → disable upstream workflows → start TestFlight /
  Simulator tests when their inputs changed → open upstream-overlap issues
```

- **Sync** (`sync.sh`): Typr commits = `dev` since its merge-base with upstream `dev`. Nothing
  new upstream and no new Typr commits: no push. `AGENTS.md` conflicts keep Typr's file; other conflicts go to Claude
  (`sync-resolve.sh`, file tools on copies of the conflicted files only) or fail red without a
  push when `CLAUDE_CODE_OAUTH_TOKEN` is unset. Checks run in a job without secrets; the push job
  runs no repository code and pushes with the write deploy key `TYPR_SYNC_DEPLOY_KEY`
  (GITHUB_TOKEN may not push workflow files). An empty `[skip ci]` commit on top keeps the push
  from starting any workflow, so new upstream workflows are disabled before they run; the next
  sync drops it. A push whose old `dev` is gone builds and tests everything.

- **Feature commits** (`sync-group.py`): after the rebase, Typr commits without a
  `Typr-Feature: <slug>` trailer are new. Claude (Sonnet, JSON only) sorts them by what they do
  for the user into existing feature commits or new ones; shared files do not force features
  together. `.github/**` and `AGENTS.md` always go to `ci`. Each feature commit replays its
  changes 3-way on top of the one below, so features may share files. The body lists the folded
  subjects and `PRs: #a, #b`. A manual run with `regroup` splits every existing feature back into
  its PRs (merge commits via `gh`) and lets Claude group them afresh. Bad AI output, a timeout,
  no token or a replay conflict group by area (`ci` vs `typr`, existing features kept); a tree
  that differs from the plain rebase keeps the plain rebase. The step summary shows what went
  where.

- **Upstream overlap** (`sync-overlap.py`): after the push, Claude compares the upstream commits
  the sync pulled in with the Typr features (`ci` only by its feat/fix bullets: branding, build
  identity). Matches at confidence 0.7 or above open one `upstream-overlap` issue per feature
  and hex PR, deduped by a hidden marker across open and closed issues. The job alone has
  `issues: write`, holds no deploy key and cannot fail the sync.

- **Changelog** (`changelog.py`): a Linux job writes `TyprChangelog.json` (German bullets
  by Claude Haiku in `typr-agent`; plain titles without token, on a timeout or bad output) and
  the archive job copies it to `ios/HEXMobile/Typr/`, so it is bundled but never committed.
  "Typr": dev PRs named in the Typr commits and not in the last record, without CI-only PRs or
  ci/test/docs/chore titles. "Von Hex": upstream commits since the last record's upstream
  base that change app inputs. The record (upstream base + PR numbers) is the artifact
  `typr-build-record`, uploaded only after a TestFlight upload and kept 90 days; without one
  both sections look back 7 days. Any changelog failure leaves the app without the file and
  the build goes on. A branch run has no `typr-agent` and gets plain titles.
- **Inputs** (`fingerprint.sh`): `ios/` minus docs, benchmark, Xcode Cloud and offline
  scripts, plus `app.json`, `overlay.py`, `rebrand.py`, `wordmark.py`, `wordmark/`,
  `mark.py`, `mark/`, `prepare.sh` and `AppIcon.icon`. Tests,
  `tests/fixtures/vocabulary/audio` and `tests/fixtures/hex-words` only start simulator
  tests. Rust, Android, site, docs and other pipeline edits start no macOS job.
- **Identity** (`app.json`): `dev.rudek.typr`, `.keyboard`, `.widgets`, `.tests`;
  App Group `group.dev.rudek.typr`; team `2ZNGF24932`; App Store Connect
  "Typr Keyboard" (`6832515139`), group "Typr Internal". Upstream's URL scheme stays.
  Build number = run number + `build_number_offsets[marketing version]`, 0 if unlisted,
  always a plain integer. Re-runs keep the run number, so Apple rejects a rebuild after a
  successful upload; push a new commit or use workflow_dispatch for a new number.
  Only 9.0.0 has an offset (1000, since typr-deprecated ended at 519 and 9.0.0 reached
  1002); the next upstream version resets to the bare run number. Marketing version
  is upstream's (`ios/project.yml`).
- **Environments**: `typr-testflight` (signing + ASC secrets), `typr-agent`
  (`CLAUDE_CODE_OAUTH_TOKEN`) and `typr-sync` (deploy key), all deployable from `dev`
  only. *A branch proof needs that branch added to `typr-testflight`'s policy for the run.
- **Runners**: `xcode-27` by default; variables `MACOS_BUILD_RUNNER`, `MACOS_RUNNER`,
  `XCODE_PATH` override.

```sh
gh workflow run typr-ci.yml -R hrudek/typr                        # TestFlight from dev
gh workflow run typr-sync.yml -R hrudek/typr                      # upstream sync now
gh workflow run typr-ci.yml -R hrudek/typr --ref BRANCH -f upload=false
gh workflow run typr-simulator.yml -R hrudek/typr --ref BRANCH -f scenes=keyboard-warm
bash .github/typr/agent-test.sh [Target/Class]                    # on a Mac
```
