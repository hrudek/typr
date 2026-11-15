# Typr

Typr is a standalone iPhone dictation keyboard with a containing app, widgets and
Live Activity. Speech recognition runs on-device: Apple Speech (iOS 26+), Parakeet
V2 (iOS 18+) or Whisper Large V3 Turbo (explicit model download). An explicit
engine or language choice never silently falls back to another.

## How it works

- The app records and transcribes; the keyboard sends commands and inserts text
  through an App Group. The keyboard needs Full Access but never accesses the
  microphone, speech model or network.
- From a cold start, Dictate opens Typr to record, then returns to the host app.
  Host detection and return use private APIs with fallbacks. Transient surfaces
  such as share sheets require **Keep mic warm** instead.
- **Keep mic warm** keeps an audio session active so dictation can start without
  leaving the keyboard. The idle microphone session mixes with other audio; only
  an actual dictation interrupts playback. Stopping or cancelling the recording
  releases that interruption immediately, without waiting for transcription or
  ending the warm session. If iOS refuses to interrupt playback in the background,
  dictation still works, but playback may continue during that recording. Resuming
  playback is ultimately controlled by the interrupted app and iOS.
- Text processing combines vocabulary corrections, optional on-device Apple
  Intelligence cleanup (iOS 26+) and formatting styles. The full keyboard adds
  German/English autocorrect and adaptive suggestions.

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
