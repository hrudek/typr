# Third-party notices

## Larger corpus context packs (R2-9)

The packs and `context-heldout-r2.json` additionally adapt these sources.
The [SOURCE notice](ios/tools/keyboard_context/SOURCE) records exact URLs, hashes,
modifications, reproduction and open questions; retain it with distributed data.

- **Leipzig Corpora Collection / Deutscher Wortschatz, University of Leipzig**,
  DE/EN news 2024, first 300k rows each: compilation **CC BY**, exact version
  unverified (official page bot-protected); underlying news publishers' rights
  remain unresolved. Working notice link https://creativecommons.org/licenses/by/4.0/
  is not a verified grant for every article. Credit: Dirk Goldhahn, Thomas Eckart
  and Uwe Quasthoff, *Building Large Monolingual Dictionaries at the Leipzig
  Corpora Collection: From 100 to 200 Languages*, LREC 2012.
  https://wortschatz.uni-leipzig.de/en/download
- **Wikipedia contributors**, DE 2021 / EN 2016 100K Leipzig exports: historic
  underlying text **CC BY-SA 3.0 Unported**, https://creativecommons.org/licenses/by-sa/3.0/ .
  Typr's copyrightable derived Wikipedia adaptations are offered under
  **CC BY-SA 4.0** (later-version adaptation under 3.0 §4(b)); preserve changes,
  attribution, share-alike and accompanying WordData license text. This does not
  relicense other sources or app code. Keep the accompanying
  [DE article URL/date list](ios/tools/keyboard_context/credits/wikipedia-de-sources.tsv.gz)
  and [EN list](ios/tools/keyboard_context/credits/wikipedia-en-sources.tsv.gz)
  publicly accessible there or alongside redistributed data. Each article's
  history credits its authors; crawl dates are not immutable revision IDs.
  Whether aggregate counts carry copyright/database rights, mixed-count
  share-alike scope, exact historic attribution and App Store DRM remain open.
- **OPUS / OpenSubtitles.org / subtitle contributors**, OpenSubtitles v2018
  DE/EN mono exports, first 1M lines each: **underlying subtitle/film/translation
  rights retained; no universal CC license verified**. Credit: Pierre Lison and
  Jörg Tiedemann, *OpenSubtitles2016: Extracting Large Parallel Corpora from Movie
  and TV Subtitles*, LREC 2016. https://opus.nlpl.eu/legacy/OpenSubtitles.php and
  https://www.opensubtitles.org/ . Public download/citation/takedown availability
  does not clear all authors' rights. Per-line film/author provenance and rights
  in derived counts/excerpts remain unresolved; mono files omit that mapping.

NFC/lowercase tokenization, global deduplication/split, train-only vocabulary,
display spelling and counts, pruning and TBG1 compilation are modifications.
No endorsement is implied. Retain CV/Tatoeba notices below. Owner R2 permission
allows these sources with explicit open questions; it is not legal clearance.
No upstream code/executables, GPL/AGPL/LGPL code, audio or personal data enter.


Hex+'s own code and the adopted Hex iOS base are covered by the repository's
[MIT license](LICENSE), whose original © Christopher Langton notice is retained.
Base and adoption pins: Hex iOS base `anomalyco/hex` at
`cae389a833178c5e104e6d00db894078afc29ea0` (MIT, [LICENSE](LICENSE)); iOS 26 full
keyboard parity from unmerged anomalyco/hex PR #938 at
`9029d2bcafb5504019d9ad979fa3883dd1659161` (MIT, same license). Adoption history is
in Git and the adopting PRs.

## OpenCode iOS scope port

