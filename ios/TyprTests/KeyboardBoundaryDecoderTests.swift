import Foundation
import XCTest
@testable import Typr

/// Public/constructed text and synthetic touches only. No Apple dictionary or device claims.
@MainActor
final class KeyboardBoundaryDecoderTests: XCTestCase {
    typealias Boundary = KeyboardBoundaryDecoder
    typealias Language = SpatialWordDecoder.Language

    final class Checker: TextChecking {
        let lexicon: SpatialWordLexicon?
        var trusted: Set<String>
        /// Corpus entries a real dictionary does not list (FrequencyWords merge noise such
        /// as "inthe"). A stated evaluation premise, not Apple dictionary evidence.
        var rejected: Set<String>
        var calls = 0
        init(_ lexicon: SpatialWordLexicon? = nil, trusted: Set<String> = [], rejected: Set<String> = []) {
            self.lexicon = lexicon
            self.trusted = trusted
            self.rejected = rejected
        }
        func isWordValid(_ word: String) -> Bool {
            calls += 1
            let lower = word.lowercased()
            return trusted.contains(lower) || (!rejected.contains(lower) && lexicon?.logPrior(for: lower) != nil)
        }
        func guesses(for word: String) -> [String] { calls += 1; return [] }
        func completions(for prefix: String) -> [String] { calls += 1; return [] }
    }

    let grid = KeyboardLayout(width: 393)

    func resources() throws -> [Language: SpatialWordLexicon] { try XCTUnwrap(BundledKeyboardData.lexicons) }

    func contextModel() throws -> KeyboardContextModel { try XCTUnwrap(BundledKeyboardData.contextModel) }

    func engine(_ sources: [Language: SpatialWordLexicon], languages: Set<Language> = [.german, .english],
                trusted: Set<String> = [], rejected: Set<String> = [],
                model: KeyboardContextModel? = nil) -> AutocorrectEngine {
        let ac = AutocorrectEngine(checker: Checker(sources[.english], trusted: trusted, rejected: rejected),
                                  spatialDecoder: SpatialWordDecoder(lexicons: sources),
                                  contextResources: KeyboardContextResources(model: model))
        ac.englishEnabled = languages.contains(.english)
        if languages.contains(.german) {
            ac.german = GermanAutocorrect(checker: Checker(sources[.german], trusted: trusted, rejected: rejected))
        }
        return ac
    }

    func job(_ token: String, previous: String? = nil, languages: Set<Language> = [.german, .english],
             personal: PersonalLexiconSnapshot = .empty, kept: Set<String> = []) -> Boundary.Job {
        .init(token: token, previous: previous, languages: languages, personal: personal, kept: kept)
    }

    func strip(_ ac: AutocorrectEngine, _ text: String) -> [KeyboardSuggestion] {
        ac.suggestions(beforeInput: text, field: .text, autocorrectionType: .default)
    }

    func testExactSplitsShortWordsAndWholeProtection() throws {
        let sources = try resources()
        for phrase in ["great day", "this is", "ich habe", "das ist", "in the", "kannst du", "I am", "a day", "es ist", "am ende", "für die"] {
            let token = phrase.replacingOccurrences(of: " ", with: "")
            let result = Boundary.retrieve(job(token), lexicons: sources)
            XCTAssertTrue(result.candidates.contains { $0.replacement == phrase.lowercased() }, "\(phrase): \(result)")
            XCTAssertTrue(result.candidates.allSatisfy { $0.score > $0.baseline })
        }
        for token in ["Haustür", "Kindergarten", "Bahnhof", "Fahrrad", "something", "inside", "another", "the", "in"] {
            XCTAssertFalse(Boundary.retrieve(job(token), lexicons: sources).candidates.contains { $0.kind == .split }, token)
        }
        for token in ["greatDay", "GREATDAY", "foo_bar", "ichhabe2", "https://greatday", "😀", String(repeating: "a", count: 33)] {
            XCTAssertTrue(Boundary.retrieve(job(token), lexicons: sources).candidates.isEmpty, token)
        }
        XCTAssertTrue(Boundary.retrieve(job("ichhabe", kept: ["ichhabe"]), lexicons: sources).candidates.isEmpty)
        let personal = PersonalLexiconSnapshot(kept: [], counts: ["ichhabe": 2], rejected: [])
        XCTAssertTrue(Boundary.retrieve(job("ichhabe", personal: personal), lexicons: sources).candidates.isEmpty)
        XCTAssertTrue(Boundary.retrieve(job("ichhabe"), lexicons: [.german: sources[.german]!]).candidates.isEmpty)
        XCTAssertTrue(Boundary.retrieve(job("ichhabe", languages: []), lexicons: sources).candidates.isEmpty)
    }

    func testPerPartPersonalWordsAndLanguageSelection() throws {
        let sources = try resources()
        let personal = PersonalLexiconSnapshot(kept: ["velqora"], counts: ["velqora": 100], rejected: [])
        XCTAssertTrue(Boundary.retrieve(job("invelqora", personal: personal), lexicons: sources).candidates.contains {
            $0.replacement == "in velqora"
        })
        XCTAssertTrue(Boundary.retrieve(job("invelqora"), lexicons: sources).candidates.isEmpty)
        XCTAssertTrue(Boundary.retrieve(job("ichhabe", languages: [.english]), lexicons: sources).candidates.isEmpty)
        XCTAssertTrue(Boundary.retrieve(job("thisis", languages: [.german]), lexicons: sources).candidates.isEmpty)
    }

