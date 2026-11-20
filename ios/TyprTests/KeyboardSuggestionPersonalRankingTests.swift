import Foundation
import XCTest
@testable import Typr

/// Personal completion ranking (#101): injected checkers and personal snapshots, synthetic
/// public fixtures. Not Apple's dictionaries, real typing, simulator or iPhone evidence.
@MainActor
final class KeyboardSuggestionPersonalRankingTests: XCTestCase {
    private final class Checker: TextChecking {
        var valid: Set<String>
        var completionLists: [String: [String]]
        var guessLists: [String: [String]]
        var calls = 0
        init(valid: Set<String> = [], completions: [String: [String]] = [:], guesses: [String: [String]] = [:]) {
            self.valid = valid
            completionLists = completions
            guessLists = guesses
        }
        func isWordValid(_ word: String) -> Bool { calls += 1; return valid.contains(word) }
        func guesses(for word: String) -> [String] { calls += 1; return guessLists[word] ?? [] }
        func completions(for prefix: String) -> [String] {
            calls += 1
            return completionLists[PersonalLexiconSnapshot.normalize(prefix)] ?? []
        }
    }

    /// Valid when the bundled corpus has the word (or it is explicitly trusted); no system completions.
    private final class CorpusChecker: TextChecking {
        let lexicon: SpatialWordLexicon?
        let trusted: Set<String>
        init(_ lexicon: SpatialWordLexicon?, trusted: Set<String> = []) { self.lexicon = lexicon; self.trusted = trusted }
        func isWordValid(_ word: String) -> Bool {
            trusted.contains(word) || lexicon?.logPrior(for: word.lowercased()) != nil
        }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private let grid = KeyboardLayout(width: 393, orientation: .portrait, layer: .letters, field: .text,
                                      showsGlobe: false, showsStrip: true)

    func testRepeatedExplicitAcceptanceStrengthensCompletion() {
        let (session, _) = session()
        let checker = Checker(valid: ["he"], completions: ["he": ["help", "hello"]])
        let ac = AutocorrectEngine(checker: checker, learning: session, spatialDecoder: nil)
        let before = alternatives(ac, "he")
        XCTAssertEqual(before, ["help", "hello"])
        let pick = KeyboardSuggestion(displayText: "hello", replacement: "hello", kind: .secondary, isCompletion: true)
        for _ in 0..<8 { ac.recordSuggestionFeedback(pick, literal: "he", evidence: nil) }
        let after = alternatives(ac, "he")
        XCTAssertEqual(after.first, "hello")
        XCTAssertEqual(session.model.lexicon.counts["hello"], 8)
        XCTAssertEqual(session.diagnostics.acceptedLabels, 0)
    }

    // MARK: - Helpers

    private func session(learning: Bool = true) -> (KeyboardLearningSession, UserDefaults) {
        let defaults = UserDefaults(suiteName: "typr.tests.personal-ranking.\(UUID().uuidString)")!
        defaults.set(learning, forKey: "keyboard.personalLearning")
        return (KeyboardLearningSession(defaults: defaults), defaults)
    }

    private func seed(_ session: KeyboardLearningSession, counts: [String: Int], kept: [String] = []) {
        for (word, count) in counts.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<count { session.model.recordWord(word) }
        }
        for word in kept { _ = session.model.keep(word) }
    }

