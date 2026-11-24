# Typr CI

Builds upstream Hex's `ios/` as Typr. Nothing here changes upstream files in Git:
`prepare.sh` runs `overlay.py` (identity, icon, no Bellhop feedback key), upstream's
cleanup model fetch and `xcodegen` on the CI checkout.

```text
Checks (typr-checks.yml): script tests, ShellCheck, actionlint; scope + labels on PRs
Simulator tests (typr-simulator.yml): push to dev with changed test inputs; manual + screenshots
TestFlight (typr-ci.yml): push to dev with changed app inputs → unsigned archive → sign → upload
  manual: upload=true (dev only) or upload=false (archive + sign, any branch*)
Runner retry (typr-retry.yml): re-runs macOS jobs that never got a runner (5/10/20 min)
Review (typr-review.yml): Claude reviews each PR commit; skipped while CLAUDE_CODE_OAUTH_TOKEN is unset
```

- **Inputs** (`fingerprint.sh`): `ios/` minus docs, benchmark, Xcode Cloud and offline
  scripts, plus `app.json`, `overlay.py`, `prepare.sh` and `AppIcon.icon`. Tests and
  `tests/fixtures/vocabulary/audio` only start simulator tests. Rust, Android, site,
  docs and other pipeline edits start no macOS job.
- **Identity** (`app.json`): `dev.rudek.typr`, `.keyboard`, `.widgets`, `.tests`;
  App Group `group.dev.rudek.typr`; team `2ZNGF24932`; App Store Connect
  "Typr Keyboard" (`6832515139`), group "Typr Internal". Upstream's URL scheme stays.
  Build number = run number + 1000 (typr-deprecated ended at 519); marketing version
  is upstream's.
- **Environments**: `typr-testflight` (signing + ASC secrets) and `typr-agent`
  (`CLAUDE_CODE_OAUTH_TOKEN`), both deployable from `dev` only. *A branch proof
  needs that branch added to `typr-testflight`'s policy for the run.
- **Runners**: `xcode-27` by default; variables `MACOS_BUILD_RUNNER`, `MACOS_RUNNER`,
  `XCODE_PATH` override.

```sh
gh workflow run typr-ci.yml -R hrudek/typr                        # TestFlight from dev
gh workflow run typr-ci.yml -R hrudek/typr --ref BRANCH -f upload=false
gh workflow run typr-simulator.yml -R hrudek/typr --ref BRANCH -f scenes=keyboard-warm
bash .github/typr/agent-test.sh [Target/Class]                    # on a Mac
```
