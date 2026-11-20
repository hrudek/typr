import Foundation
import XCTest
@testable import Typr

extension KeyboardBoundaryDecoderTests {
    func testContextSplitMultipliesLexicalPriorsByBothConditionalLifts() throws {
        let sources = try resources(), model = try contextModel()
        var input = job("inthe", languages: [.english])
        input.context = .init(previous: "we", weightDE: 0)
        let result = Boundary.retrieve(input, lexicons: sources, model: model)
        let candidate = try XCTUnwrap(result.candidates.first { $0.replacement == "in the" })
        func p(_ word: String, _ context: String?) -> Double {
            model.probability(word, after: context, weightDE: 0, german: false, english: true)
        }
        // "in" takes the larger of the curated short-word prior and its TSW1 prior; "the" uses
        // its TSW1 prior. Context multiplies the lexical product by P(in|we)/P(in) and P(the|in)/P(the).
        let english = try XCTUnwrap(sources[.english])
        let lexical = max(Boundary.shortPrior, english.logPrior(for: "in") ?? -.infinity)
            + (try XCTUnwrap(english.logPrior(for: "the")))
        let lifts = log(p("in", "we") / p("in", nil)) + log(p("the", "in") / p("the", nil))
        XCTAssertEqual(candidate.score, lexical + lifts + Boundary.missingSpacePenalty, accuracy: 1e-9)
        XCTAssertTrue(candidate.strongPair)
        XCTAssertTrue(candidate.weakWhole, "FrequencyWords inthe is not independent whole-word evidence")
        XCTAssertGreaterThan(result.contextQueries, 0)
        XCTAssertLessThanOrEqual(result.contextQueries, Boundary.maximumContextQueries)
        // Merge-noise weakening recovers splits the lexical-only policy lost to the corpus whole.
        for (token, phrase) in [("ofthe", "of the"), ("forthe", "for the"), ("inder", "in der")] {
            var noisy = job(token)
            XCTAssertFalse(Boundary.retrieve(noisy, lexicons: sources).candidates.contains { $0.replacement == phrase })
            noisy.context = .init(previous: nil, weightDE: 0.5)
            XCTAssertTrue(Boundary.retrieve(noisy, lexicons: sources, model: model).candidates.contains {
                $0.replacement == phrase && $0.weakWhole
            }, token)
        }
        // A pair the sparse rows did not retain only pays its backoff weight: lexical-only
        // retrievals stay reachable instead of being rescored on another corpus's scale.
        for phrase in ["I am", "as if", "great day", "ich habe", "mit you", "ich have"] {
            var plain = job(phrase.replacingOccurrences(of: " ", with: ""))
            plain.context = .init(previous: nil, weightDE: 0.5)
            XCTAssertTrue(Boundary.retrieve(plain, lexicons: sources, model: model).candidates.contains {
                $0.replacement == phrase.lowercased()
            }, phrase)
        }
        for word in ["inside", "another", "something", "keyboard", "Kindergarten", "Bahnhof"] {
            var valid = job(word)
            valid.context = .init(previous: "the", weightDE: 0.5)
            XCTAssertFalse(Boundary.retrieve(valid, lexicons: sources, model: model).candidates.contains {
                $0.kind == .split
            }, word)
        }
    }

    func testMissingContextPackBacksOffWithoutSilentlySelectingOneLanguage() throws {
        let sources = try resources(), model = try contextModel()
        let englishOnly = try XCTUnwrap(KeyboardContextModel(de: nil, en: model.en))
        var input = job("ichhabe")
        let original = Boundary.retrieve(input, lexicons: sources)
        input.context = .init(previous: "und", weightDE: 0.8)
        let unavailable = Boundary.retrieve(input, lexicons: sources, model: englishOnly)
        XCTAssertEqual(unavailable.candidates, original.candidates)
        XCTAssertEqual(unavailable.contextQueries, 0)
        XCTAssertEqual(Boundary.retrieve(input, lexicons: sources).candidates, original.candidates)
        XCTAssertEqual(Boundary.Context(previous: String(repeating: "a", count: 129), weightDE: .nan),
                       Boundary.Context(previous: nil, weightDE: 0.5))
        XCTAssertEqual(Boundary.Context(previous: "Fu\u{308}r", weightDE: 2).previous, "für")
        XCTAssertEqual(Boundary.Context(previous: nil, weightDE: 2).weightDE, 1)
    }

