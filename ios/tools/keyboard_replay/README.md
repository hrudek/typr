# Keyboard replay

Replays the typing log from your iPhone through the keyboard's own engine and reports how often
it commits the word you meant. Nothing leaves your computer. The only files
written are the build in its build folder; the replay itself keeps everything in memory and prints
the report.

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

Options: `--show-words` lists the words that did not reproduce or differ from the meant word
(private text, keep it off screenshots and issues), `--json` prints the report as JSON,
The report goes to the terminal only; to keep it, redirect it into your private folder, for
example `"$bin" ~/typr-private/typr-typing-log.json > ~/typr-private/report.txt`. Rebuild after
pulling keyboard changes, so the replay runs today's code.

## 4. Read the result

Each word is replayed as you typed it up to its first space or punctuation: every tap, the
backspaces between them and a suggestion you picked. Later edits (undo, retyping after the space)
are what you meant, not input.

- **Reproduction** (first lines): the replay should commit what your iPhone committed. The
  percentage tells how far to trust the rest. Words fixed by system spelling or picked from the
  suggestion strip are counted, not compared. Words typed with an older Typr build may differ.
- **Skipped**: swiped words, words with a tap the log has no point for (slides, accents, hold-123),
  layouts this build cannot rebuild, edits whose order the log does not tell, picks the replayed
  strip does not offer, and words whose learning state is uncertain: the export keeps, protects or
  rejects them, and their own log cannot tell whether that was already so when you typed them.
- **Vs meant word**: the share of words whose committed text differs from the
  word you finally kept (word errors) and the edit distance per letter (letter errors). Known words
  are in the bundled German or English word list; unknown words are everything else, such as new
  names, compounds and abbreviations.

The replay uses the learning state at export time, changed only where a word's own log proves it
(an autocorrected word was not kept then). It has no system spelling dictionary, so it validates
words against the bundled word lists and never makes spelling-only corrections. The learning state
includes each key's aim memories at export time.
The replay sees at most the three words logged before each word as context.

## Tests

`python3 -m unittest discover -s ios/tools/keyboard_replay/tests` builds the tool and replays
`fixture/synthetic.json`, invented text typed through the engine. After changing the export format,
regenerate it with `keyboard-replay --make-fixture ios/tools/keyboard_replay/fixture/synthetic.json`.
`keyboard-replay --touch-posterior` prints the learned touch densities after fixed labels and how
displaced taps move one key's aim; the tests compare them with an independent computation of the
touch model.
