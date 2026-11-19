# Keyboard replay

Replays the typing log from your iPhone through the keyboard's own engine and reports how often
each hit-area setting commits the word you meant. Nothing leaves your computer and nothing is
written unless you ask for it.

## 1. Export on the iPhone

Typr app → Keyboard → Words and privacy → Typing log → Export typing log. The share sheet offers
`typr-typing-log.json`; AirDrop it to your computer or save it to Files on the iPhone. The log
only exists while "Learn from my typing" is on.

## 2. Keep the file private

The file holds what you typed. Move it into a private folder that is outside every Git checkout and
not synced (no iCloud Drive, Desktop, Documents or Dropbox), and delete the AirDrop copy:

```sh
mkdir -m 700 -p ~/typr-private
mv ~/Downloads/typr-typing-log.json ~/typr-private/
```

## 3. Build and run

macOS needs Xcode; Linux needs a Swift 6 toolchain (for example from swiftly). From the repository:

```sh
bin=$(ios/tools/keyboard_replay/build.sh)   # builds into ~/.cache/typr-keyboard-replay
"$bin" ~/typr-private/typr-typing-log.json
```

Options: `--show-words` lists the words that changed between settings or did not reproduce
(private text, keep it off screenshots and issues), `--json` prints the report as JSON,
`--out FILE` writes the report to a file outside every Git checkout. Rebuild after pulling
keyboard changes, so the replay runs today's code.

## 4. Read the result

- **Skipped**: swiped words, words with a tap the log has no point for (slides, accents, hold-123)
  and words whose keyboard layout this build cannot rebuild.
- **Reproduction**: replaying under the setting a word was typed with should give what the keyboard
  typed and committed then. Mismatches mean the replay differs from your iPhone; the usual causes
  are listed below. Words fixed by a suggestion pick or edited again after the space are not
  compared, nor are system spelling corrections.
- **Vs meant word**: for each setting, the share of words whose committed text differs from the
  word you finally kept (word errors) and the edit distance per letter (letter errors). Known words
  are in the bundled German or English word list; unknown words are everything else, such as
  names, compounds and abbreviations.
- **standard->other**: words a setting gets right that Standard got wrong (fixed) and the reverse
  (broken). Broken unknown words matter most: names and compounds must not get worse.

The replay differs from the iPhone in known ways. It has no system spelling dictionary, so it
validates words against the bundled word lists and never makes spelling-only corrections. It uses
the touch learning saved at export time for every word, without your personal words, and it sees
at most the three words logged before each word as context.
