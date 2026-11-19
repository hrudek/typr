# Bundled keyboard word data

`keyboard-de.words` and `keyboard-en.words` are derived spatial word data, licensed
under **Creative Commons Attribution-ShareAlike 4.0 International**, not Typr's MIT
code license. Full terms accompany them in `CC-BY-SA-4.0.txt`:
https://creativecommons.org/licenses/by-sa/4.0/ . No endorsement is implied.

Attribution: **Hermit Dave / FrequencyWords**, German and English frequency lists,
2018 edition, derived from **OpenSubtitles 2018 / OpenSubtitles**.

- Source: https://github.com/hermitdave/FrequencyWords
- Reviewed revision: `525f9b560de45753a5ea01069454e72e9aa541c6`
- Files: `content/2018/de/de_50k.txt`, `content/2018/en/en_50k.txt`
- Content license declaration: https://github.com/hermitdave/FrequencyWords/blob/525f9b560de45753a5ea01069454e72e9aa541c6/README.md#license
- Corpus: https://opus.nlpl.eu/OpenSubtitles2018.php and https://www.opensubtitles.org/
- Typr modifications: NFC normalization; retain lowercase letters only (a–z for
  English, also ä/ö/ü/ß for German), lengths 2–32; sum duplicate counts; compile
  into a forward-only, breadth-first trie. No invented spellings or capitalization.
- The derived resources remain CC BY-SA 4.0. Their editable upstream inputs,
  exact hashes and the complete transformation are available through the links
  above and `ios/tools/keyboard_words/build.py` in Typr's source repository:
  https://github.com/hrudek/typr .

| Resource | Words | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| keyboard-de.words | 49,311 | 1,651,680 | `9f44e7e6d71f1f214528f2a140743b65c2e798fda2cfe88775a6738b13c290e8` |
| keyboard-en.words | 46,691 | 1,293,108 | `ca0cf23d3ef0bddf0f633a20aa82d05e667dd848f35cc773f0531609f5903ff8` |

## Reproduce offline

Explicitly download the two source files at the pinned revision outside the
repository. The compiler itself never accesses the network or app/runtime data;
its CLI rejects inputs with different SHA-256 hashes.

```sh
python3 ios/tools/keyboard_words/build.py de /path/to/de_50k.txt ios/TyprShared/FullKeyboard/WordData/keyboard-de.words
python3 ios/tools/keyboard_words/build.py en /path/to/en_50k.txt ios/TyprShared/FullKeyboard/WordData/keyboard-en.words
python3 -m unittest discover -s ios/tools/keyboard_words -v
```

The folder, including attribution and license, is bundled in both app and keyboard,
never the widgets. These counts are not a spelling dictionary; no accuracy claim
follows from inclusion.

## Corpus context sidecars (TBG1)

`keyboard-{de,en}.tbg` are **separate** corpus adaptations: Common Voice CC0,
named-owner Tatoeba CC BY 2.0 FR, Leipzig news (CC BY terms/version qualification),
Wikipedia (CC BY-SA), and OPUS OpenSubtitles (underlying rights unresolved).
They are not FrequencyWords or MIT data. R2-9 source-by-source terms, notices,
open questions and reproduction are in [SOURCE](../../../tools/keyboard_context/SOURCE). See
[ATTRIBUTION.md](ATTRIBUTION.md), [tatoeba-contributors.tsv](tatoeba-contributors.tsv)
and the linked full sentence source mapping. Preserve all three when redistributing.
The [explicit offline compiler](../../../tools/keyboard_context/README.md) pins
all input hashes and documents rebuilds; no acquisition or input files are bundled.

| Resource | Lexical words | Edges | Bytes | SHA-256 |
| --- | ---: | ---: | ---: | --- |
| keyboard-de.tbg | 8,000 | 15,340 | 382,140 | `5b19683277b453d6d93189d6a615f63ce012deba0f50e05880dedf1c8a9c5ed3` |
| keyboard-en.tbg | 8,000 | 20,065 | 388,490 | `a270578241a627473dac054d2a340e763dab87af95fc57dc7bde95684cc7aee5` |

The packs contain no audio, raw sentences, neural weights, personal data or URLs.

`context-heldout-cc0.json` is a small **CC0 Common Voice** test fixture with source
revision/selection recorded inside. `swift-reference-vectors.json` is Typr-generated
numeric reference output for the fixed bilingual formulas. Both are inert test
resources, not runtime model inputs. Neither changes the sidecar training counts.
`context-heldout-r2.json` adds 64 globally test-partitioned sentences per language
and new source (384 sentences); it is **not CC0**. It is a test-only input, not
runtime prediction data; SOURCE and ATTRIBUTION apply to its excerpts too.