The iOS scope credits `DotScopeView.swift`, `DictationScopeBar` and
`DotScopeShaders.metal` from [anomalyco/opencode](https://github.com/anomalyco/opencode),
inherited through the Hex iOS base. This port is covered by the MIT license.
The following notice is reproduced exactly from the
[OpenCode LICENSE](https://github.com/anomalyco/opencode/blob/12a661ea40cd5863b271a89bb06b8a3ddb7ab5a0/LICENSE);
this commit pins the verified license text, not a new code adoption.

```text
MIT License

Copyright (c) 2025 opencode

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Automatic return to the host app

Host-app detection and return after a cold-start dictation (`ios/TyprKeyboard/KeyboardHost.swift`,
`ios/TyprKeyboard/KeyboardArbiter.c`, `ios/TyprShared/HostReturnCatalog.swift`,
`ios/Typr/HostReturner.swift`) are translated from three MIT projects.
Their notices are reproduced below.

### iikb

The Overview / Typing / Dictation statistics additionally adapt the large speed /
small figures / daily history card structure and Words–Speed / 7D–30D–90D choices
from `App/Stats/{Overview,StatsSections}.swift` at
[`cf50492d150278e9b1184b4158515170ce485481`](https://github.com/AVGVSTVS96/iikb/tree/cf50492d150278e9b1184b4158515170ce485481).
License re-verified at that revision: **MIT, Copyright (c) 2026 Bassim Shahidy**;
the full iikb notice below applies. Typr's `ActivityStatistics.swift` and
`ActivityStatisticsView.swift` use its own text-free daily populations, fixed-zone
calendar, separate completion/standard/recognized word measures, summed speeds and
60-second thresholds. No combined speed, reconstructed history, device sync,
per-app tracking, resources or additional dependencies are adopted.

The Taps statistics presentation additionally adapts the summary / Heat–Aim–Accuracy /
key-detail / keyboard-halves structure of `App/Stats/TapsPage.swift` and the
Gaussian Cholesky lattice integration in
`Packages/KeyboardModules/Sources/KeyboardCore/Correction/Aim.swift` from
[AVGVSTVS96/iikb at `cf50492d150278e9b1184b4158515170ce485481`](https://github.com/AVGVSTVS96/iikb/tree/cf50492d150278e9b1184b4158515170ce485481).
License verified at that revision: **MIT, Copyright (c) 2026 Bassim Shahidy**;
the full iikb MIT notice below applies. Typr uses its own shared keyboard geometry,
physical saved-model summary and measured raster, includes off-board/modifier mass
in the probability denominator, suppresses sparse estimates, and does not adopt
upstream model memories, raw points, resources, sync or navigation. New/adapted
files: `ios/Typr/{TapStatistics,TapStatisticsBoard,StatisticsView}.swift`.

R2-10 adds evaluation-only independent interpretation of HXN1 layout/LSTM math
from `KeyboardCore/Correction/Network.swift` and reads the training/provenance
notices at `09a2e9cdfbe851adff6c4646333c0a3f74ba8765` (MIT © 2026 Bassim
Shahidy). The existing MIT notice below applies; it is not duplicated. No
upstream weights or new corpus data are distributed. The original tiny MLP and
Swift test forward do not use upstream code files. Locally evaluated weight and
corpus provenance/licenses/open questions are recorded in
`ios/tools/keyboard_neural/SOURCE`;
R2-9's existing data notices are unchanged. NumPy is an optional external offline
training dependency, not vendored or linked into Typr.

R2-6 translates multi-part span caching and endpoint beam retention from
`Packages/KeyboardModules/Sources/KeyboardCore/Correction/Corrector.swift`
(`missedSpaces`, `Run.keep`, lines 513–707, 717–765) at
`09a2e9cdfbe851adff6c4646333c0a3f74ba8765`. Typr's bounded worker-only trie
edit rows and observed-tap gates are original adaptations, not copied files.
No new resources, weights, dependencies or automatic policy are included.
The single MIT notice below (© 2026 Bassim Shahidy) applies.

R2-5 also translates internal-boundary missing-apostrophe candidate recognition
from `Packages/KeyboardModules/Sources/KeyboardCore/Correction/Corrector.swift`
at `09a2e9cdfbe851adff6c4646333c0a3f74ba8765` into bounded, dictionary-backed,
manual-only Typr suggestions. No lexicon, network, weights or builder output is
adopted. The existing MIT notice below (Copyright (c) 2026 Bassim Shahidy),
checked against this pin's LICENSE, applies without duplication.

Undo/literal confirmation and acceptance memory additionally translate
`Packages/KeyboardModules/Sources/KeyboardCore/Correction/TypingMemory.swift:16–114`
and adjacent `Typing/TypingEngine+Words.swift` revert feedback at
`09a2e9cdfbe851adff6c4646333c0a3f74ba8765` (R2-3). Typr adds its own bounded
event-decayed rejected-pair metadata; upstream does not implement that decay.
The same MIT notice below applies; no upstream files/data/dependencies are copied.

The bounded adaptive letter-gap attribution additionally translates posterior ×
prefix continuation scoring and synchronous current-revision maps from
`Correction/KeyMap.swift`, `Correction/LanguageModel.swift` and
`Typing/TypingEngine+Words.swift` (under `Packages/KeyboardModules/Sources/KeyboardCore/`)
at `09a2e9cdfbe851adff6c4646333c0a3f74ba8765`. Typr supplies its own gap-only reach,
strict margins, TSW1/personal indexes and no-self-training policy. P8b's tighter
novel-word/density gates, backspace recovery and original synthetic harm fixtures
are Typr-specific hardening, not additional upstream code or data. No upstream files,
resources, neural weights or dependencies are included. The single full MIT notice
below (Copyright (c) 2026 Bassim Shahidy) covers this adaptation.

From [AVGVSTVS96/iikb](https://github.com/AVGVSTVS96/iikb/blob/f0f1e1f7a29ba915918729115d782ae494fc7244/LICENSE).

```text
MIT License

Copyright (c) 2026 Bassim Shahidy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Dictus

From [getdictus/dictus-ios](https://github.com/getdictus/dictus-ios/blob/8804c3629741b9aebe9475e0b2103769eb969dc5/LICENSE).

```text
MIT License

Copyright (c) 2026 PIVI Solutions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### VivaDicta

The URL table Dictus ports from [n0an/VivaDicta](https://github.com/n0an/VivaDicta/blob/fac7599517d9110d0e8fc7b439b4e60709547144/LICENSE) (Dictus's last sync point).

```text
MIT License

Copyright (c) 2026 Anton Novoselov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Keyboard correction, personal learning, diagnostics and word data

Typr adapts selected bounded trie/edit-search, spatial/prior scoring, pitch-normalized
learning statistics, explicit pending feedback and snapshot-dashboard ideas from
[AVGVSTVS96/iikb at `08df5aa1e698d8587b6dcaef53f5e555ba1fac2a`](https://github.com/AVGVSTVS96/iikb/tree/08df5aa1e698d8587b6dcaef53f5e555ba1fac2a).
The earlier static decoder adoption used `9c74e51f0218a814e2e99756087d3f38ef003614`.
These are rewritten, bounded Typr implementations, not a port of iikb's full
learned/neural model or resources. The existing iikb MIT notice above
(Copyright (c) 2026 Bassim Shahidy), verified against the
[pinned LICENSE](https://github.com/AVGVSTVS96/iikb/blob/08df5aa1e698d8587b6dcaef53f5e555ba1fac2a/LICENSE),
also covers these adaptations; it is not duplicated here.

The local usage-statistics store reuses Typr's existing Darwin snapshot-observer
adaptation, now shared as `StoreChangeObserver`. Its upstream reference is
`Packages/KeyboardModules/Sources/KeyboardStore/MemoryStore.swift` at
[iikb `cf50492d150278e9b1184b4158515170ce485481`](https://github.com/AVGVSTVS96/iikb/blob/cf50492d150278e9b1184b4158515170ce485481/Packages/KeyboardModules/Sources/KeyboardStore/MemoryStore.swift).
The **MIT, Copyright (c) 2026 Bassim Shahidy** license was verified against that
revision's LICENSE; the full notice above covers this reuse. The new text-free tally,
raster aggregates, reset generations and additive store are Typr implementations;
no additional iikb code, resources or accuracy formula were copied for this change.

Typr additionally translates bounded best-first prefix enumeration, physical
held-letter mapping and personal (kept or repeatedly typed) word completions from
`Correction/Lexicon.swift`, `Correction/LetterKeys.swift` and `Correction/TypingMemory.swift`
at [iikb `09a2e9cdfbe851adff6c4646333c0a3f74ba8765`](https://github.com/AVGVSTVS96/iikb/tree/09a2e9cdfbe851adff6c4646333c0a3f74ba8765).
The existing **MIT, Copyright (c) 2026 Bassim Shahidy** notice above was verified
against that revision's LICENSE and also covers these rewritten adaptations.
No additional iikb word data, neural weights or dependencies are included.

R2-1 additionally reviews/translates the independent name/protection-layer idea
from `Packages/KeyboardModules/Sources/KeyboardCore/Correction/Corrector.swift`
(`setNames`, name handling before split/correction), with normalized lexical
query ideas from adjacent `Lexicon.swift`, at
**`09a2e9cdfbe851adff6c4646333c0a3f74ba8765`**. The same **MIT, Copyright (c)
2026 Bassim Shahidy** notice above applies without duplication. Typr's app-only
Contacts/dictation importer, bounded sorted token format and reset controls are
original implementations. No upstream data, code file, neural model, Contacts
service or dependency is bundled.

R2-2 extends that adaptation to the one/two-word context keys and all-endpoint
cleanup in `Correction/TypingMemory.swift` at the same pinned
**`09a2e9cdfbe851adff6c4646333c0a3f74ba8765`**, with P4's existing discounted
backoff from `Correction/LanguageModel.swift`. The existing **MIT, Copyright (c)
2026 Bassim Shahidy** notice covers it without duplication. Typr supplies its own
bounded longest-row selection, trusted chip settlement, migration and tests;
no new third-party data, model, code file or dependency is bundled.

The P4 personal next-word layer additionally translates follower counts and cleanup
from `Packages/KeyboardModules/Sources/KeyboardCore/Correction/TypingMemory.swift`
and discounted backoff from the adjacent `LanguageModel.swift` at
**`09a2e9cdfbe851adff6c4646333c0a3f74ba8765`**. The same **MIT, Copyright (c)
2026 Bassim Shahidy** notice above applies and was checked against that pin's LICENSE;
it is not duplicated. Typr supplies its own stricter trust protocol, event-count
ageing, bounds, schema migration and deletion UI. No upstream resources, app
histories, trigrams, neural weights or executable dependency are adopted.

The aggregate-aim extension additionally translates full covariance, pooled shrinkage,
multiple-timescale aim, predictive fixed-share weighting and covariance-display/test
ideas (rewritten with Typr's shared 40/8-label affine drift, not upstream per-key
30/3 banks) from `TouchModel.swift`, `Aim.swift`, `Tap.swift` and `TypingModelTests.swift` at
[iikb `09a2e9cdfbe851adff6c4646333c0a3f74ba8765`](https://github.com/AVGVSTVS96/iikb/tree/09a2e9cdfbe851adff6c4646333c0a3f74ba8765),
MIT, Copyright (c) 2026 Bassim Shahidy. The same full MIT notice above applies.
No upstream recent-tap
reservoir, executable dependency, neural weights, or language resource is adopted.

The deferred suggestion pipeline additionally translates snapshot/job/revision-checked
finish and compatible-cache adoption from
[AVGVSTVS96/iikb at `09a2e9cdfbe851adff6c4646333c0a3f74ba8765`](https://github.com/AVGVSTVS96/iikb/tree/09a2e9cdfbe851adff6c4646333c0a3f74ba8765),
`TypingEngine+Words.swift` and `FullKeyboardViewController.swift`. The existing
**MIT, Copyright (c) 2026 Bassim Shahidy** notice above also covers this rewritten
adaptation. No upstream controller, resources or neural weights are bundled.

Exact two-part omitted-space suggestions, whole-vs-split comparison and owned boundary
revert additionally translate ideas from `Correction/Corrector.swift`,
`Typing/TypingEngine+Words.swift` and boundary scenarios in `AutocorrectTests.swift` at
[iikb `09a2e9cdfbe851adff6c4646333c0a3f74ba8765`](https://github.com/AVGVSTVS96/iikb/tree/09a2e9cdfbe851adff6c4646333c0a3f74ba8765).
The same **MIT, Copyright (c) 2026 Bassim Shahidy** notice above, verified against
that pin's LICENSE, applies without duplication. These are rewritten manual-only
Typr algorithms, not copied files, upstream test data, language data or dependencies.
The spatial boundary extension additionally translates whole-versus-separate tap
likelihood comparison, geometric Space adjacency, retained actual boundary taps and
owned suffix/revert from that pin's `Correction/Corrector.swift` (513–553, 625–707)
and `Typing/TypingEngine+Words.swift` (259–417). These are rewritten, bounded,
suggestion-only Typr algorithms, with no upstream data/model/dependency, inferred
Space training or wholesale file copy. The same **MIT, Copyright (c) 2026 Bassim
Shahidy** notice above was checked against the pinned LICENSE and covers this
adaptation without duplication.
The small closed-class short-word supplement is Typr original hand-curated work.
P5b additionally translates two-part conditional scoring and whole comparison from
that pin's `Corrector.swift` / `LanguageModel.swift`, using Typr's existing separately
licensed TBG1 corpus model, lexical/code-switch backoff and manual-only policy.
No new upstream data, neural weights, personal context storage or dependencies;
the same MIT © 2026 Bassim Shahidy notice above applies.

The bundled `keyboard-de.words` and `keyboard-en.words` are derived from **Hermit Dave /
FrequencyWords**, revision `525f9b560de45753a5ea01069454e72e9aa541c6`, 2018 DE/EN
50k lists, originating from **OpenSubtitles 2018 / OpenSubtitles**. **Their content
is CC BY-SA 4.0, not MIT**, as declared in the pinned source README:
https://github.com/hermitdave/FrequencyWords/blob/525f9b560de45753a5ea01069454e72e9aa541c6/README.md#license .
Typr normalizes/filters words and compiles the counts into a trie; the derived data
remains CC BY-SA 4.0. Attribution, exact source links, modifications, hashes and
reproduction instructions are in
[ios/TyprShared/FullKeyboard/WordData/README.md](ios/TyprShared/FullKeyboard/WordData/README.md).
That notice and the [full license](ios/TyprShared/FullKeyboard/WordData/CC-BY-SA-4.0.txt)
are bundled with the data in both the app and keyboard. These notices do not
claim endorsement by the original authors. Typr's own decoder/compiler code
remains MIT. No iikb model or word resources, wordfreq or Python package dependency
is bundled.

## Offline corpus context suggestions

Typr additionally translates absolute-discount backoff and bounded contextual
candidate ranking ideas from iikb `LanguageModel.swift` / `Corrector.swift` at
[`09a2e9cdfbe851adff6c4646333c0a3f74ba8765`](https://github.com/AVGVSTVS96/iikb/tree/09a2e9cdfbe851adff6c4646333c0a3f74ba8765),
MIT, **Copyright (c) 2026 Bassim Shahidy**. The full existing iikb notice above
covers this adaptation; no duplicate notice or iikb resource is included.

## Swipe typing (FUTO Swipe encoder, iikb swipe code)

`ios/TyprShared/FullKeyboard/SwipeEncoder.swift` and `SwipeDecoder.swift` translate the
pure-Swift swipe encoder kernels, path resampling and CTC prefix beam search over a word trie
from iikb `Packages/KeyboardModules/Sources/KeyboardCore/Correction/{Swipe,SwipeKernels,SwipeLayout,SwipeMath,SwipeNetwork,SwipeSearch}.swift`
and `Tools/SwipeBuilder` at
[`f42bad59ce3c0f6f35c7ec0cf727d0b67c146608`](https://github.com/AVGVSTVS96/iikb/tree/f42bad59ce3c0f6f35c7ec0cf727d0b67c146608),
MIT, **Copyright (c) 2026 Bassim Shahidy** (license re-verified at that revision; the full
iikb notice above applies). Typr's changes: its own TSE1 weight file, per-language folded
ä/ö/ü/ß tries built from Typr's word lists, bilingual merging and no decoder model.
No iikb swipe file (`*.swipe`) or word list is bundled.

`ios/TyprShared/FullKeyboard/SwipeModel/swipe-encoder.tse` holds the encoder weights of
**FUTO Swipe** (`honorable_sturgeon/model_fp32.pte`) from
[futo-org/futo-swipe at `0a9a44bbe4d5b8aa8d1ff579ffc40d4861ae2467`](https://huggingface.co/futo-org/futo-swipe/tree/0a9a44bbe4d5b8aa8d1ff579ffc40d4861ae2467),
sha256 `725242bab5d14345e96ff214e8de2bfbc1f962c232d320df9c24cb82ffd1fbaf`, under the
**FUTO Model Weights License 1.0** (custom, permissive, not GPL-family). The weights were
modified: converted and repacked by `ios/tools/swipe_model/build.py` (transposed, zero-padded
float32, not retrained); FUTO's decoder model is not included. The license requires a visible
end-user notice: Typr's keyboard settings show “Swipe typing powered by FUTO Swipe.” The full
license text and the modification notice ship next to the weights in
[ios/TyprShared/FullKeyboard/SwipeModel/LICENSE-FUTO-SWIPE.txt](ios/TyprShared/FullKeyboard/SwipeModel/LICENSE-FUTO-SWIPE.txt),
in both the app and the keyboard. FUTO does not endorse Typr.

The evaluation swipes used during development (FUTO
[swipe.futo.org dataset](https://huggingface.co/datasets/futo-org/swipe.futo.org) at
`d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566`, MIT) are not bundled or committed.

The separate `keyboard-de.tbg` / `keyboard-en.tbg` statistics adapt:

- **Common Voice and its sentence-collector contributors**, DE/EN text at
  `cd9dbfeeed7f2c377d6e9792f4d7a583c0ad3538`, **CC0 1.0 Universal**:
  https://creativecommons.org/publicdomain/zero/1.0/ .
- **Tatoeba contributors named in the accompanying
  [tatoeba-contributors.tsv](ios/TyprShared/FullKeyboard/WordData/tatoeba-contributors.tsv)**,
  German and English detailed exports dated 7 November 2026, retrieved
  12 November 2026 UTC, **Creative Commons Attribution 2.0 France (CC BY 2.0 FR)**:
  https://creativecommons.org/licenses/by/2.0/fr/ ; full legal code:
  https://creativecommons.org/licenses/by/2.0/fr/legalcode.fr .
  Official source and terms: https://tatoeba.org/en/downloads and
  https://tatoeba.org/en/terms_of_use#section-6 .

The [full accompanying attribution](ios/TyprShared/FullKeyboard/WordData/ATTRIBUTION.md)
contains exact source URLs, changes and distribution conditions, with the actual
7,206-owner roster bundled in app and keyboard. Preserve the accompanying
[training sentence-ID / owner / URL / per-sentence-license mapping](ios/tools/keyboard_context/credits/tatoeba-training-attribution.tsv.gz)
at an accessible public data/credits location or accompany redistributed data with
it; generic Tatoeba credit alone is insufficient. Official CC0 subset rows are
labelled in that mapping. Tatoeba-derived portions are **not CC0 or MIT**. No
endorsement is implied. Preserve applicable credits/license links and do not add
restrictions defeating the granted rights. No audio enters these sidecars.
R2-9 additionally incorporates share-alike Wikipedia-derived counts; see the
source-specific notice below. The unchanged FrequencyWords `.words` files retain
separate CC BY-SA terms. `context-heldout-cc0.json` is a Common Voice CC0 test-only fixture;
`swift-reference-vectors.json` is Typr-generated numeric reference output.

## FluidAudio 0.15.5

The iPhone app uses the Swift package
[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio/tree/v0.15.5),
pinned to 0.15.5 in `ios/project.yml`, under
[Apache License 2.0](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/LICENSE).
Its package manifest has no external package dependencies. It includes vendored
components, whose [license notices](https://github.com/FluidInference/FluidAudio/tree/v0.15.5/ThirdPartyLicenses)
must accompany redistribution:

- `ThirdPartyLicenses/fastcluster-LICENSE.md`: BSD-2-Clause, reproduced below.
- `ThirdPartyLicenses/vbx-LICENSE.md`: Apache-2.0;
  Copyright 2021-2024 BUT Speech@FIT (original VBx project).
  [Full pinned license](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/ThirdPartyLicenses/vbx-LICENSE.md).

### fastcluster notice (from FluidAudio v0.15.5)

Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## NVIDIA Parakeet TDT 0.6B v2 Core ML

FluidAudio downloads
[FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
at runtime; model weights are not bundled in this repository.
The NVIDIA Parakeet TDT 0.6B v2 model is licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
The Core ML conversion is provided by FluidInference.
[Original NVIDIA model and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2).

## NVIDIA Parakeet TDT 0.6B v3 Core ML

Typr downloads this at runtime, only when the user taps Download; nothing is
bundled in this repository or the app: `Preprocessor`, `Encoder`, `Decoder` and
`JointDecisionv3` (`.mlmodelc`) and `parakeet_vocab.json` from
[FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe)
at revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`.
The NVIDIA Parakeet TDT 0.6B v3 model is licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
The Core ML conversion is provided by FluidInference.
[Original NVIDIA model and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

## Orukeet r3 Core ML (INT8 encoder)

Typr downloads this at runtime, only when the user taps Download; nothing is
bundled in this repository or the app: the archive
`coreml/orukeet-r3-coreml-int8sym-encoder-only-experimental-20260920-deflated.zip`
(SHA-256 `24df9ff76f00f86f9ae1fd601cbbcab1d1eac98c7e8107de67444a7858d88b8b`) from
[oruk/orukeet](https://huggingface.co/oruk/orukeet/tree/419d7f79e290127e202a0f610509868d314743eb/coreml)
at revision `419d7f79e290127e202a0f610509868d314743eb`. Typr unpacks its
`Preprocessor`, `Encoder`, `Decoder` and `JointDecisionv3` packages and
`parakeet_vocab.json`, and compiles the packages on the iPhone.
Orukeet is Oruk AI's adaptation of NVIDIA Parakeet TDT 0.6B v3; the Orukeet
weights are licensed under
[Creative Commons Attribution-ShareAlike 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
(the archive's `LICENSE-WEIGHTS`), with the Core ML conversion and optimizations by
Oruk AI, based on Fluid Inference's Core ML graphs. NVIDIA retains copyright in
the NVIDIA Parakeet TDT 0.6B v3 model, licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)
([original NVIDIA model and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)).
No endorsement by NVIDIA is implied.

`ios/Typr/OrukeetModelSpec.swift` and `ios/Typr/TdtV3Transcriber.swift` follow the
local loading and on-device compilation steps of Oruk AI's `OrukeetLocalModels`
([OrukeetEngine.swift](https://github.com/Oruk-AI/orukeet/blob/decfb6e4b50a41fbddadf8a9cf12beadf06ae2f1/export/coreml/benchmark/Sources/OrukeetCoreML/OrukeetEngine.swift)
at commit `decfb6e4b50a41fbddadf8a9cf12beadf06ae2f1`), MIT license
([Oruk-AI/orukeet LICENSE](https://github.com/Oruk-AI/orukeet/blob/decfb6e4b50a41fbddadf8a9cf12beadf06ae2f1/LICENSE)).

## Cohere Transcribe 03-2026 Core ML

Typr downloads this at runtime, only when the user taps Download; nothing is
bundled in this repository or the app: `q8/cohere_encoder.mlmodelc`,
`q8/cohere_decoder_cache_external_v2.mlmodelc` and `vocab.json` from
[FluidInference/cohere-transcribe-03-2026-coreml](https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml/tree/e1ce10d4cae2ca9a8b36cef5786fa3660f070050)
at revision `e1ce10d4cae2ca9a8b36cef5786fa3660f070050`.
The base Cohere Transcribe weights are licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
The Core ML conversion is provided by FluidInference. Its repository metadata
says Apache-2.0, but the License section of its
[README at that revision](https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml/blob/e1ce10d4cae2ca9a8b36cef5786fa3660f070050/README.md#license)
says [CC-BY-NC-4.0](https://creativecommons.org/licenses/by-nc/4.0/)
(non-commercial). Typr is for personal use, so either license allows it.
[Original Cohere Labs model and attribution](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026).

## ZIPFoundation 0.9.20

The iPhone app (only the Typr app target) uses the Swift package
[weichsel/ZIPFoundation](https://github.com/weichsel/ZIPFoundation/tree/0.9.20),
pinned with `exactVersion: 0.9.20` in `ios/project.yml` (tag commit
`22787ffb59de99e5dc1fbfe80b19c97a904ad48d`), under the MIT license below.

```text
MIT License

Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Argmax OSS (WhisperKit) 1.1.1

The iPhone app (only the Typr app target, not the keyboard or widgets) uses the
`WhisperKit` product of the Swift package
[argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.1),
pinned with `exactVersion: 1.1.1` in `ios/project.yml` (tag commit
`1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`), under the MIT license below.
Portions under `Sources/ArgmaxCore/External` (the Hub client and tokenizers that
WhisperKit uses) are derived from
[huggingface/swift-transformers](https://github.com/huggingface/swift-transformers),
Copyright 2022 Hugging Face SAS, modified by Argmax, Inc., and licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0); the package's
[NOTICES](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/NOTICES) file carries
that notice and the full license text and must accompany redistribution.

`ios/Typr/WhisperTokenizer.swift` follows the special-token table and language-token
set of WhisperKit's `WhisperTokenizerWrapper` (`Sources/WhisperKit/Core/Models.swift`
at v1.1.1).

```text
MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Whisper Large V3 Turbo model and tokenizer

Typr downloads these at runtime, only when the user taps Download; nothing is
bundled in this repository or the app:

- Core ML model folder `openai_whisper-large-v3-v20240930_626MB` from
  [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-large-v3-v20240930_626MB)
  at revision `0f63a7800b00dd0226abd051b906c246e1907482`, MIT license (Core ML
  conversion by Argmax, Inc.). It is a conversion of OpenAI's Whisper Large V3 Turbo
  ([openai/whisper](https://github.com/openai/whisper), model weights released by
  OpenAI under the MIT license).
- `config.json`, `tokenizer.json` and `tokenizer_config.json` from
  [openai/whisper-large-v3](https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1)
  at revision `06f233fe06e710322aca913c1bc4249a0d71fce1`, Apache License 2.0.

The OpenAI Whisper model-weight license is reproduced below (the Argmax Core ML
conversion is covered by the Argmax MIT notice above):

```text
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hex dictation rewrite prompt

Typr's AI cleanup prompt (`ios/Typr/CleanupPrompt.swift`) and its numbers-only skip
(`ios/Typr/CleanupNumbers.swift`) are taken word for word from
[anomalyco/hex](https://github.com/anomalyco/hex) at
`b5b5a2715853456f3f114d094927a9defca083ff`: `PROTOCOL_PROMPT`, `prompt()`,
`vocabulary_lines()` and `numbers_only()` in `src/dictation/processor.rs`, `section()` and
`neutralized()` in `src/dictation/caret_prompt.rs`, the default mode prompt in
`src/app_settings/dictation_processing.rs` and the caret caps in `src/accessibility.rs`.
MIT, © Christopher Langton, the same license as this repository ([LICENSE](LICENSE)).
