import Foundation
import XCTest
@testable import Typr

@MainActor
final class PersonalTypingTrigramTests: XCTestCase {
    func testTrustedSettlementRequiresAllThreeAdjacentEndpoints() {
        let session = KeyboardLearningSession()
        session.settleTrustedWord("Meine", beforeInput: "Meine ")
        session.settleTrustedWord("neue", beforeInput: "Meine neue ")
        session.settleTrustedWord("Tastatur", beforeInput: "Meine neue Tastatur ")
        XCTAssertEqual(session.personalBigrams.followers(after: "meine neue"), ["tastatur": 1])
        XCTAssertEqual(session.personalBigrams.followers(after: "neue"), ["tastatur": 1])
        session.breakWordSequence()
        session.settleTrustedWord("neue", beforeInput: "Meine neue ")
        session.settleTrustedWord("Version", beforeInput: "Meine neue Version ")
        XCTAssertNil(session.personalBigrams.followers(after: "meine neue")["version"])
        session.breakWordSequence()
        session.settleTrustedWord("meine", beforeInput: "meine ")
        session.settleTrustedWord("neue", beforeInput: "meine neue ")
        session.settleTrustedWord("version", beforeInput: "andere neue version ")
        XCTAssertNil(session.personalBigrams.followers(after: "meine neue")["version"], "Edited earlier endpoint cannot teach")
    }

    func testBackoffSelectionAndContextBarriers() throws {
        var personal = PersonalBigramModel()
        personal.record("garden", after: "project")
        personal.record("keyboard", after: "project", earlier: "our")
        XCTAssertEqual(personal.select(after: "project", earlier: "our"), .init(context: "our project", lookups: 1))
        XCTAssertEqual(personal.select(after: "project", earlier: "your"), .init(context: "project", lookups: 2))
        XCTAssertEqual(personal.select(after: "missing", earlier: "our"), .init(context: nil, lookups: 2))
        XCTAssertEqual(personal.select(after: nil, earlier: nil).lookups, 0)
        let model = try XCTUnwrap(KeyboardContextModelTests.model)
        XCTAssertEqual(model.context(before: "our project ", currentToken: nil).earlier, "our")
        for prefix in ["our. project ", "our\nproject ", "our 123 project ", "our https://x project "] {
            XCTAssertNil(model.context(before: prefix, currentToken: nil).earlier, prefix)
        }
        XCTAssertEqual(model.context(before: "our project key", currentToken: "key").earlier, "our")
        print("EVAL R2_2_query_work retainedTrigramLookups=1 fallbackLookups=2 noPreviousLookups=0 rowFollowersMax=8 rerankCandidatesMax=32")
    }

    /// Moved from the research-only neural spike file: the exact discounted probability of
    /// a selected two-word row, purge of the earlier predecessor and reset to corpus.
    func testTrigramPrecedenceProbabilityPurgeBackoffAndReset() {
        var profile: PersonalBigramModel = .init()
        profile.record("morgen", after: "wir", earlier: "sehen")
        profile.record("morgen", after: "wir", earlier: "sehen")
        let selected = profile.select(after: "wir", earlier: "sehen")
        XCTAssertEqual(selected.context, "sehen wir")
        XCTAssertEqual(profile.probability("morgen", after: selected.context, corpus: 0.1), 0.55, accuracy: 1e-12)
        profile.purge("sehen")
        XCTAssertEqual(profile.select(after: "wir", earlier: "sehen").context, "wir")
        profile = .init()
        XCTAssertEqual(profile.probability("morgen", after: nil, corpus: 0.1), 0.1)
    }

