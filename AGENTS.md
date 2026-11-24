# Typr: a fork of Hex

This repository is [anomalyco/hex](https://github.com/anomalyco/hex) 1:1 plus a
minimal Typr layer that builds Hex's iPhone app as the Typr App Store app
(`dev.rudek.typr`, team `2ZNGF24932`, TestFlight group "Typr Internal").
Behaviour is upstream's; Typr adds only what this file lists.

## Where the Typr layer lives

- `.github/workflows/typr-*.yml` and `.github/typr/**`: Typr's own CI
  (checks, simulator tests, TestFlight, runner retry, review). See
  `.github/typr/README.md`. Upstream's workflows are disabled in this repo.
- `.github/typr/overlay.py`: applies Typr's identity (bundle IDs, App Group,
  team, display name, icon) to upstream's `ios/` at build time, in CI only.
  Never commit identity changes to upstream files; extend the overlay.
- Typr features: new files in Typr-named folders (`ios/**/Typr*`), hooked into
  upstream files with as few lines as possible.
- This `AGENTS.md`.

## Rules

- Keep Typr changes separate from upstream code and minimal. A daily job
  rebases the Typr commits onto `upstream/dev`; every upstream line you edit is
  a future conflict. Prefer a new Typr file over editing an upstream one.
- Upstream fixes and features belong upstream, not here.
- For upstream code, read upstream's guide: `git show upstream/dev:AGENTS.md`
  (remote `upstream` = anomalyco/hex). Its process rules (Dax, releases, Labs)
  do not apply to this fork.

## PRs and CI

- Branch from `dev`, open a PR to `dev`, squash-merge. `dev` is rebased onto
  upstream daily, so expect its history to be rewritten.
- PRs run Linux checks (`typr-checks.yml`) and the Claude review. Changes under
  `.github/` need the `infra` label, new Markdown files the `docs` label.
- A push to `dev` that changes iOS build inputs (`ios/`, the overlay) runs
  simulator tests and archives, signs and uploads to TestFlight. Nothing else
  starts a macOS runner.