    private func strip(_ ac: AutocorrectEngine, _ text: String) -> [KeyboardSuggestion] {
        ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default)
    }

    private func alternatives(_ ac: AutocorrectEngine, _ text: String) -> [String] {
        strip(ac, text).filter { $0.kind != .keepLiteral }.map(\.replacement)
    }

    private func evidence(_ typed: String) -> KeyboardTouchWord {
        let samples = typed.map { letter in
            let key = grid.key(.character(String(letter).lowercased()))!
            return KeyboardTouchWord.Sample(text: String(letter), point: CGPoint(x: key.frame.midX, y: key.frame.midY),
                                            key: key)
        }
        return KeyboardTouchWord(layout: grid, samples: samples)
    }

    private func track(_ word: KeyboardTouchWord, engine: AutocorrectEngine) {
        var before = ""
        for sample in word.samples {
            let after = before + sample.text
            engine.touchInput.append(text: sample.text, point: sample.point, key: sample.key,
                                     layout: word.layout, before: before, after: after)
            before = after
        }
    }

    private func bundled() throws -> [SpatialWordDecoder.Language: SpatialWordLexicon] {
        try XCTUnwrap(BundledKeyboardData.lexicons)
    }

    // MARK: - Prefix index

    func testIndexOrdersByCountThenKeptThenSpellingAndExcludesTheTypedWord() {
        let snapshot = PersonalLexiconSnapshot(
            kept: ["tassilo"],
            counts: ["tastatur": 5, "tastaturen": 5, "taste": 9, "tasse": 2, "tasche": 1, "hund": 4],
            rejected: [])
        let index = snapshot.scan.completions
        for prefix in ["tas", "TAS", "Tas"] {
            XCTAssertEqual(index.completions(for: prefix).map(\.word),
                           ["taste", "tastatur", "tastaturen", "tasse", "tassilo"], prefix)
        }
        XCTAssertEqual(index.completions(for: "taste").map(\.word), [], "The typed word itself is not a completion")
        XCTAssertEqual(index.completions(for: "tast").map(\.word), ["taste", "tastatur", "tastaturen"])
        XCTAssertEqual(index.completions(for: "t").map(\.word), [], "Two letters minimum")
        XCTAssertEqual(index.completions(for: String(repeating: "t", count: 32)).map(\.word), [])
        XCTAssertEqual(index.completions(for: "ta1").map(\.word), [])
        XCTAssertFalse(index.entries.contains { $0.word == "tasche" }, "Counted once is below the personal threshold")
    }

    func testIndexHandlesUmlautsSharpSAndDecomposedInput() {
        let snapshot = PersonalLexiconSnapshot(
            kept: [], counts: ["straße": 3, "strand": 4, "müsli": 2, "mühle": 6, "muster": 3], rejected: [])
        let index = snapshot.scan.completions
        XCTAssertEqual(index.completions(for: "stra").map(\.word), ["strand", "straße"])
        XCTAssertEqual(index.completions(for: "STRA").map(\.word), ["strand", "straße"])
        XCTAssertEqual(index.completions(for: "straß").map(\.word), ["straße"])
        XCTAssertEqual(index.completions(for: "mü").map(\.word), ["mühle", "müsli"])
        XCTAssertEqual(index.completions(for: "mu\u{308}").map(\.word), ["mühle", "müsli"], "NFD prefix")
        XCTAssertEqual(index.completions(for: "MÜ").map(\.word), ["mühle", "müsli"])
        XCTAssertEqual(index.completions(for: "mu").map(\.word), ["muster"], "u and ü are different spellings")
    }

    func testIndexMatchesBruteForceOracleOnFullSnapshotAndStaysBounded() {
        var counts: [String: Int] = [:]
        var kept: Set<String> = []
        var state: UInt64 = 0x5459_5052_5f50_3262
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let letters = Array("aeinrstuäöß")
        while Set(counts.keys).union(kept).count < 2_000 {
            let length = 3 + Int(next() % 6)
            let word = String((0..<length).map { _ in letters[Int(next() % UInt64(letters.count))] })
            if next() % 9 == 0 { kept.insert(word) } else { counts[word] = 2 + Int(next() % 12) }
        }
        let snapshot = PersonalLexiconSnapshot(kept: kept, counts: counts, rejected: [])
        let index = snapshot.scan.completions
        XCTAssertEqual(Set(counts.keys).union(kept).count, 2_000, "Overlapping keeps/counts must not shrink the full-cap fixture")
        XCTAssertEqual(index.entries.count, 2_000)
        XCTAssertLessThanOrEqual(index.entries.count, PersonalCompletionIndex.capacity)
        var prefixes = 0, nonEmpty = 0
        for a in letters { for b in letters {
            for prefix in ["\(a)\(b)", "\(a)\(b)\(letters[prefixes % letters.count])"] {
                let expected = index.entries.filter { $0.word.hasPrefix(prefix) && $0.word != prefix }
                    .sorted { lhs, rhs in
                        if lhs.count != rhs.count { return lhs.count > rhs.count }
                        if lhs.kept != rhs.kept { return lhs.kept }
                        return lhs.word < rhs.word
                    }.prefix(PersonalCompletionIndex.resultLimit).map(\.word)
                let actual = index.completions(for: prefix).map(\.word)
                XCTAssertEqual(actual, Array(expected), prefix)
                prefixes += 1
                if !actual.isEmpty { nonEmpty += 1 }
            }
        } }
        XCTAssertGreaterThan(nonEmpty, 50)
        XCTAssertLessThan(index.payloadBytes, 192 * 1024)
    }

    func testPromotionTiesKeepBaselineOrderAndAdditionsFollowEqualBaselineWeights() {
        let personal = PersonalLexiconSnapshot(kept: ["helios"], counts: ["helmet": 3, "helpful": 3, "help": 1, "helga": 3],
                                               rejected: [])
        let additions = personal.scan.completions.completions(for: "hel")
        let promotions = KeyboardCompletionRanking.promotions(
            token: "hel", baseline: ["help", "hello", "helmet", "helpful", "Helmet"], additions: additions,
            personal: personal)
        XCTAssertEqual(promotions, [
            .init(word: "helmet", isAddition: false), .init(word: "helpful", isAddition: false),
            .init(word: "helga", isAddition: true), .init(word: "helios", isAddition: true)])
        XCTAssertEqual(KeyboardCompletionRanking.promotions(token: "hel", baseline: ["help", "hello"], additions: [],
                                                           personal: .empty), [])
    }

    // MARK: - Strip integration

    func testSwitchOffGivesIdenticalSystemAndTrieOrder() throws {
        let words = try bundled()
        let checker = { Checker(valid: ["help", "hello"],
                                completions: ["hel": ["helpful", "hello", "help", "helmet"], "tas": ["task", "taste", "tasks"],
                                              "kno": ["know", "knowledge", "knot"]]) }
        let tokens = ["hel", "Hel", "tas", "kno", "fen", "Fen", "stra", "mü", "zz", "ha"]
        let personal = ["helmet": 6, "knot": 4, "fenster": 3, "fensterbank": 9, "tassen": 5, "mühle": 3, "haushalt": 7]
        func make(_ session: KeyboardLearningSession) -> AutocorrectEngine {
            let ac = AutocorrectEngine(checker: checker(), learning: session,
                                       spatialDecoder: SpatialWordDecoder(lexicons: words))
            ac.german = GermanAutocorrect(checker: Checker(valid: ["Fenster", "Mühle", "Haushalt"]))
            return ac
        }
        let reference = make(KeyboardLearningSession())
        let (offSession, defaults) = session(learning: true)
        seed(offSession, counts: personal, kept: ["helium"])
        defaults.set(false, forKey: "keyboard.personalLearning")
        offSession.refresh()
        XCTAssertFalse(offSession.isLearningEnabled)
        let off = make(offSession)
        let (onSession, _) = session(learning: true)
        seed(onSession, counts: personal, kept: ["helium"])
        let on = make(onSession)
        var changed = 0
        for token in tokens {
            let baseline = strip(reference, token)
            XCTAssertEqual(strip(off, token), baseline, token)
            XCTAssertFalse(strip(off, token).contains(where: \.isPersonal))
            if strip(on, token) != baseline { changed += 1 }
        }
        XCTAssertGreaterThanOrEqual(changed, 5, "Learning on must actually rerank these fixtures")
    }

    func testPersonalCountsMoveSystemCompletionsUpWithStableTiesAndKeptWords() {
        let (learning, _) = session()
        seed(learning, counts: ["helmet": 3, "helpful": 3])
        let checker = Checker(completions: ["hel": ["helpful", "hello", "help", "helmet"]])
        let ac = AutocorrectEngine(checker: checker, learning: learning, spatialDecoder: nil)
        // Baseline (length, then alphabetical): help, hello, helmet, helpful.
        let chips = strip(ac, "hel")
        XCTAssertEqual(chips.map(\.replacement), ["hel", "helmet", "helpful"], "Equal counts keep system order")
        XCTAssertTrue(chips.dropFirst().allSatisfy { $0.isCompletion && $0.isPersonal && !$0.willAutoReplace })
        seed(learning, counts: ["helpful": 2], kept: ["hello"])
        XCTAssertEqual(alternatives(ac, "hel"), ["helpful", "helmet"], "Higher count wins")
        XCTAssertEqual(alternatives(ac, "Hel"), ["Helpful", "Helmet"], "Typed capital applies")
        let keptOnly = AutocorrectEngine(checker: checker, learning: { let (s, _) = session(); seed(s, counts: [:], kept: ["hello"]); return s }(),
                                         spatialDecoder: nil)
        XCTAssertEqual(alternatives(keptOnly, "hel"), ["hello", "help"], "A kept word moves up; others keep order")
    }

    func testMissingPersonalWordsJoinWithDictionaryCasingIncludingGermanNounsAndSharpS() {
        let (learning, _) = session()
        seed(learning, counts: ["tastatur": 4, "hendrik": 3, "straße": 3, "müsli": 2, "berlin": 5])
        let ac = AutocorrectEngine(checker: Checker(valid: ["Berlin"]), learning: learning, spatialDecoder: nil)
        ac.german = GermanAutocorrect(checker: Checker(valid: ["Tastatur", "Straße", "Müsli"]))
        XCTAssertEqual(alternatives(ac, "tast"), ["Tastatur"], "German noun capital from the dictionary")
        XCTAssertEqual(alternatives(ac, "Tast"), ["Tastatur"])
        XCTAssertEqual(alternatives(ac, "hen"), ["hendrik"], "Case-folded store follows the typed case")
        XCTAssertEqual(alternatives(ac, "Hen"), ["Hendrik"])
        XCTAssertEqual(alternatives(ac, "ber"), ["Berlin"], "English proper noun capital from the dictionary")
        XCTAssertEqual(alternatives(ac, "stra"), ["Straße"])
        XCTAssertEqual(alternatives(ac, "Stra"), ["Straße"])
        XCTAssertEqual(alternatives(ac, "mu\u{308}").map { $0.precomposedStringWithCanonicalMapping }, ["Müsli"])
        XCTAssertTrue(strip(ac, "tast").dropFirst().allSatisfy { $0.isPersonal && $0.isCompletion })
        let noGerman = AutocorrectEngine(checker: Checker(), learning: learning, spatialDecoder: nil)
        XCTAssertEqual(alternatives(noGerman, "tast"), ["tastatur"], "No dictionary: no invented capital")
    }

    func testContactsRejectionsAndAutomaticReplacementAreUnchanged() {
        let (learning, _) = session()
        seed(learning, counts: ["helmet": 5, "teheran": 6, "helga": 4])
        let checker = Checker(valid: ["the", "hello", "help"],
                              completions: ["hel": ["hello", "help", "helmet"], "teh": ["teheran"]],
                              guesses: ["teh": ["the"]])
        let ac = AutocorrectEngine(checker: checker, learning: learning, spatialDecoder: nil)
        let (offLearning, _) = session(learning: false)
        let off = AutocorrectEngine(checker: checker, learning: offLearning, spatialDecoder: nil)
        for engine in [ac, off] { engine.loadLexiconEntries([(userInput: "Helmut", documentText: "Helmut")]) }
        XCTAssertEqual(alternatives(ac, "hel"), ["Helmut", "helmet"], "Contacts keep precedence")
        XCTAssertEqual(alternatives(off, "hel"), ["Helmut", "help"])
        learning.rejectCorrection(typed: "hel", replacement: "helmet")
        XCTAssertEqual(alternatives(ac, "hel"), ["Helmut", "helga"], "A rejected pair is never offered")
        // Automatic replacement: identical primary, highlight and boundary result with learning on/off.
        let onChips = strip(ac, "teh"), offChips = strip(off, "teh")
        XCTAssertEqual(onChips[1], offChips[1])
        XCTAssertTrue(onChips[1].willAutoReplace)
        XCTAssertEqual(onChips.last?.replacement, "teheran")
        XCTAssertEqual(onChips.last?.willAutoReplace, false)
        let a = ac.replacementOnSpace(beforeInput: "teh", field: .text, autocorrectionType: .default)
        let b = off.replacementOnSpace(beforeInput: "teh", field: .text, autocorrectionType: .default)
        XCTAssertEqual(a?.replacement, "the")
        XCTAssertEqual(a?.replacement, b?.replacement)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "tehe", field: .text, autocorrectionType: .default))
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "helm", field: .text, autocorrectionType: .default),
                     "A personal completion never applies at Space")
    }

    func testPersonalCompletionPickCountsWordOnlyAndIsCountedSeparately() throws {
        let (learning, _) = session()
        seed(learning, counts: ["keyboard": 3])
        let ac = AutocorrectEngine(checker: Checker(completions: ["keyb": ["keybinding"]]), learning: learning,
                                   spatialDecoder: nil)
        let taps = evidence("keyb")
        track(taps, engine: ac)
        let chips = strip(ac, "keyb")
        let personal = try XCTUnwrap(chips.first { $0.replacement == "keyboard" })
        let system = try XCTUnwrap(chips.first { $0.replacement == "keybinding" })
        XCTAssertTrue(personal.isPersonal)
        XCTAssertFalse(system.isPersonal)
        ac.recordSuggestionFeedback(personal, literal: "keyb", evidence: taps)
        XCTAssertEqual(learning.model.lexicon.counts["keyboard"], 4)
        XCTAssertEqual(learning.diagnostics[.manualCompletionPick], 1)
        XCTAssertEqual(learning.diagnostics[.personalCompletionPick], 1)
        XCTAssertEqual(learning.diagnostics.acceptedLabels, 0, "A completion pick teaches no touch labels")
        XCTAssertTrue(learning.model.state.layouts.isEmpty)
        ac.recordSuggestionFeedback(system, literal: "keyb", evidence: taps)
        XCTAssertEqual(learning.diagnostics[.manualCompletionPick], 2)
        XCTAssertEqual(learning.diagnostics[.personalCompletionPick], 1)
        XCTAssertEqual(learning.diagnostics.acceptedLabels, 0)
    }

    func testWorkerRetrievesCompletionsWithoutCheckerAndMatchesSynchronousStrip() async throws {
        let words = try bundled()
        let worker = KeyboardSuggestionWorker()
        for (typed, noisy) in [("fens", false), ("hau", false), ("keyb", true), ("tast", false), ("stra", false)] {
            func make() -> (AutocorrectEngine, Checker) {
                let (learning, _) = session()
                seed(learning, counts: ["fensterbank": 4, "haushalt": 3, "keyboard": 2, "tastatur": 5, "strandkorb": 3])
                let checker = Checker(completions: ["hau": ["haul", "haunt"], "keyb": ["keyboards"]])
                let ac = AutocorrectEngine(checker: checker, learning: learning,
                                           spatialDecoder: SpatialWordDecoder(lexicons: words))
                ac.german = GermanAutocorrect(checker: Checker(valid: ["Fensterbank", "Haushalt", "Tastatur", "Strandkorb"]))
                return (ac, checker)
            }
            let (sync, _) = make()
            let (deferred, checker) = make()
            let taps = evidence(noisy ? "kryb" : typed)
            let token = noisy ? "kryb" : typed
            track(taps, engine: sync)
            track(taps, engine: deferred)
            let ownership = KeyboardSuggestionOwnership(
                engine: UUID(), revision: 1, context: token, token: token, field: .text, permitsCorrection: true,
                configuration: deferred.suggestionConfiguration, learning: deferred.learning.generation,
                feedbackEpoch: deferred.learning.feedbackEpoch, resources: deferred.spatialDecoder?.resourceRevision ?? -1,
                layout: grid)
            let calls = checker.calls
            let request = deferred.suggestionRequest(ownership: ownership, evidence: taps)
            XCTAssertEqual(checker.calls, calls, "Preparation stays checker-free")
            XCTAssertNotNil(request.completion?.personal)
            var completed: KeyboardSuggestionWorker.Result?
            worker.submit(prepare: { request }, finish: { completed = $0 })
            await worker.waitUntilIdle()
            let result = try XCTUnwrap(completed)
            XCTAssertNotNil(result.completion, "Corpus/personal retrieval ran in the worker")
            XCTAssertEqual(deferred.finishSuggestions(result), strip(sync, token), token)
        }
    }

    // MARK: - Evaluation

    /// A synthetic user who types a subset of public fixture words (and invented names) often.
    /// Measures whether those words reach the two alternative chips from a three-letter prefix,
    /// with learning off (today's order) versus on. No real typing data; not an accuracy claim.
    func testEvaluationPersonalRerankRecallAndNoAutomaticChange() throws {
        let words = try bundled()
        let modes: [(String, [String])] = [
            ("DE", SpatialTypoEvaluationFixtures.german),
            ("EN", SpatialTypoEvaluationFixtures.english),
            ("mixed", SpatialTypoEvaluationFixtures.german + SpatialTypoEvaluationFixtures.english)
        ]
        let names = SpatialTypoEvaluationFixtures.novel.prefix(32).map { $0.lowercased() }
        for (name, fixture) in modes {
            let targets = fixture.enumerated().filter { $0.offset % 3 == 0 && $0.element.count >= 5 }.map(\.element)
                + (name == "mixed" ? names : [])
            var counts: [String: Int] = [:]
            for (ordinal, word) in targets.enumerated() { counts[word] = 2 + (ordinal * 7) % 19 }
            func make(learning on: Bool) -> AutocorrectEngine {
                let (learning, defaults) = session(learning: true)
                seed(learning, counts: counts)
                if !on { defaults.set(false, forKey: "keyboard.personalLearning"); learning.refresh() }
                let ac = AutocorrectEngine(checker: CorpusChecker(words[.english], trusted: Set(names)),
                                           learning: learning, spatialDecoder: SpatialWordDecoder(lexicons: words))
                ac.englishEnabled = name != "DE"
                if name != "EN" { ac.german = GermanAutocorrect(checker: CorpusChecker(words[.german])) }
                return ac
            }
            let off = make(learning: false), on = make(learning: true)
            var n = 0, off1 = 0, off2 = 0, on1 = 0, on2 = 0, autoDiff = 0, autoCompletion = 0, personalAuto = 0
            for target in targets {
                let prefix = String(target.prefix(3))
                let a = alternatives(off, prefix).map { $0.lowercased() }
                let chips = strip(on, prefix)
                let b = chips.filter { $0.kind != .keepLiteral }.map { $0.replacement.lowercased() }
                if a.first == target { off1 += 1 }
                if a.prefix(2).contains(target) { off2 += 1 }
                if b.first == target { on1 += 1 }
                if b.prefix(2).contains(target) { on2 += 1 }
                if chips.contains(where: { $0.isPersonal && $0.willAutoReplace }) { personalAuto += 1 }
                for typed in [prefix, target] {
                    let x = off.replacementOnSpace(beforeInput: typed, field: .text, autocorrectionType: .default)
                    let y = on.replacementOnSpace(beforeInput: typed, field: .text, autocorrectionType: .default)
                    if x?.replacement != y?.replacement { autoDiff += 1 }
                    if let y, y.replacement.lowercased().hasPrefix(typed.lowercased()),
                       y.replacement.count > typed.count { autoCompletion += 1 }
                }
                n += 1
            }
            XCTAssertEqual(autoDiff, 0, "Personal ranking never changes automatic replacement")
            XCTAssertEqual(autoCompletion, 0)
            XCTAssertEqual(personalAuto, 0)
            XCTAssertGreaterThan(on2, off2, "\(name): the user's frequent words must become easier to pick")
        }
    }
}
