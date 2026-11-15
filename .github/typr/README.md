# Typr CI and release

```text
Checks (typr-checks.yml)
└─ Linux checks: helper + dictation-log tests, actionlint, shell syntax; scope on PRs

Simulator tests (typr-simulator.yml)
├─ main / automatic: changed simulator inputs → tests (no device archive or signing)
└─ manual distribution=simulator: tests + screenshot artifact (7 days)

TestFlight (typr-ci.yml, kept for build-number and archive continuity)
├─ main / automatic: changed app inputs → archive → sign → upload
└─ manual unsigned, ad-hoc (owner approval) or testflight
   Run titles distinguish Unsigned build / Ad-hoc build / TestFlight.

PRs: Linux checks only; no macOS allocation.
App changes run simulator and TestFlight independently, with separate Actions results.
Tests/fixtures only run simulator tests; docs/offline/pipeline changes use no macOS.
Red runs → pinned "Typr status" issue → fix/<name> PR.

Typr review: every same-repo PR commit → Claude (read-only) → sticky comment
  ✅ PASS (green) | ❌ FIX + numbered findings (red) | ⚠️ NO RESULT (re-run once)

Typr PR to iPhone: signs an existing manual distribution=unsigned PR archive
```

- **Merge gates:** required checks **Linux checks** and **Typr review**. `main`
  only moves forward (no force push); `Decide`/archive are not gates.
- **Review:** `typr-review.yml` runs as `pull_request_target` from `main`'s copy, so a
  PR cannot change its reviewer; it reads but never runs PR code. It uses
  `CLAUDE_CODE_OAUTH_TOKEN` in environment `typr-agent`, no signing secrets. It is
  the only agent in CI.
- **Auto-merge:** `typr-auto-merge.yml` (trusted `main` code) squash-merges the
  current same-repo PR once all required checks pass for its head SHA. Drafts, forks
  and PRs labelled `no-auto-merge` are skipped. Bot merges explicitly dispatch all
  three workflows (bot pushes do not trigger push workflows). Simulator and release
  use `distribution=automatic` with the merge's first parent as baseline. Recovery
  checks each workflow separately, so a partial dispatch retries only missing lanes.
- **Scheduling:** newer automatic main runs cancel older archive/test jobs, never a
  running signing/upload. Markdown, `ios/tools/` and pipeline-only edits start no
  macOS jobs (`fingerprint.sh`); build helper edits take effect on the next app change.
  Automatic pushes and bot-merge dispatches compare two fingerprints: `app` excludes
  only `ios/TyprTests/` and `ios/TestFixtures/`, while `test` includes them. Both
  include project configuration, identity, shared code, resources and unknown iOS
  paths conservatively. `pipeline` retains the broader explicit-comparison mode.
  Test/fixture additions, edits, renames and deletions therefore run only simulator
  tests. A mixed app/test change runs both lanes. Current `ios/project.yml` uses
  those two folders only for the test target; if production starts consuming them,
  update the fingerprint policy with that project change.
- **Manual routing:** explicit `unsigned`, `ad-hoc`, `testflight` and `simulator`
  distributions always run, even with no input changes or a supplied `base_sha`.
  Simulator previews never archive; `only_testing=none` skips simulator tests only.
  Simulator inputs (`only_testing`, `scenes`) now belong to `typr-simulator.yml`,
  not `typr-ci.yml`. Manual device builds no longer start simulator tests.
  `base_sha` applies only to automatic distribution; failed baseline fetches fail
  Decide rather than silently skipping work.
- **Status and retries:** each completed main workflow refreshes status independently
  via `workflow_run`, using trusted main code. The issue has separate Checks,
  Simulator tests and TestFlight/device-build rows. It includes automatic bot-merge
  dispatches and retains the last actual TestFlight result across skipped releases.
  Capacity retries target only the unallocated failed macOS job and its dependents;
  retrying simulator tests cannot start a release. A green TestFlight upload means
  App Store Connect accepted the upload, not that Apple finished processing it.
- **Runner retry:** `typr-retry.yml` retries a macOS job that never got a
  runner after 5, 10 and 20 minutes (max three attempts, same commit, open PR).
- **Labels:** adding `infra` re-runs failed CI jobs (`typr-recheck.yml`).
- **Identity** (`app.json`, validated by `identity.py`): `dev.rudek.typr`,
  `.keyboard`, `.widgets`, `.tests`; App Group `group.dev.rudek.typr`; URL scheme
  `typr`; team `2ZNGF24932`; App Store Connect **Typr Keyboard** (`6832515139`),
  TestFlight group **Typr Internal**. Profiles `Typr Ad Hoc|App Store <bundle>`;
  environments `typr-ad-hoc` (approval), `typr-testflight`, `typr-agent`.
- **Runners:** variable `MACOS_RUNNER` overrides the default `macos-26`.
- **PR fast path:** only open, non-draft `feature/*` PRs; requires the latest manual
  CI run for the current head with successful Linux checks, Decide and unsigned
  archive. Signing uses scripts from `main` only and keeps the archive's build number.

## Owner commands

```sh
# Try a PR on the iPhone: build, then sign that archive (approve on the run page)
gh workflow run typr-ci.yml -R hrudek/typr --ref feature/NAME -f distribution=unsigned
gh workflow run typr-ad-hoc.yml -R hrudek/typr --ref main -f pr=123

# Simulator tests + screenshots before merging
gh workflow run typr-simulator.yml -R hrudek/typr --ref feature/NAME \
  -f distribution=simulator -f scenes=keyboard-warm,full-keyboard-idle-dark

# Fresh ad-hoc build of main or a branch; TestFlight by hand
gh workflow run typr-ci.yml -R hrudek/typr --ref feature/NAME -f distribution=ad-hoc
gh workflow run typr-ci.yml -R hrudek/typr -f distribution=testflight

# Install an ad-hoc build (RUN_ID = signing run)
gh run download -R hrudek/typr RUN_ID --pattern 'typr-ad-hoc-*' --dir ~/code/typr-downloads/RUN_ID
age --decrypt --identity ~/.local/share/ios-build-signing/artifacts.agekey \
  --output Typr.ipa ~/code/typr-downloads/RUN_ID/typr-ad-hoc-RUN_ID/Typr.ipa.age
~/code/apple-dev-setup/iphone-wifi install "$PWD/Typr.ipa"

# Signing profiles (local, ~/.local/share/ios-build-signing)
python3 -I .github/typr/provision.py ad-hoc|testflight
```

Ad-hoc and TestFlight builds share one bundle ID and replace each other on the
iPhone (data stays).
