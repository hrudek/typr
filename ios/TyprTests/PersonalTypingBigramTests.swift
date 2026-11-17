import Foundation
import XCTest
@testable import Typr

/// P4 regression tests: trusted personal next-word pairs (Typr-authored synthetic words only).
@MainActor
final class PersonalTypingBigramTests: XCTestCase {
    private final class Checker: TextChecking {
        var valid: Set<String> = ["hello", "world", "the", "next", "ich", "code", "swift", "morgen", "coffee", "please",
                                   "meine", "tastatur", "heute", "mittag", "guten", "daily", "review", "project", "update", "morning"]
        func isWordValid(_ word: String) -> Bool { valid.contains(word) }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }
    private func keyboard(_ session: KeyboardLearningSession? = nil, text: String = "",
                          model: KeyboardContextModel? = nil) -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget(text: text)
        target.autocapitalizationType = .some(.none)
        let ac = AutocorrectEngine(checker: Checker(), learning: session, spatialDecoder: nil,
                                   contextResources: .init(model: model))
        let engine = FullKeyboardEngine(target: target, autocorrect: ac)
        engine.width = 393
        engine.clock = { 100 }
        engine.configureForField()
        return (engine, target)
    }
    private func tap(_ kind: KeyKind, _ engine: FullKeyboardEngine) {
        guard let key = engine.layout.key(kind) else { XCTFail("Missing fixture key \(kind)"); return }
        let p = CGPoint(x: key.frame.midX, y: key.frame.midY)
        engine.touchBegan(id: 1, at: p); engine.touchEnded(id: 1, at: p)
    }
    private func type(_ text: String, _ engine: FullKeyboardEngine) {
        for ch in text { tap(ch == " " ? .space : .character(String(ch)), engine) }
    }
    /// Distinct synthetic letter-only words: w + base-26 digits.
    private func word(_ n: Int) -> String {
        var value = n, s = "w"
        repeat { s.append(Character(UnicodeScalar(97 + value % 26)!)); value /= 26 } while value > 0
        return s
    }

    func testOnlyAdjacentIndependentlySettledWordsTeachPairs() {
        let (engine, _) = keyboard()
        type("hello world ", engine)
        XCTAssertEqual(engine.autocorrect.learning.personalBigrams.pairCount, 0, "The follower is not settled yet")
        type("n", engine)
        XCTAssertEqual(engine.autocorrect.learning.personalBigrams.followers(after: "hello"), ["world": 1])
        // No pair is inferred from pre-existing field text, even if both words are valid.
        let (other, _) = keyboard(text: "hello ")
        type("world n", other)
        XCTAssertEqual(other.autocorrect.learning.personalBigrams.pairCount, 0)
        // Mixed DE/EN pairs share one normalized key space, no language partition.
        let (mixed, _) = keyboard()
        type("meine coffee n", mixed)
        XCTAssertEqual(mixed.autocorrect.learning.personalBigrams.followers(after: "MEINE"), ["coffee": 1])
        XCTAssertEqual(mixed.autocorrect.learning.previousTrustedWord, "coffee", "RAM-only predecessor")
    }

    func testAutomaticUndoneRetypedAndDiscontinuousWordsNeverTeachPairs() {
        let modes = ["auto", "undo", "retype", "field", "selection", "language", "doubleSpace", "return",
                     "punctuation", "learningToggle"]
        for mode in modes {
            let defaults = UserDefaults(suiteName: "p4.modes.\(UUID().uuidString)")!
            let (engine, target) = keyboard(KeyboardLearningSession(defaults: defaults))
            type("hello ", engine)
            if mode == "auto" || mode == "undo" {
                type("teh ", engine)
                if mode == "undo" { tap(.delete, engine); type(" ", engine) }
                type("world n", engine)
            } else if mode == "retype" {
                type("worla", engine); tap(.delete, engine); type("d next n", engine)
            } else {
                type("world", engine)
                switch mode {
                case "field": engine.configureForField()
                case "selection": engine.textDidChange()
                case "language": engine.autocorrect.englishEnabled = false; engine.autocorrect.englishEnabled = true
                case "doubleSpace": type("  ", engine)
                case "return": tap(.returnKey, engine)
                case "punctuation":
                    tap(.layerSwitch(.numbers), engine); tap(.character("."), engine); tap(.layerSwitch(.letters), engine)
                case "learningToggle":
                    defaults.set(false, forKey: "keyboard.personalLearning"); engine.autocorrect.syncLearning()
                    defaults.set(true, forKey: "keyboard.personalLearning"); engine.autocorrect.syncLearning()
                default: break
                }
                type(" next n", engine)
            }
            let pairs = engine.autocorrect.learning.personalBigrams
            XCTAssertNil(pairs.followers(after: "hello")["world"], mode)
            XCTAssertNil(pairs.followers(after: "hello")["the"], mode)
            XCTAssertNil(pairs.followers(after: "the")["world"], mode)
            // Language/learning toggles break only the earlier boundary; `world next` is then a
            // fresh, trusted adjacent pair. Field/selection changes also drop world's own evidence.
            let freshPair = mode == "language" || mode == "learningToggle"
            XCTAssertEqual(pairs.followers(after: "world")["next"], freshPair ? 1 : nil, mode)
            XCTAssertFalse(target.text.isEmpty)
        }
    }

    func testDiscontinuityAfterSettledPredecessorClearsRAMContext() {
        // `hello` settles at the next letter. After the discontinuity, a silent fixture edit
        // removes that letter so a freshly typed, independently trusted `world` follows
        // `hello ` again: only clearing the RAM predecessor prevents the pair. `none` is
        // the positive control proving the scenario would otherwise learn it.
        for mode in ["none", "selection", "field", "lifecycle", "layout", "cancel"] {
            let (engine, target) = keyboard()
            type("hello w", engine)
            XCTAssertEqual(engine.autocorrect.learning.previousTrustedWord, "hello", mode)
            switch mode {
            case "selection": engine.textDidChange()
            case "field": engine.configureForField()
            case "lifecycle": engine.discardTouchEvidence()
            case "layout": engine.width = 430
            case "cancel": engine.cancelAllTouches()
            default: break
            }
            XCTAssertEqual(engine.autocorrect.learning.previousTrustedWord, mode == "none" ? "hello" : nil, mode)
            target.deleteBackward()
            XCTAssertEqual(target.text, "hello ")
            type("world n", engine)
            XCTAssertEqual(engine.autocorrect.learning.personalBigrams.followers(after: "hello")["world"],
                           mode == "none" ? 1 : nil, mode)
        }
    }

    func testManualChoiceWaitsForSettlementAndUndoBreaksSequence() async throws {
        for undo in [false, true] {
            let (engine, _) = keyboard()
            type("hello world", engine)
            await engine.waitForSuggestions()
            var chip = KeyboardSuggestion(displayText: "world", replacement: "world", kind: .keepLiteral)
            chip.ownership = engine.suggestions.first?.ownership
            engine.acceptSuggestion(chip)
            XCTAssertEqual(engine.autocorrect.learning.personalBigrams.pairCount, 0)
            if undo { tap(.delete, engine) }
            type(undo ? " n" : "n", engine)
            XCTAssertEqual(engine.autocorrect.learning.personalBigrams.followers(after: "hello")["world"], undo ? nil : 1)
        }
    }

    func testBoundaryPickSuppliesNoPairEndpointAndBreaksPredecessor() {
        for undo in [false, true] {
            let (engine, target) = keyboard(text: "")
            type("hello helloworld", engine)
            XCTAssertEqual(engine.autocorrect.learning.previousTrustedWord, "hello")
            var chip = KeyboardSuggestion(displayText: "hello world", replacement: "hello world",
                                          kind: .primary(autoReplace: false))
            chip.boundary = .init(kind: .split, original: "helloworld", replacement: "hello world", score: 0, baseline: 0)
            chip.ownership = engine.suggestionOwnership
            engine.acceptSuggestion(chip)
            XCTAssertEqual(target.text, "hello hello world ")
            XCTAssertNil(engine.autocorrect.learning.previousTrustedWord)
            if undo { tap(.delete, engine) }
            type("next n", engine)
            let pairs = engine.autocorrect.learning.personalBigrams
            XCTAssertTrue(pairs.followers(after: "hello").isEmpty, "\(undo)")
            XCTAssertNil(pairs.followers(after: "world")["next"], "\(undo)")
        }
    }

    func testKeepRevertDoesNotPurgeButExplicitDeletionDoes() {
        let session = KeyboardLearningSession()
        for _ in 0..<3 { session.model.recordPair("world", after: "hello") }
        session.keep("world")
        // The immediate keep revert (backspace after a keep chip) is not a deletion request.
        session.forgetKeep("world")
        XCTAssertEqual(session.personalBigrams.followers(after: "hello"), ["world": 3])
        session.model.forgetCount("world")
        XCTAssertEqual(session.personalBigrams.pairCount, 0)
    }

    func testDeterministicCapsAgeingBytesAndNormalization() throws {
        var a = PersonalBigramModel(), b = PersonalBigramModel()
        for i in 0..<255 { a.record("WORLD", after: "Hello"); b.record("world", after: "hello"); XCTAssertEqual(a, b, "event \(i)") }
        XCTAssertEqual(a.followers(after: "hello")["world"], 255, "Saturated")
        // The 256th event halves first (255 → 127), then counts itself.
        a.record("world", after: "hello")
        XCTAssertEqual(a.updates, 0)
        XCTAssertEqual(a.followers(after: "hello")["world"], 128)
        a.record("Straße", after: "FU\u{308}R")
        XCTAssertEqual(a.followers(after: "für")["straße"], 1)
        XCTAssertTrue(a.followers(after: "fur").isEmpty, "Umlauts stay distinct")
        // Invalid words (digits, apostrophes, spaces, empty) are ignored without counting an event.
        let before = a
        for bad in ["c3po", "don't", "two words", "", String(repeating: "a", count: 33)] { a.record(bad, after: "hello") }
        XCTAssertEqual(a, before)

        // Same event sequence → identical state; the just-recorded follower is never its own victim.
        var x = PersonalBigramModel(), y = PersonalBigramModel()
        for i in 0..<20 { x.record(word(i), after: "context"); y.record(word(i), after: "context") }
        XCTAssertEqual(x, y)
        XCTAssertEqual(x.followers(after: "context").count, PersonalBigramModel.followerLimit)
        XCTAssertNotNil(x.followers(after: "context")[word(19)], "A recent follower replaces a stale one")
        // A stronger follower survives newcomers.
        let strong = (x.followers(after: "context")[word(0)] ?? 0) + 3
        for _ in 0..<3 { x.record(word(0), after: "context") }
        for i in 100..<120 { x.record(word(i), after: "context") }
        XCTAssertEqual(x.followers(after: "context")[word(0)], strong)
        XCTAssertNotNil(x.followers(after: "context")[word(119)])

        // Halving drops ones and keeps ordering among survivors.
        var ageing = PersonalBigramModel()
        for _ in 0..<6 { ageing.record("often", after: "very") }
        ageing.record("once", after: "very")
        for i in 0..<(PersonalBigramModel.ageingInterval - 7) { ageing.record(word(i % 40), after: word(200 + i % 40)) }
        XCTAssertEqual(ageing.followers(after: "very"), ["often": 3])

        // Full, valid encoded fixture seeded directly (no need to defeat ageing).
        let rows = Dictionary(uniqueKeysWithValues: (0..<64).map { h in
            (word(h), Dictionary(uniqueKeysWithValues: (0..<8).map { (word(100 + $0), 10) }))
        })
        let fullData = try JSONSerialization.data(withJSONObject: ["following": rows, "updates": 0])
        var full = try JSONDecoder().decode(PersonalBigramModel.self, from: fullData)
        XCTAssertTrue(full.isValid)
        XCTAssertEqual(full.pairCount, 512)
        for i in 0..<40 {
            full.record(word(500 + i), after: word(1000 + i))
            XCTAssertTrue(full.isValid)
            XCTAssertEqual(full.followers(after: word(1000 + i))[word(500 + i)], 1, "New pair spared under the global cap")
        }
        XCTAssertEqual(full.pairCount, 512)
        let bytes = try JSONEncoder().encode(full).count
        XCTAssertLessThanOrEqual(bytes, full.encodedByteBound)
        XCTAssertLessThanOrEqual(full.encodedByteBound, PersonalBigramModel.maximumBytes)
        // Long Unicode words exercise the independent byte ceiling, not just edge capacity.
        var unicode = PersonalBigramModel()
        for i in 0..<200 {
            unicode.record(String(repeating: "界", count: 27) + word(i), after: String(repeating: "語", count: 27) + word(i))
            XCTAssertLessThanOrEqual(unicode.encodedByteBound, PersonalBigramModel.maximumBytes)
        }
        XCTAssertTrue(unicode.isValid)
        XCTAssertLessThan(unicode.pairCount, 200)
        let unicodeBytes = try JSONEncoder().encode(unicode).count
        XCTAssertLessThanOrEqual(unicodeBytes, unicode.encodedByteBound)
        print("EVAL P4_bounds pairs=\(full.pairCount) followersMax=\(PersonalBigramModel.followerLimit) encodedBytes=\(bytes) encodedBound=\(full.encodedByteBound) byteCap=\(PersonalBigramModel.maximumBytes) unicodePairs=\(unicode.pairCount) unicodeEncodedBytes=\(unicodeBytes) unicodeBound=\(unicode.encodedByteBound) countCap=\(PersonalBigramModel.countLimit) ageingInterval=\(PersonalBigramModel.ageingInterval)")
    }

    func testWholeStoreStaysWithinFileLimitAtMaximumWordAndPairState() throws {
        // Under the whole-file ceiling, frequency associations yield before words and protections.
        var small = PersonalTypingModel.State()
        let date = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<3 { small.counts[word(i)] = .init(count: 2, lastUpdated: date) }
        for i in 0..<5 { small.bigrams?.record(word(10 + i), after: "hello") }
        XCTAssertTrue(small.dropOldestLexiconEntries(2))
        XCTAssertEqual(small.bigrams?.pairCount, 3)
        XCTAssertEqual(small.counts.count, 3)
        XCTAssertTrue(small.dropOldestLexiconEntries(10))
        XCTAssertEqual(small.bigrams?.pairCount, 0)
        XCTAssertEqual(small.counts.count, 3)
        XCTAssertTrue(small.dropOldestLexiconEntries(1))
        XCTAssertEqual(small.counts.count, 2)

        // 2,000 long three-byte-letter words plus a byte-saturated pair section never exceed 256 KiB.
        var state = PersonalTypingModel.State()
        for i in 0..<2000 { state.counts[String(repeating: "ア", count: 28) + word(i)] = .init(count: 3, lastUpdated: date) }
        var pairs = PersonalBigramModel()
        for i in 0..<600 { pairs.record(String(repeating: "界", count: 27) + word(i), after: String(repeating: "語", count: 27) + word(i % 90)) }
        state.bigrams = pairs
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardLearningStore(directory: directory, defaults: nil)
        var diagnostics = KeyboardDiagnostics()
        XCTAssertTrue(store.save(model: try XCTUnwrap(state.validated()), diagnostics: &diagnostics))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("learning-v1.json").path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, KeyboardLearningStore.maximumLearningBytes)
        let loaded = try XCTUnwrap(store.load().0)
        XCTAssertTrue(loaded.bigrams?.isValid == true)
        if loaded.counts.count < state.counts.count { XCTAssertEqual(loaded.bigrams?.pairCount, 0, "Pairs yield first") }
        print("EVAL P4_store_bytes fileBytes=\(size) fileCap=\(KeyboardLearningStore.maximumLearningBytes) pairsBefore=\(pairs.pairCount) pairsAfter=\(loaded.bigrams?.pairCount ?? 0) words=\(loaded.counts.count)")
    }

    func testDiscountedBackoffAndPersonalTopThreeAgainstExhaustiveUnion() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        var personal = PersonalBigramModel()
        for _ in 0..<12 { personal.record("swift", after: "ich") }
        for _ in 0..<3 { personal.record("coffee", after: "ich") }
        personal.record("zzqx", after: "ich") // Personal-only, seen once: not eligible yet.
        let corpus = 0.2
        XCTAssertEqual(personal.probability("swift", after: "ich", corpus: corpus), (11.5 + 4.5 * corpus) / 19, accuracy: 1e-12)
        XCTAssertEqual(personal.probability("other", after: "unknown", corpus: corpus), corpus)
        XCTAssertEqual(personal.backoffWeight(after: "ich"), 4.5 / 19, accuracy: 1e-12)
        // A proper distribution: followers' discounted mass plus the backed-off corpus mass is 1.
        let mass = (11.5 + 2.5 + 0.5) / 19 + personal.backoffWeight(after: "ich")
        XCTAssertEqual(mass, 1, accuracy: 1e-12)
        let selections = [(0.05, true, true), (0.5, true, true), (0.95, true, true), (0.5, true, false), (0.5, false, true)]
        for (weight, german, english) in selections {
            let actual = model.suggestions(after: "ich", weightDE: weight, german: german, english: english, personal: personal)
            var keys = Set<String>()
            for pack in [german ? model.de : nil, english ? model.en : nil].compactMap({ $0 }) {
                for id in 1..<pack.wordCount { keys.insert(pack.word(id)) }
            }
            let corpusKeys = keys.subtracting(KeyboardContextModel.suppressed)
            let eligible = corpusKeys.union(personal.followers(after: "ich").filter {
                $0.value >= PersonalBigramModel.novelFollowerMinimum }.keys)
            let scored: [(key: String, probability: Double)] = eligible.map { key in
                let corpusProbability = model.probability(key, after: "ich", weightDE: weight,
                                                          german: german, english: english)
                return (key, personal.probability(key, after: "ich", corpus: corpusProbability))
            }
            let ranked = scored.sorted { left, right in
                if left.probability == right.probability {
                    return left.key.utf8.lexicographicallyPrecedes(right.key.utf8)
                }
                return left.probability > right.probability
            }
            let expected = ranked.prefix(3).map(\.key)
            XCTAssertEqual(actual.map(\.key), expected, "\(weight) \(german) \(english)")
            XCTAssertEqual(actual.first?.key, "swift")
            XCTAssertFalse(actual.contains { $0.key == "zzqx" })
        }
        let context = model.context(before: "ich ", currentToken: nil)
        XCTAssertEqual(model.rerank(["unknown", "swift"], context: context, german: true, english: true, personal: personal).first, "swift")
        // One sighting of a personal-only word gives no rerank gain; two do.
        XCTAssertEqual(model.contextGain("zzqx", context: context, german: true, english: true, personal: personal), 0)
        personal.record("zzqx", after: "ich")
        XCTAssertGreaterThan(model.contextGain("zzqx", context: context, german: true, english: true, personal: personal), 0)
        XCTAssertTrue(model.suggestions(after: "ich", weightDE: 0.5, personal: personal).count == 3)
        // Learning off passes an empty model: exactly the corpus-only output.
        XCTAssertEqual(model.suggestions(after: "ich", weightDE: 0.5), model.suggestions(after: "ich", weightDE: 0.5, personal: .init()))
        XCTAssertEqual(model.rerank(["unknown", "swift"], context: context, german: true, english: true),
                       model.rerank(["unknown", "swift"], context: context, german: true, english: true, personal: .init()))
    }

    func testMigrationRepairDeletionResetRaceAndLearningOffIsolation() throws {
        let defaults = UserDefaults(suiteName: "p4.\(UUID().uuidString)")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        let session = KeyboardLearningSession(store: store, defaults: defaults)
        for (a, b) in [("hello", "world"), ("world", "next"), ("next", "hello"), ("ich", "code")] {
            session.model.recordPair(b, after: a)
        }
        session.recordWord("world"); session.flush()
        XCTAssertTrue(store.deleteLearnedEntry(.count("world")))
        session.flush() // A dirty/old writer must reload the authoritative edited epoch.
        XCTAssertFalse(session.personalBigrams.words.contains("world"))
        XCTAssertEqual(session.personalBigrams.pairCount, 2)
        XCTAssertTrue(store.deleteLearnedEntry(.pairWord("hello")))
        session.refresh()
        XCTAssertFalse(session.personalBigrams.words.contains("hello"))
        XCTAssertEqual(store.learnedWords()?.bigrams?.followers(after: "ich"), ["code": 1])
        session.keep("code"); session.flush()
        XCTAssertTrue(store.deleteLearnedEntry(.kept("code")))
        session.refresh()
        XCTAssertEqual(session.personalBigrams.pairCount, 0, "Deleting a kept word purges its pairs too")
        session.model.recordPair("code", after: "ich")
        // Learning off: no updates, no influence, retained data untouched.
        defaults.set(false, forKey: "keyboard.personalLearning"); session.refresh()
        let retained = session.model.state.bigrams
        session.model.recordPair("world", after: "hello")
        session.settleTrustedWord("hello", beforeInput: "hello ")
        XCTAssertEqual(session.model.state.bigrams, retained)
        XCTAssertEqual(session.personalBigrams, .init())
        XCTAssertNil(session.previousTrustedWord)
        defaults.set(true, forKey: "keyboard.personalLearning"); session.refresh()
        XCTAssertEqual(session.personalBigrams.pairCount, 1)
        // Reset: a pending predecessor cannot pair across it, and saved pairs are gone.
        session.settleTrustedWord("hello", beforeInput: "hello ")
        XCTAssertTrue(store.requestLearningReset()); session.flush()
        XCTAssertNil(session.previousTrustedWord)
        session.settleTrustedWord("world", beforeInput: "hello world ")
        XCTAssertEqual(session.personalBigrams.pairCount, 0)
        XCTAssertEqual(store.load().0?.bigrams?.pairCount ?? 0, 0)

        var state = PersonalTypingModel.State()
        state.kept["hello"] = Date(timeIntervalSinceReferenceDate: 0)
        state.rejected = [.init(typed: "teh", replacement: "the")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        for version in [1, 2] {
            object["schemaVersion"] = version; object.removeValue(forKey: "bigrams")
            let decoded = try JSONDecoder().decode(PersonalTypingModel.State.self, from: JSONSerialization.data(withJSONObject: object))
            let migrated = try XCTUnwrap(decoded.validated())
            XCTAssertEqual(migrated.schemaVersion, 5)
            XCTAssertEqual(migrated.bigrams, .init(), "No invented observations")
            XCTAssertEqual(migrated.kept, state.kept)
        }
        // Out-of-bounds pair data drops only the pairs; keeps and rejections survive.
        object["schemaVersion"] = 3
        object["bigrams"] = ["following": ["hello": ["world": 999]], "updates": 0]
        let corrupt = try JSONDecoder().decode(PersonalTypingModel.State.self, from: JSONSerialization.data(withJSONObject: object))
        let repaired = try XCTUnwrap(corrupt.validated())
        XCTAssertEqual(repaired.bigrams, .init())
        XCTAssertEqual(repaired.kept, state.kept)
        XCTAssertEqual(repaired.rejected, state.rejected)
        // Unknown future schema fails closed; a schema-3 snapshot must carry its pair section.
        state.schemaVersion = 6
        XCTAssertNil(state.validated())
        state.schemaVersion = 3; state.bigrams = nil
        XCTAssertNil(state.validated())
    }

    func testPermissionRevocationBreaksPendingSequenceAndUsesRAMOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let session = KeyboardLearningSession(store: .init(directory: directory, defaults: nil), allowsPersistence: { allowed })
        session.settleTrustedWord("hello", beforeInput: "hello ")
        allowed = false; session.refresh()
        XCTAssertFalse(session.isPersistent)
        XCTAssertNil(session.previousTrustedWord)
        session.settleTrustedWord("world", beforeInput: "hello world ")
        XCTAssertEqual(session.personalBigrams.pairCount, 0)
        // RAM-only learning continues for this keyboard session and is never written.
        session.settleTrustedWord("next", beforeInput: "hello world next ")
        XCTAssertEqual(session.personalBigrams.followers(after: "world"), ["next": 1])
        session.flush()
        XCTAssertNil(KeyboardLearningStore(directory: directory, defaults: nil).load().0?.bigrams?.followers(after: "world")["next"])
    }

    func testPredictionPicksFollowSentenceCapitalizationAndKeepNounCasing() async throws {
        typealias Mode = AutoCapitalization.Mode
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .sentences, before: "done. ", hasText: true), "World")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .sentences, before: "done! ", hasText: true), "World")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .sentences, before: "done? ", hasText: true), "World")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .sentences, before: "line\n", hasText: true), "World")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .sentences, before: "", hasText: false), "World")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .sentences, before: "hello ", hasText: true), "world")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .words, before: "hello ", hasText: true), "World")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: .allCharacters, before: "hello ", hasText: true), "WORLD")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("world", mode: Mode.none, before: "done. ", hasText: true), "world")
        XCTAssertEqual(FullKeyboardEngine.casedPrediction("Tastatur", mode: .sentences, before: "meine ", hasText: true), "Tastatur",
                       "German nouns are never lowercased")
        for (text, capitalizes) in [("done. ", true), ("done! ", true), ("done? ", true), ("hello ", false), ("", true)] {
            let (engine, target) = keyboard(text: text)
            target.autocapitalizationType = .sentences
            var chip = KeyboardSuggestion(displayText: "world", replacement: "world", kind: .primary(autoReplace: false), isCompletion: true)
            // A directly owned prediction fixture also covers a field-start pick without inventing history.
            chip.ownership = engine.suggestionOwnership
            engine.acceptSuggestion(chip)
            XCTAssertEqual(target.text, text + (capitalizes ? "World " : "world "))
            XCTAssertEqual(engine.autocorrect.learning.personalBigrams.pairCount, 0, "Prediction picks teach no pair")
        }
        // Published chips already show the capitalization they insert (real corpus, personal follower).
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let session = KeyboardLearningSession()
        for _ in 0..<4 { session.model.recordPair("tastatur", after: "meine") }
        for (text, sentences) in [("Das ist meine ", true), ("das ist meine ", false)] {
            let expected = "Tastatur"
            let (engine, target) = keyboard(session, text: text, model: model)
            target.autocapitalizationType = sentences ? .sentences : .some(.none)
            engine.autocorrect.german = GermanAutocorrect(checker: { let c = Checker(); c.valid.insert("Tastatur"); return c }())
            engine.textDidChange()
            await engine.waitForSuggestions()
            XCTAssertTrue(engine.suggestions.contains { $0.displayText == expected && $0.replacement == expected }, "\(engine.suggestions)")
            XCTAssertTrue(engine.suggestions.allSatisfy { !$0.willAutoReplace })
        }
        let (engine, target) = keyboard(session, text: "Fertig. ", model: model)
        target.autocapitalizationType = .sentences
        engine.textDidChange()
        await engine.waitForSuggestions()
        XCTAssertFalse(engine.suggestions.isEmpty)
        XCTAssertTrue(engine.suggestions.allSatisfy { $0.displayText.first?.isUppercase == true && $0.displayText == $0.replacement },
                      "\(engine.suggestions)")
    }
}
