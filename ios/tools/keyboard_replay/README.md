# Keyboard replay

Replays the typing log from your iPhone through the keyboard's own engine and reports how often
each hit-area setting commits the word you meant. Nothing leaves your computer and nothing is
written unless you ask for it.

## 1. Export on the iPhone

Typr app → Keyboard → Words and privacy → Typing log → Export typing log. The share sheet offers
`typr-typing-log.json`; AirDrop it to your computer or save it to Files on the iPhone. The log
only exists while "Learn from my typing" is on. The file also carries what the keyboard learned
and your imported personal words, so the replay protects the same words as your iPhone.

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

- **Reproduction** (first lines): replaying a word under the setting it was typed with should
  commit what your iPhone committed. The percentage tells how far to trust the rest; mismatches
  mean the replay differs from your iPhone (see below). Words fixed by system spelling, by a
  suggestion pick or edited again after the space are not compared and are counted.
- **Skipped**: swiped words, words with a tap the log has no point for (slides, accents, hold-123)
  and words whose keyboard layout this build cannot rebuild.
- **Vs meant word**: for each setting, the share of words whose committed text differs from the
  word you finally kept (word errors) and the edit distance per letter (letter errors). Known words
  are in the bundled German or English word list, imported as personal words or kept before the
  word was typed; unknown words are everything else, such as new names, compounds and
  abbreviations.
- **standard->other**: words a setting gets right that Standard got wrong (fixed) and the reverse
  (broken). Broken unknown words matter most: names and compounds must not get worse.

The replay differs from the iPhone in known ways. It has no system spelling dictionary, so it
validates words against the bundled word lists and never makes spelling-only corrections. It uses
the learning saved at export time for every word, minus the undos and keeps the log shows from
that word on; touch aim and word counts are not rewound. It sees at most the three words logged
before each word as context.

## Tests

`python3 -m unittest discover -s ios/tools/keyboard_replay/tests` builds the tool and replays
`fixture/synthetic.json`, invented text typed through the engine. After changing the export format,
regenerate it with `keyboard-replay --make-fixture ios/tools/keyboard_replay/fixture/synthetic.json`.