    /// Default-run replacement for the research-only learning sweep. All four phrases share
    /// their middle word, so only the earlier word can select each target.
    func testSettledCompletionAndPredictionTeachTrigramCountsAndEarlierContext() throws {
        let model = try XCTUnwrap(KeyboardContextModelTests.model)
        let phrases = try XCTUnwrap(PersonalTrigramPhraseFixtures.phrases["de"])
        let middle = phrases[0][1]
        let repetitions = PersonalBigramModel.novelFollowerMinimum
        for mode in PersonalTrigramPhraseFixtures.trainingModes {
            let session = KeyboardLearningSession()
            for _ in 0..<repetitions {
                for phrase in phrases { PersonalTrigramPhraseFixtures.train(phrase, mode: mode, session: session) }
            }
            let personal = session.personalBigrams
            XCTAssertEqual(personal.pairCount, 3 * phrases.count, "\(mode): exactly the trusted pairs")
            XCTAssertEqual(personal.followers(after: middle),
                           Dictionary(uniqueKeysWithValues: phrases.map { ($0[2], repetitions) }), mode)
            for phrase in phrases {
                let pair = phrase[0] + " " + middle
                XCTAssertEqual(personal.followers(after: phrase[0]), [middle: repetitions], "\(mode) \(pair)")
                XCTAssertEqual(personal.followers(after: pair), [phrase[2]: repetitions], "\(mode) \(pair)")
                // Held-out lead-in: the earlier word comes from the field, not from training order.
                let context = model.context(before: "okay " + pair + " ", currentToken: nil)
                XCTAssertEqual(context.earlier, phrase[0], "\(mode) \(pair)")
                XCTAssertEqual(personal.select(after: context.previous, earlier: context.earlier).context, pair)
                let top = model.suggestions(after: context.previous, weightDE: 0.5, personal: personal,
                                            earlier: context.earlier).first?.key
                XCTAssertEqual(top, phrase[2], "\(mode) \(pair)")
            }
            XCTAssertEqual(personal.select(after: middle, earlier: "euer").context, middle, "\(mode): untrained earlier word backs off")
        }
    }

    func testTrigramNextWordAndRerankWithBigramFallback() throws {
        let model = try XCTUnwrap(KeyboardContextModelTests.model)
        var personal = PersonalBigramModel()
        for _ in 0..<12 { personal.record("garden", after: "project") }
        for _ in 0..<8 { personal.record("keyboard", after: "project", earlier: "our") }
        let known = model.context(before: "our project ", currentToken: nil)
        let unknown = model.context(before: "your project ", currentToken: nil)
        XCTAssertEqual(model.suggestions(after: known.previous, weightDE: 0.5, personal: personal, earlier: known.earlier).first?.key, "keyboard")
        XCTAssertEqual(model.suggestions(after: unknown.previous, weightDE: 0.5, personal: personal, earlier: unknown.earlier).first?.key, "garden")
        XCTAssertEqual(model.suggestions(after: "project", weightDE: 0.5, personal: personal),
                       model.suggestions(after: "project", weightDE: 0.5, personal: personal, earlier: "missing"))
        // OOV targets isolate the context gain from the corpus denominator and its cap.
        for _ in 0..<4 { personal.record("zqxword", after: "project", earlier: "our") }
        XCTAssertEqual(model.rerank(["unknown", "zqxword"], context: known, german: true, english: true, personal: personal).first, "zqxword")
        let short = model.context(before: "project ", currentToken: nil)
        XCTAssertEqual(model.contextGain("zqxword", context: unknown, german: true, english: true, personal: personal),
                       model.contextGain("zqxword", context: short, german: true, english: true, personal: personal))
    }

    func testTrigramContextsNeverAuthorizeAutomaticChanges() throws {
        final class Checker: TextChecking {
            func isWordValid(_ word: String) -> Bool { true }
            func guesses(for word: String) -> [String] { [] }
            func completions(for prefix: String) -> [String] { [] }
        }
        let model = try XCTUnwrap(KeyboardContextModelTests.model)
        let controls = ["Lena", "Donaudampfschiff", "WeChat", "camelCase", "meeting", "tasche",
                        "mittwoch", "updated", "reviewer", "standard", "tastaturen", "kollegen"]
        var queries = 0, unwanted = 0, differences = 0
        for language in ["de", "en", "mixed"] {
            let phrases = try XCTUnwrap(PersonalTrigramPhraseFixtures.phrases[language])
            let session = KeyboardLearningSession()
            for phrase in phrases {
                for _ in 0..<8 { session.model.recordPair(phrase[2], after: phrase[1], earlier: phrase[0]) }
            }
            let baseline = AutocorrectEngine(checker: Checker(), spatialDecoder: nil, contextResources: .init(model: model))
            let personal = AutocorrectEngine(checker: Checker(), learning: session, spatialDecoder: nil,
                                             contextResources: .init(model: model))
            for ac in [baseline, personal] {
                ac.englishEnabled = language != "de"
                if language != "en" { ac.german = GermanAutocorrect(checker: Checker()) }
            }
            for phrase in phrases {
                for literal in controls {
                    let before = phrase[0] + " " + phrase[1] + " " + literal
                    let base = baseline.replacementOnSpace(beforeInput: before, field: .text, autocorrectionType: .default)
                    let mine = personal.replacementOnSpace(beforeInput: before, field: .text, autocorrectionType: .default)
                    if base?.replacement != mine?.replacement { differences += 1 }
                    if mine != nil { unwanted += 1 }
                    queries += 1
                }
            }
        }
        XCTAssertEqual(unwanted, 0)
        XCTAssertEqual(differences, 0)
        print("EVAL R2_2_trigram_controls queries=\(queries) unwantedAuto=\(unwanted) changedAuto=\(differences) validity=injected_valid_DE_EN_mixed_names_compounds")
    }

