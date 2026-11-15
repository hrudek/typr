# Whisper background failure investigation

## State

PR [#162](https://github.com/hrudek/typr/pull/162) merged as `e0d2b630` after
Linux and Typr review PASS on `6194cb3d` (no findings). Original branch:
`fix/whisper-background-failure`. Follow-up branch `fix/whisper-preparation-copy-test`
repairs a pre-existing failing simulator assertion found while following delivery.
No subworkers.

## Device evidence (2026-11-15)

Read the local wireless connection documentation and userspace helper before access.
An outside-repository private diagnostic helper reused the existing paired Tailscale
userspace tunnel. It performed read-only crash-report listing and a 40-second
Typr-PID-only historical/live os_trace stream with sensitive payloads disabled.
Connection succeeded; one Typr process was running; no Typr-named crash reports
were present in the root listing. No app launch, installation, pairing, device
configuration, data deletion or profile/certificate changes were performed.

The stream returned 7,206 technical entries, all GPU errors: 2,402 Metal background
execution permission failures and 4,804 private IOGPU errors. No Core ML error,
ANE denial, task expiration, jetsam, watchdog or preparation outcome was captured.
This is **not** an independently reproduced preparation failure. The 60 Hz GPU
errors are consistent with a still-animating UI spinner, not proof that Core ML
requested GPU execution. The configured Whisper loader excludes GPU compute.
Do not adopt GPU resources/entitlements or CPU fallback on this evidence.

Raw logs and helper are outside Git under
`~/.local/share/typr-diagnostics/whisper-background-failure/` (directory 0700,
files 0600). Only aggregated, sanitized technical metadata is recorded here.

## API and code findings

Apple's current JSON documentation and iOS 27.0 SDK mirror headers were inspected:
`BGTaskRequest.h`, `BGTaskScheduler.h`, and `BGTask.h`. Required resources have
only default (zero) and GPU (bit 0); there is no ANE/inference request bit.
Default resources are correct for the current CPU/ANE configuration. Background
Inference is a separate entitlement, already verified in signed build 290.1 by
the preceding worker. Device runtime permission is not established by signing.

The continued-task header requires runtime NSProgress reporting and says stalled
tasks may be expired. Existing code left completedUnitCount at zero and total at
-1 until success, even as completed model components were known. Title updates
are not NSProgress updates. This violates the intended progress-reporting contract;
it is a plausible expiration contributor, **not an observed cause** of this report.

Existing controller serialization/generation handling already prevents a cancelled
non-interruptible load publishing ready or overlapping a retry. Add regression
coverage specifically for resource failure followed by foreground retry.

## Changes

- App spinners become static while inactive/backgrounded, including settings and
  home preparation indicators. No GPU entitlement or compute-unit change.
- Continued-task NSProgress now counts five actual completed milestones. The app
  remains indeterminate (no synthetic Core ML percent/time); title and stage replay
  when the task attaches late. Progress cannot regress, and only successful runtime
  completion marks all units complete. No timer heartbeat or fake progress.
- Unified log metadata distinguishes task start/submission errors, runtime expiration,
  and Core ML domain/code (including one underlying error), without descriptions,
  paths or inference payloads. This enables a fresh scoped failure diagnosis.
- Written simulator tests check system progress/milestone accounting and resource
  failure followed by foreground retry with no relaunch, fallback, audio or stale
  expiration invalidation. Existing serial cancellation/retry tests remain intact.

## Verification and outstanding work

Local Linux checks passed: 88 `.github/typr/tests` tests, 25 dictation-log tests,
`bash -n` for all `.github/typr/*.sh`, shellcheck with workflow flags, actionlint
v1.7.11 with workflow flags, and `git diff --check`. The host's unconfigured Go shim
initially rejected actionlint; reran successfully with `mise exec go@1.27.3` (no
configuration edits).

No simulator execution on this Linux host. Main CI simulator run
[43720128607](https://github.com/hrudek/typr/actions/runs/43720128607) **compiled and
executed 906 tests, with one failure**. Both new tests (milestone accounting and
resource-failure foreground retry) and the expanded component progress test passed.
The only failure was the stale `First use optimizes` copy assertion at
`SpeechEngineSelectionTests.swift:452`. Previous main run
[43715273830](https://github.com/hrudek/typr/actions/runs/43715273830) has exactly the
same failure (904 tests). PR #161 changed the copy to automatic preparation /
`First optimization`; its test assertion was not updated. Follow-up updates the
assertion to the current automatic-preparation, optimization and retry contract;
no production copy or behavior changes.

Main TestFlight run [43720130405](https://github.com/hrudek/typr/actions/runs/43720130405)
succeeded, including archive, signing and upload. This proves upload acceptance,
not Apple processing or tester installation. No fixed build installed or exercised
on iPhone. Need a signed release retest and, if failure persists, a scoped capture
during a fresh attempt including the new technical preparation/scheduler diagnostics.