    func testSplitPointTiesAreDeterministicAndLimitsAreInclusive() throws {
        // Tiny independent TSW1 fixture: equal lexical products at two split points.
        final class Node {
            var children: [Character: Node] = [:]
            var count: UInt32 = 0
        }
        let entries: [(String, UInt32)] = [("foo", 1_000_000), ("bars", 1_000_000),
            ("foob", 1_000_000), ("ars", 1_000_000), ("zzzzz", 1_000_000_000)]
        let root = Node()
        for (word, count) in entries {
            var node = root
            for letter in word {
                if node.children[letter] == nil { node.children[letter] = Node() }
                node = node.children[letter]!
            }
            node.count = count
        }
        func uint(_ value: UInt32, _ data: inout Data) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        var nodes: [(Character?, Node)] = [(nil, root)], records = Data(), index = 0
        while index < nodes.count {
            let (letter, node) = nodes[index]
            let children = node.children.sorted { $0.key < $1.key }
            records.append(contentsOf: [letter.map { UInt8(SpatialWordLexicon.alphabet.firstIndex(of: $0)!) } ?? 255,
                                       UInt8(children.count), 0, 0])
            uint(children.isEmpty ? 0 : UInt32(nodes.count), &records)
            uint(node.count, &records)
            nodes.append(contentsOf: children.map { (Optional($0.key), $0.value) })
            index += 1
        }
        var data = Data("TSW1".utf8)
        for value in [UInt32(nodes.count), UInt32(entries.count), 0, 1_004_000_000, 0] { uint(value, &data) }
        data.append(records)
        let source = try XCTUnwrap(SpatialWordLexicon(data: data))
        let result = Boundary.retrieve(job("foobars", languages: [.english]), lexicons: [.english: source])
        XCTAssertEqual(result.candidates.map(\.replacement), ["foo bars", "foob ars"])
        XCTAssertEqual(result.candidates[0].score, result.candidates[1].score)
        for _ in 0..<20 {
            XCTAssertEqual(Boundary.retrieve(result.job, lexicons: [.english: source]).candidates, result.candidates)
        }
        XCTAssertTrue(Boundary.isEligible(String(repeating: "a", count: 32)))
        XCTAssertFalse(Boundary.isEligible(String(repeating: "a", count: 33)))
        XCTAssertTrue(Boundary.isEligible("fu\u{308}rdie"), "NFD is normalized without folding ü to u")
        // A raw two-token NFD suffix can exceed 65 bytes despite a 32-letter NFC join.
        let rawPart = String(repeating: "u\u{308}", count: 16)
        let normalizedJoin = String(repeating: "ü", count: 32)
        let personal = PersonalLexiconSnapshot(kept: [normalizedJoin], counts: [:], rejected: [])
        let joined = Boundary.retrieve(job(rawPart, previous: rawPart, personal: personal), lexicons: try resources())
        let candidate = try XCTUnwrap(joined.candidates.first { $0.kind == .join })
        XCTAssertEqual(Array(candidate.original.utf8), Array((rawPart + " " + rawPart).utf8))
        XCTAssertGreaterThan(candidate.original.utf8.count, 65)
        XCTAssertLessThanOrEqual(candidate.original.utf8.count + candidate.replacement.utf8.count, 194)
    }

    func testWholeSpatialReadingCompetesAndIncompleteReadingHasNoAutomaticAuthority() throws {
        let sources = try resources()
        let candidate = SpatialWordDecoder.Candidate(word: "great", language: .english, score: 100,
                                                    spatialScore: 100, edit: .none, alignment: [])
        let reading = SpatialWordDecoder.Result(candidates: [candidate], literalScore: -20,
            literalSpatialScore: 0, literalInLexicon: false, complete: false, visits: 1, generated: 1)
        XCTAssertTrue(Boundary.retrieve(job("greatday"), lexicons: sources, whole: .result(reading)).candidates.isEmpty)
    }

    func testExactJoinsButNeverTwoPlausibleWordsOrNonAdjacentText() throws {
        let sources = try resources()
        let ac = engine(sources)
        for text in ["Tasta tur", "keyb oard"] {
            let suggestions = strip(ac, text)
            XCTAssertTrue(suggestions.contains { $0.boundary?.kind == .join }, "\(text): \(suggestions)")
            XCTAssertTrue(suggestions.filter { $0.boundary != nil }.allSatisfy { !$0.willAutoReplace })
        }
        for text in ["some thing", "in side", "a bout", "Tasta  tur", "Tasta\ntur", "@Tasta tur", "foo_bar tur"] {
            XCTAssertFalse(strip(ac, text).contains { $0.boundary?.kind == .join }, text)
        }
    }