    func testOldSchemaThreeFileLoadsCountsAndMigratesWithoutInventedTrigrams() throws {
        var state = PersonalTypingModel.State()
        state.schemaVersion = 3
        state.bigrams?.record("world", after: "hello")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardLearningStore(directory: directory, defaults: nil)
        var diagnostics = KeyboardDiagnostics()
        XCTAssertTrue(store.save(model: state, diagnostics: &diagnostics))
        // save validates/migrates; replace only the version to reproduce the legacy wire format.
        let file = directory.appendingPathComponent("learning-v1.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var value = try XCTUnwrap(object["value"] as? [String: Any])
        value["schemaVersion"] = 3
        object["value"] = value
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let loaded = try XCTUnwrap(store.load().0)
        XCTAssertEqual(loaded.schemaVersion, 5)
        XCTAssertEqual(loaded.bigrams?.following, ["hello": ["world": 1]])
        XCTAssertNil(loaded.bigrams?.following["hello world"])
        XCTAssertNil(PersonalTypingModel.State(schemaVersion: 6).validated(), "Future schemas fail closed")
    }

    func testAllReferenceDeletionIncludingBothPredecessorsAndReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "r2.trigrams.\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        for endpoint in ["first", "second", "third"] {
            var state = PersonalTypingModel.State()
            state.bigrams?.record("third", after: "second", earlier: "first")
            state.bigrams?.record("safe", after: "unrelated")
            var diagnostics = KeyboardDiagnostics()
            XCTAssertTrue(store.save(model: state, diagnostics: &diagnostics))
            let result = store.deleteLearnedEntry(.pairWord(endpoint))
            XCTAssertTrue(result)
            let model = try XCTUnwrap(store.load().0?.bigrams)
            XCTAssertFalse(model.words.contains(endpoint))
            XCTAssertNil(model.following["first second"])
            XCTAssertEqual(model.followers(after: "unrelated"), ["safe": 1])
        }
        XCTAssertTrue(store.requestLearningReset())
        XCTAssertTrue(store.load().0?.bigrams?.following.isEmpty ?? true)
    }

    func testCorruptContextSectionAndFileTolerance() throws {
        var state = PersonalTypingModel.State()
        let rows = ["three word context": ["follower": 2]]
        let data = try JSONSerialization.data(withJSONObject: ["following": rows, "updates": 0])
        state.bigrams = try JSONDecoder().decode(PersonalBigramModel.self, from: data)
        XCTAssertFalse(try XCTUnwrap(state.bigrams).isValid)
        XCTAssertTrue(try XCTUnwrap(state.validated()?.bigrams).following.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("learning-v1.json"))
        let store = KeyboardLearningStore(directory: directory, defaults: nil)
        XCTAssertNil(store.load().0)
    }

    func testPredictionChainsDeferEndpointsAndUndoDropsPendingTrigram() {
        final class Checker: TextChecking {
            func isWordValid(_ word: String) -> Bool { true }
            func guesses(for word: String) -> [String] { [] }
            func completions(for prefix: String) -> [String] { [] }
        }
        for undo in [false, true] {
            let target = FixtureTextTarget(text: "host ")
            target.autocapitalizationType = .some(.none)
            let ac = AutocorrectEngine(checker: Checker(), spatialDecoder: nil, contextResources: .init(model: nil))
            let engine = FullKeyboardEngine(target: target, autocorrect: ac)
            engine.width = 393; engine.clock = { 100 }; engine.configureForField()
            for word in ["our", "project", "keyboard"] {
                var chip = KeyboardSuggestion(displayText: word, replacement: word,
                                              kind: .primary(autoReplace: false), isCompletion: true)
                chip.ownership = engine.suggestionOwnership
                engine.acceptSuggestion(chip)
            }
            XCTAssertNil(ac.learning.personalBigrams.following["host"], "Host text never supplies a trusted endpoint")
            XCTAssertNil(ac.learning.personalBigrams.following["our project"], "Last pick waits for settlement")
            func tap(_ kind: KeyKind) {
                guard let key = engine.layout.key(kind) else { XCTFail("Missing key"); return }
                let p = CGPoint(x: key.frame.midX, y: key.frame.midY)
                engine.touchBegan(id: 1, at: p); engine.touchEnded(id: 1, at: p)
            }
            if undo { tap(.delete) }
            tap(.character("n"))
            XCTAssertEqual(ac.learning.personalBigrams.followers(after: "our project")["keyboard"], undo ? nil : 1)
        }
    }

    func testTrigramResetRaceAndLearningOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "r2.reset.\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        let session = KeyboardLearningSession(store: store, defaults: defaults)
        for _ in 0..<3 { session.model.recordPair("third", after: "second", earlier: "first") }
        session.recordWord("third")
        session.flush()
        XCTAssertNotNil(store.load().0?.bigrams?.following["first second"])
        defaults.set(false, forKey: "keyboard.personalLearning")
        session.refresh()
        XCTAssertTrue(session.personalBigrams.following.isEmpty)
        session.model.recordPair("other", after: "second", earlier: "first")
        XCTAssertNil(session.model.state.bigrams?.following["first second"]?["other"])
        defaults.set(true, forKey: "keyboard.personalLearning")
        session.refresh()
        XCTAssertEqual(session.personalBigrams.followers(after: "first second")["third"], 3)
        session.recordWord("dirty")
        XCTAssertTrue(store.requestLearningReset())
        session.flush()
        XCTAssertTrue(session.personalBigrams.following.isEmpty)
        XCTAssertTrue(store.load().0?.bigrams?.following.isEmpty ?? true, "Stale save never resurrects trigrams")
    }

    func testCombinedEntryByteCapsAgeingAndDeterministicEviction() throws {
        func word(_ value: Int) -> String {
            var n = value, result = "w"
            repeat { result.append(Character(UnicodeScalar(97 + n % 26)!)); n /= 26 } while n > 0
            return result
        }
        var rows: [String: [String: Int]] = [:]
        for i in 0..<64 {
            var followers: [String: Int] = [:]
            for j in 0..<8 { followers[word(j)] = 8 }
            rows[word(i) + " project"] = followers
        }
        let data = try JSONSerialization.data(withJSONObject: ["following": rows, "updates": 0])
        var a = try JSONDecoder().decode(PersonalBigramModel.self, from: data)
        var b = a
        XCTAssertEqual(a.pairCount, 512)
        XCTAssertTrue(a.isValid)
        let atCapBytes = try JSONEncoder().encode(a).count
        let atCapBound = a.encodedByteBound
        for i in 0..<1024 {
            a.record(word(i), after: "project", earlier: word(i + 100))
            b.record(word(i), after: "project", earlier: word(i + 100))
            XCTAssertEqual(a, b)
            XCTAssertTrue(a.isValid)
        }
        XCTAssertNil(a.following["wa project"], "Stale two-word rows age out under unrelated use")
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(a).count, a.encodedByteBound)
        var unicode = PersonalBigramModel()
        for i in 0..<255 {
            unicode.record(String(repeating: "界", count: 26) + word(i),
                           after: String(repeating: "語", count: 26) + word(i), earlier: String(repeating: "文", count: 28))
            XCTAssertTrue(unicode.isValid)
        }
        print("EVAL R2_2_bounds entriesAtCap=512 encodedBytesAtCap=\(atCapBytes) boundAtCap=\(atCapBound) byteCap=65536 unicodeEntries=\(unicode.pairCount) unicodeBound=\(unicode.encodedByteBound) agedOriginalRows=0 deterministicReplay=1")
    }
}