    func testContextSplitCacheOwnsPreviousContextAndLanguageSelection() throws {
        let sources = try resources(), model = try contextModel()
        let ac = engine(sources, rejected: ["inthe"], model: model)
        func request(_ text: String) -> KeyboardSuggestionWorker.Request {
            let owner = KeyboardSuggestionOwnership(engine: UUID(), revision: 1, context: text,
                token: AutocorrectEngine.currentToken(in: text), field: .text, permitsCorrection: true,
                configuration: ac.suggestionConfiguration, learning: ac.learning.generation,
                feedbackEpoch: ac.learning.feedbackEpoch, resources: ac.spatialDecoder?.resourceRevision ?? -1,
                layout: grid)
            return ac.suggestionRequest(ownership: owner, evidence: nil)
        }
        _ = strip(ac, "we inthe")
        XCTAssertNotNil(request("we inthe").boundaryReady)
        let changed = request("und inthe")
        XCTAssertNil(changed.boundaryReady)
        XCTAssertEqual(changed.boundary?.context?.previous, "und")
        ac.englishEnabled = false
        XCTAssertEqual(request("thisis").boundary?.languages, [.german])
        XCTAssertFalse(strip(ac, "thisis").contains { $0.boundary != nil }, "No English pair in German-only mode")
        ac.isEnabled = false
        XCTAssertNil(request("we inthe").boundary)
        XCTAssertFalse(strip(ac, "inthe").contains { $0.boundary != nil })
    }

    func testDictionaryValidityStaysAuthoritativeOverCorpusMergeNoise() throws {
        let sources = try resources(), model = try contextModel()
        // Corpus entries whose split has a strong retained pair (found by scanning both
        // TSW1 packs) but which real dictionaries list. The checker, not the ranking
        // corpus, decides validity: no chip even though the worker ranked a split.
        let valid = ["comeback", "herein", "hereto", "beider", "Anden", "todo", "noone"]
        let ac = engine(sources, trusted: Set(valid.map { $0.lowercased() }), model: model)
        for word in valid {
            XCTAssertFalse(strip(ac, word).contains { $0.boundary != nil }, word)
            XCTAssertFalse(strip(ac, "the " + word).contains { $0.boundary != nil }, word)
        }
        // The pessimistic corpus-as-dictionary proxy also vetoes "inthe"; once the
        // dictionary rejects it the ranked split appears, manual-only.
        XCTAssertFalse(strip(engine(sources, languages: [.english], model: model), "inthe").contains {
            $0.boundary != nil
        })
    }

    func testImportedNamesBlockSplitsAndJoins() throws {
        let sources = try resources()
        let model = try contextModel()
        let controls = ["ina", "malin", "andi", "asa", "bea", "isa", "ora", "todo", "athome",
                        "withyou", "redis", "esbuild", "sunhat", "siemens", "herdr", "typr"]
        let ac = engine(sources, rejected: Set(controls), model: model)
        var builder = ProtectedPersonalLexicon.Builder()
        for word in controls { builder.add(word) }
        ac.loadProtectedLexicon(builder.build())
        for word in controls {
            XCTAssertFalse(strip(ac, word).contains { $0.boundary != nil }, word)
            for phrase in ["the " + word, word + " in"] {
                XCTAssertFalse(strip(ac, phrase).contains { $0.boundary != nil }, phrase)
                XCTAssertNil(ac.replacementOnSpace(beforeInput: phrase, field: .text, autocorrectionType: .default), phrase)
            }
        }
    }

    func testStrongCorpusSplitNeverOverridesKeepContactCountOrAutomaticPolicy() throws {
        let sources = try resources(), model = try contextModel()
        let ac = engine(sources, languages: [.english], rejected: ["inthe"], model: model)
        let chips = strip(ac, "inthe")
        let split = try XCTUnwrap(chips.first { $0.boundary?.replacement == "in the" })
        XCTAssertTrue(split.boundary?.weakWhole == true)
        XCTAssertFalse(split.willAutoReplace)
        XCTAssertFalse(split.isCompletion)
        XCTAssertNil(ac.replacementOnSpace(beforeInput: "inthe", field: .text, autocorrectionType: .default))
        let suite = "typr.tests.boundary-context.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "keyboard.personalLearning")
        let session = KeyboardLearningSession(defaults: defaults)
        let off = AutocorrectEngine(checker: Checker(sources[.english], rejected: ["inthe"]), learning: session,
                                    spatialDecoder: SpatialWordDecoder(lexicons: sources),
                                    contextResources: KeyboardContextResources(model: model))
        XCTAssertFalse(off.learning.isLearningEnabled)
        XCTAssertTrue(strip(off, "inthe").contains { $0.boundary?.replacement == "in the" })
        XCTAssertTrue(off.learning.model.state.counts.isEmpty)
        ac.loadLexiconEntries([("inthe", "inthe")])
        XCTAssertFalse(strip(ac, "inthe").contains { $0.boundary != nil })
        for personal in [PersonalLexiconSnapshot(kept: ["inthe"], counts: [:], rejected: []),
                         PersonalLexiconSnapshot(kept: [], counts: ["inthe": 1], rejected: [])] {
            var input = job("inthe", languages: [.english], personal: personal, kept: personal.kept)
            input.context = .init(previous: nil, weightDE: 0)
            XCTAssertFalse(Boundary.retrieve(input, lexicons: sources, model: model).candidates.contains {
                $0.kind == .split
            })
        }
        XCTAssertTrue(ac.suggestions(beforeInput: "inthe", field: .text, autocorrectionType: .no).isEmpty)
        XCTAssertTrue(ac.suggestions(beforeInput: "inthe", field: .email, autocorrectionType: .default).isEmpty)
    }
}
