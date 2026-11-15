# Typr CI and release

```text
Typr CI
├─ Linux checks: helper + dictation-log tests, actionlint, shell syntax; scope on PRs
├─ PRs: Linux checks only (no archive, simulator tests or screenshots)
├─ main / automatic: Decide — compare release and simulator inputs separately
├─ app changes: archive → TestFlight at once; simulator tests in parallel
├─ tests/fixtures only: simulator tests; no archive, signing or TestFlight
├─ docs / offline tools / pipeline only: no macOS jobs
│  └─ red tests → pinned "Typr status" issue → fix/<name> PR
├─ manual distribution=simulator: tests + screenshot artifact (7 days)
└─ manual ad-hoc (owner approval) or testflight

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
  and PRs labelled `no-auto-merge` are skipped. Bot merges then dispatch Typr CI
  (`distribution=automatic`) with the merge's first parent as baseline.
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
  `base_sha` applies only to automatic distribution; failed baseline fetches fail
  Decide rather than silently skipping work.
- **Status and retries:** status refresh still waits for all lanes, including
  intentionally skipped archive/sign jobs. The status issue reports failed main
  test-only runs and retains the last actual TestFlight result across skipped
  releases. Capacity retries target only the unallocated failed macOS job and its
  dependents, so retrying simulator tests cannot start an unrelated release.
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
gh workflow run typr-ci.yml -R hrudek/typr --ref feature/NAME \
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
