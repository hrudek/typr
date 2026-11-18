# Typr CI and release

```text
Checks (typr-checks.yml)
└─ Linux checks: helper + dictation-log tests, actionlint, shell syntax; scope on PRs

Simulator tests (typr-simulator.yml)
├─ main / automatic: changed simulator inputs → tests (no device archive or signing)
└─ manual distribution=simulator: tests + screenshot artifact (7 days)

TestFlight (typr-ci.yml, kept for build-number and archive continuity)
├─ main / automatic: changed app inputs → archive → sign → upload
└─ manual testflight

PRs: Linux checks only; no macOS allocation.
App changes run simulator and TestFlight independently, with separate Actions results.
Tests/fixtures only run simulator tests; docs/offline/pipeline changes use no macOS.
Red runs → fix/<name> PR.

Typr review: every same-repo PR commit → Claude (read-only) → sticky comment
  ✅ PASS (green) | ❌ FIX + numbered findings (red) | ⚠️ NO RESULT (re-run once)
```

- **Merge gates:** required checks **Linux checks** and **Typr review**. `main`
  only moves forward (no force push); `Decide`/archive are not gates.
- **Review:** `typr-review.yml` runs as `pull_request_target` from `main`'s copy, so a
  PR cannot change its reviewer; it reads but never runs PR code. It uses
  `CLAUDE_CODE_OAUTH_TOKEN` in environment `typr-agent`, no signing secrets. It is
  the only agent in CI.
- **Automatic dispatch:** `distribution=automatic` on `main` routes like a push,
  comparing against `base_sha` or the commit's first parent.
- **Scheduling:** newer automatic main runs cancel older archive/test jobs, never a
  running signing/upload. Markdown, `ios/tools/` and pipeline-only edits start no
  macOS jobs (`fingerprint.sh`); build helper edits take effect on the next app change.
  Automatic pushes and dispatches compare two fingerprints: `app` excludes
  only `ios/TyprTests/` and `ios/TestFixtures/`, while `test` includes them. Both
  include project configuration, identity, shared code, resources and unknown iOS
  paths conservatively. `pipeline` retains the broader explicit-comparison mode.
  Test/fixture additions, edits, renames and deletions therefore run only simulator
  tests. A mixed app/test change runs both lanes. Current `ios/project.yml` uses
  those two folders only for the test target; if production starts consuming them,
  update the fingerprint policy with that project change.
- **Manual routing:** explicit `testflight` and `simulator` distributions always
  run, even with no input changes or a supplied `base_sha`.
  Simulator previews never archive; `only_testing=none` skips simulator tests only.
  Simulator inputs (`only_testing`, `scenes`) now belong to `typr-simulator.yml`,
  not `typr-ci.yml`. Manual device builds no longer start simulator tests.
  `base_sha` applies only to automatic distribution; failed baseline fetches fail
  Decide rather than silently skipping work.
- **Retries:** capacity retries target only the unallocated failed macOS job and its
  dependents; retrying simulator tests cannot start a release. A green TestFlight
  upload means App Store Connect accepted the upload, not that Apple finished processing it.
- **Runner retry:** `typr-retry.yml` retries a macOS job that never got a
  runner after 5, 10 and 20 minutes (max three attempts, same commit, open PR).
- **Labels:** `infra` approves `.github/` changes, `docs` approves new Markdown
  files. After adding one, re-run the failed Checks run.
- **Identity** (`app.json`, validated by `identity.py`): `dev.rudek.typr`,
  `.keyboard`, `.widgets`, `.tests`; App Group `group.dev.rudek.typr`; URL scheme
  `typr`; team `2ZNGF24932`; App Store Connect **Typr Keyboard** (`6832515139`),
  TestFlight group **Typr Internal**. Profiles `Typr App Store <bundle>`;
  environments `typr-testflight`, `typr-agent`.
- **Runners:** variable `MACOS_RUNNER` overrides the default `macos-26`.

## Owner commands

```sh
# Simulator tests + screenshots before merging
gh workflow run typr-simulator.yml -R hrudek/typr --ref feature/NAME \
  -f distribution=simulator -f scenes=keyboard-warm,full-keyboard-idle-dark

# TestFlight by hand
gh workflow run typr-ci.yml -R hrudek/typr -f distribution=testflight

# Signing profiles (local, ~/.local/share/ios-build-signing)
python3 -I .github/typr/provision.py
```
