# Typr agent guide

Typr is a standalone iPhone dictation keyboard. CI, review, signing and owner
commands: [.github/typr/README.md](.github/typr/README.md).

## Pull requests

- Branch `feature/<name>` or `fix/<name>` from current `origin/main` (CI reads the
  prefix). Changes under `.github/` need the `infra` label.
- The PR description is the record the reviewer checks against: goal, agreed
  behavior, decisions, what was and wasn't tested. Keep it and README current.
- No new Markdown files for features, plans, task state or reports: rationale goes
  into the PR description or a short code comment. Agent working files (`TASKS.md`,
  `reports/`) stay outside the repository. A new `.md` needs the `docs` label.
- After pushing, fix every numbered finding of the latest **Typr review** and wait
  for the next verdict. `⚠️ NO RESULT`: re-run once, then tell the owner.
- **Prefer fast integration:** open small PRs promptly; do not wait for simulator
  tests before merging. Linux checks and Typr review remain required. Simulator
  tests run on `main` alongside TestFlight delivery; follow the results and promptly
  fix regressions or revert.
- Removing a feature: prefer **Revert** of its PR(s).

## Tests

- Every feature adds simulator tests in `ios/TyprTests`. CI runs them after merge;
  locally run only targeted tests when debugging:
  `bash .github/typr/agent-test.sh [Target/Class,…]` (macOS only).
- On Linux, the checks are the `linux` job in `.github/workflows/typr-checks.yml`.
- Report honestly: a written test is not a passing run, a simulator is not a real
  iPhone. Name the exact checks run, failures, and what remains unverified.

## Implementation and privacy

- Add a feature switch only when the owner asks for one.
- No speculative abstractions: generalize only for two real implementations or a
  current test need.
- The keyboard never touches network, speech model or microphone. Captured audio
  is never persisted. Transcripts and logs stay out of Git, PRs and issues.
- Never change bundle IDs, App Group, URL scheme, signing or secrets incidentally.
- UI copy: sentence case, product name “Typr”.

## Third-party code

Any license is allowed, including unknown ones (Typr is for personal use), but ask
the owner before adopting GPL-family or unlicensed code. In the same PR, add to
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): what was taken, source URL,
immutable revision and the license, or “license unknown”.
