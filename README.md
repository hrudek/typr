# Typr

Typr is a standalone iPhone dictation keyboard with a containing app, widgets and
Live Activity. Speech recognition runs on-device: Apple Speech (iOS 26+), Parakeet
V2 (iOS 18+), Whisper Large V3 Turbo, Parakeet V3, Orukeet or Cohere Transcribe
(explicit model downloads).
An explicit engine or language choice never silently falls back to another.

## How it works

- The app records and transcribes; the keyboard sends commands and inserts text
  through an App Group. The keyboard needs Full Access but never accesses the
  microphone or speech model.
- From a cold start, Dictate opens Typr to record, then returns to the host app.
  Host detection and return use private APIs with fallbacks. Transient surfaces
  such as share sheets require **Keep mic warm** instead.
- **Keep mic warm** keeps microphone input running so repeated dictations can start
  without leaving the keyboard. The duration is 5 minutes, 15 minutes or 1 hour.
  If iOS reports another app playing audio before
  microphone activation, Typr leaves idle input cold. Dictate then opens Typr to
  start recording and interrupt that audio. Stopping or cancelling the recording
  fully releases the audio session with `notifyOthersOnDeactivation`, before
  transcription, so the interrupted app can resume. That capture ends the warm
  session; another cold dictation may require opening Typr again. When no other
  audio is playing, normal warm behavior is preserved without changing category
  options on a running input. Later playback/interruption events are also checked
  before restarting idle input. Detection is a momentary iOS audio signal, not a
  per-app media inventory; actual resumption is controlled by the media app and iOS.
- Text processing combines vocabulary corrections, optional AI cleanup and
  formatting styles. Cleanup runs on-device with Apple Intelligence (iOS 26+,
  default) or, with your own Anthropic API key (stored in the Keychain), with
  Claude in the cloud; the plain transcript is used whenever cleanup is
  unavailable. Apple Intelligence cleanup is Hex's iOS cleaner word for word (instructions,
  options, 2 s budget, answer check); Claude gets Hex's dictation rewrite prompt word for
  word, with the host app and the text around the cursor as context. The full keyboard adds German/English autocorrect and adaptive
  suggestions. On iOS 26+ with Apple Intelligence available for every enabled language, the
  on-device model adds up to three next-word predictions from the current paragraph before the
  cursor (1 s budget; on failure the count-based predictions stay).
- While learning is on, the keyboard keeps a typing log on the iPhone: taps,
  corrections and the final word of the most recent 10,000 to 20,000 words, never
  from secure, URL or email fields. Keyboard › Words and privacy exports it as
  JSON with the keyboard's learning and your personal words for the desktop
  replay (`ios/tools/keyboard_replay`), or deletes it.

## Downloaded model preparation

Opening Typr automatically prepares an installed, explicitly chosen Whisper,
Parakeet V3, Orukeet or Cohere Transcribe model without downloading. On iOS 26+, Typr asks to continue that preparation after you
leave the app; older iOS has only limited background grace time. Opportunistic
maintenance can also prepare it while charging. iOS may decline, pause or stop
this work; there is no immediate post-update guarantee. Reopen Typr to retry.
Preparation never starts the microphone or audio keepalive.

Delete in Speech engine removes a downloaded model (Whisper, Parakeet V2,
Parakeet V3, Orukeet or Cohere Transcribe) with its partial downloads, after
releasing it if it is loaded. The chosen engine stays chosen: Whisper, Parakeet
V3, Orukeet and Cohere Transcribe then need Download again, Parakeet V2 downloads
again on next use. Apple Speech has no Delete; iOS manages its assets.

Cohere Transcribe has no language detection. German or English dictation passes
that language; automatic passes the first iPhone language Cohere supports, else
English.

Background Neural Engine access on iOS 27+ requires the Background Inference
capability (`com.apple.developer.background-tasks.continued-processing.inference`)
in the app's provisioning profiles; signing fails closed if it is missing.

## Build and test

Requires Xcode 26+ and XcodeGen 2.46.0+ on macOS:

```sh
cd ios
xcodegen generate
xcodebuild test -project Typr.xcodeproj -scheme Typr -destination "id=<SIM_UDID>"
```

Simulator tests exercise capture, handoff, text processing and keyboard logic.
Background microphone behavior, speech performance, host-app return, Live Activity,
Bluetooth/CarPlay and real typing quality require a physical iPhone.
CI and releases: [.github/typr/README.md](.github/typr/README.md).

## Origin and licenses

Based on [Hex by Kit Langton](https://github.com/anomalyco/hex), base commit
`cae389a8`, under MIT; the original [LICENSE](LICENSE) is preserved.
Other third-party code and data: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
