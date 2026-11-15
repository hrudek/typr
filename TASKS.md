# Whisper background preparation

Owner approved options 2 + 3: prepare the installed, selected Whisper model automatically on opening; continue after backgrounding using iOS 26 BGContinuedProcessingTask (bounded UIKit grace on older iOS); opportunistic BGProcessingTask maintenance. Never auto-download or use microphone/audio keepalive. iOS controls scheduling/termination; no promise of immediate post-update execution. Preserve engine selection, avoid duplicate model instances, safe expiration/cancellation, truthful UI/progress, simulator tests. Inspect Apple SDK/API documentation for correct availability and hardware/resource limitations of Core ML continued background work. No incidental identity/signing changes.

- [x] Implement, document, add simulator tests (written, not run on Linux)
- [x] Run available Linux checks; report macOS/device validation not performed
- [x] PR #161 opened; both numbered review findings fixed; Typr review PASS and Linux CI green on 2fc39678. Final tracking-only commit re-runs gates.
- [ ] Owner integration blocker: confirm/enable iOS 27 Background Inference capability and regenerate app profiles as required; necessary signing whitelist changes included. Do not auto-merge until resolved; this is not a simulator gate.

Worker details/report: reports/whisper-background.md. Worker reply <=10 lines.