    func testCheckerContactKeepAndIdentifierProtectionsAndNoAutomaticSplits() throws {
        let sources = try resources()
        let ac = engine(sources, trusted: ["greatday", "ichhabe"])
        XCTAssertFalse(strip(ac, "greatday").contains { $0.boundary != nil })
        XCTAssertFalse(strip(ac, "ichhabe").contains { $0.boundary != nil })
        let ordinary = engine(sources)
        ordinary.loadLexiconEntries([("greatday", "greatday")])
        XCTAssertFalse(strip(ordinary, "greatday").contains { $0.boundary != nil })
        ordinary.suppressAndKeep("ichhabe")
        XCTAssertFalse(strip(ordinary, "ichhabe").contains { $0.boundary != nil })
        for token in ["thisis", "dasist", "inthe", "kannstdu"] {
            XCTAssertTrue(strip(ordinary, token).filter { $0.boundary != nil }.allSatisfy { !$0.willAutoReplace })
            XCTAssertNil(ordinary.replacementOnSpace(beforeInput: token, field: .text, autocorrectionType: .default))
        }
        ordinary.isEnabled = false
        XCTAssertFalse(strip(ordinary, "thisis").contains { $0.boundary != nil })
    }

    func testWorkerPickUndoRejectionReversalAndStaleSuffix() async throws {
        let sources = try resources(), model = try contextModel()
        for text in ["greatday", "Tasta tur", "inthe"] {
            // "inthe" exercises corpus merge-noise ranking; its dictionary must reject it.
            let ac = text == "inthe" ? engine(sources, rejected: ["inthe"], model: model) : engine(sources)
            let target = FixtureTextTarget(text: text)
            let keyboard = FullKeyboardEngine(target: target, autocorrect: ac)
            keyboard.configureForField()
            let current = try XCTUnwrap(AutocorrectEngine.currentToken(in: text))
            var before = String(text.dropLast(current.count))
            for letter in current {
                let key = try XCTUnwrap(keyboard.layout.key(.character(String(letter).lowercased())))
                let after = before + String(letter)
                ac.touchInput.append(text: String(letter), point: CGPoint(x: key.frame.midX, y: key.frame.midY),
                                     key: key, layout: keyboard.layout, before: before, after: after)
                before = after
            }
            XCTAssertNotNil(ac.touchInput.evidence(beforeInput: text))
            keyboard.refreshSuggestions()
            await keyboard.waitForSuggestions()
            let chip = try XCTUnwrap(keyboard.suggestions.first { $0.boundary != nil }, text)
            let oldCounts = ac.learning.model.state.counts
            let oldLayouts = ac.learning.model.state.layouts
            let oldLabels = ac.learning.diagnostics.acceptedLabels
            keyboard.acceptSuggestion(chip)
            XCTAssertEqual(target.text, chip.replacement + " ")
            XCTAssertEqual(ac.learning.model.state.counts, oldCounts)
            XCTAssertEqual(ac.learning.model.state.layouts, oldLayouts)
            let labelDelta = ac.learning.diagnostics.acceptedLabels - oldLabels
            XCTAssertEqual(labelDelta, 0)
            print("EVAL P5_learning kind=\(chip.boundary!.kind) count_delta=\(ac.learning.model.state.counts.count - oldCounts.count) layouts_unchanged=\(ac.learning.model.state.layouts == oldLayouts) label_delta=\(labelDelta) evidence_complete=true")
            keyboard.deleteBackward()
            XCTAssertEqual(target.text, text, "One Backspace restores the entire original suffix")
            XCTAssertTrue(ac.learning.protections.rejected.isEmpty, "No phrases in persistent schema")
            await keyboard.waitForSuggestions()
            let redo = try XCTUnwrap(keyboard.suggestions.first { $0.boundary != nil })
            keyboard.acceptSuggestion(redo)
            keyboard.deleteBackward()
            ac.discardFeedback() // New edit/feedback ends the immediate rejection-reversal offer.
            XCTAssertFalse(strip(ac, text).contains { $0.boundary?.replacement == chip.boundary?.replacement })
            target.insertText("x")
            keyboard.acceptSuggestion(chip)
            XCTAssertEqual(target.text, text + "x", "Stale suffix may not rewrite earlier text")
        }
    }

    func testBoundaryRejectionBoundDoesNotChangePersistentSchema() throws {
        let ac = engine(try resources())
        for index in 0..<100 {
            let suffix = String(UnicodeScalar(97 + index / 26)!) + String(UnicodeScalar(97 + index % 26)!)
            let candidate = Boundary.Candidate(kind: .split, original: "in" + suffix, replacement: "in " + suffix,
                                               score: 0, baseline: -1)
            ac.recordUndo(.init(original: candidate.original, insertedText: candidate.replacement + " ", boundary: candidate))
        }
        XCTAssertTrue(ac.learning.model.state.rejected.isEmpty)
        XCTAssertEqual(ac.boundaryRejectionCount, 64)
        print("EVAL P5_rejections attempts=100 session_pairs=\(ac.boundaryRejectionCount) persistent_phrase_pairs=\(ac.learning.model.state.rejected.count) session_pair_cap=\(AutocorrectEngine.boundaryRejectionLimit)")
    }
}
