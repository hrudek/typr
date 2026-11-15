import Foundation
import XCTest
@testable import Typr

/// Test prefixes include a held-out lead-in, not new target transitions: measures repeated
/// personal associations, not language generalization. Phrases and training paths live in
/// `PersonalTrigramPhraseFixtures`; exact counts and earlier-context selection are gated by
/// `PersonalTypingTrigramTests` in the default run.
@MainActor
final class PersonalTypingTrigramEvaluationTests: XCTestCase {
    private typealias Fixtures = PersonalTrigramPhraseFixtures
    private typealias Checker = PersonalTrigramPhraseFixtures.Checker
    /// Own loader: the research target does not compile `KeyboardContextModelTests`.
    private static let model: KeyboardContextModel? = {
        let packs = ["de", "en"].map { lang in
            Bundle.main.url(forResource: "keyboard-\(lang)", withExtension: "tbg", subdirectory: "WordData")
                .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.flatMap(KeyboardContextModel.Pack.init)
        }
        return KeyboardContextModel(de: packs[0], en: packs[1])
    }()
    private func ranked(_ prefix: String, session: KeyboardLearningSession, model: KeyboardContextModel,
                        language: String) -> [String] {
        let ac = AutocorrectEngine(checker: Checker(), learning: session, spatialDecoder: nil,
                                   contextResources: .init(model: model))
        ac.englishEnabled = language != "de"
        if language != "en" { ac.german = GermanAutocorrect(checker: Checker()) }
        let chips = ac.suggestions(beforeInput: prefix, field: .text, autocorrectionType: .default)
        let best = chips.first { if case .primary = $0.kind { return true }; return false }
        let rest = chips.filter { $0 != best }
        return ([best].compactMap { $0 } + rest).map { KeyboardContextModel.key($0.replacement) }
    }
#if TYPR_RESEARCH
    // Research-only sweep: recall is printed, not gated.
    func testRepeatedPersonalPhrasesAndAcceptedChoices() throws {
        let model = try XCTUnwrap(Self.model)
        for language in ["de", "en", "mixed"] {
            let phrases = try XCTUnwrap(Fixtures.phrases[language])
            for mode in Fixtures.trainingModes {
                let session = KeyboardLearningSession()
                var repetitions = 0
                var line = "EVAL R2_2_learning_\(language)_\(mode) targets=8"
                for n in [0, 1, 2, 4, 8] {
                    while repetitions < n {
                        for phrase in phrases { Fixtures.train(phrase, mode: mode, session: session) }
                        repetitions += 1
                    }
                    var hit1 = 0, hit3 = 0
                    for phrase in phrases {
                        for lead in ["", "okay "] {
                            let prefix = lead + phrase[0] + " " + phrase[1] + " "
                            let words = ranked(prefix, session: session, model: model, language: language)
                            if words.first == phrase[2] { hit1 += 1 }
                            if words.prefix(3).contains(phrase[2]) { hit3 += 1 }
                        }
                    }
                    line += " n\(n)_recall1=\(hit1) n\(n)_recall3=\(hit3)"
                }
                print(line + " fixtures=authored_repeat_and_heldout_leadin")
            }
        }
    }
#endif // TYPR_RESEARCH

    func testPublicHeldoutWithTwoWordPrefixes() throws {
        let model = try XCTUnwrap(Self.model)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "context-heldout-cc0", withExtension: "json", subdirectory: "WordData"))
        struct Fixture: Decodable { let sentences: [String: [[String]]] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let session = KeyboardLearningSession()
        for _ in 0..<8 {
            for language in ["de", "en", "mixed"] {
                for phrase in try XCTUnwrap(Fixtures.phrases[language]) { Fixtures.train(phrase, mode: "settled", session: session) }
            }
        }
        for language in ["de", "en", "mixed"] {
            // Mixed mode is public DE/EN sentences interleaved with both packs enabled,
            // not a claim of public intra-sentence code-switch data.
            let sentences = language == "mixed"
                ? try XCTUnwrap(fixture.sentences["de"]) + XCTUnwrap(fixture.sentences["en"])
                : try XCTUnwrap(fixture.sentences[language])
            var n = 0, hit1 = 0, hit3 = 0
            for words in sentences where words.count > 1 {
                for i in 1..<words.count {
                    let prefix = words.prefix(i).joined(separator: " ") + " "
                    let ranked = ranked(prefix, session: session, model: model, language: language)
                    let word = KeyboardContextModel.key(words[i])
                    if ranked.first == word { hit1 += 1 }
                    if ranked.prefix(3).contains(word) { hit3 += 1 }
                    n += 1
                }
            }
            print(String(format: "EVAL R2_2_public_%@ targets=%d recall1=%.4f recall3=%.4f training=authored_personal_not_public", language, n, Double(hit1) / Double(n), Double(hit3) / Double(n)))
        }
    }
}
