import Foundation
import XCTest
@testable import Typr

@MainActor
final class KeyboardPersonalLexiconLearningTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { false }
        func guesses(for word: String) -> [String] {
            let guesses = ["ina": "in", "malin": "main", "andi": "and", "jens": "jeans",
                           "maren": "mare", "siemens": "siemen", "herdr": "herd", "typr": "typer"]
            return guesses[word.lowercased()].map { [$0] } ?? []
        }
        func completions(for prefix: String) -> [String] { [] }
    }

    private func lexicon(_ text: String) -> ProtectedPersonalLexicon {
        var builder = ProtectedPersonalLexicon.Builder()
        builder.add(text)
        return builder.build()
    }

    private func engine() -> AutocorrectEngine {
        AutocorrectEngine(checker: Checker(), spatialDecoder: nil, contextResources: .init(model: nil))
    }

    private func suffix(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String([letters[(index / 676) % 26], letters[(index / 26) % 26], letters[index % 26]])
    }

    func testBuildNormalizationDedupeAndDeterministicCaps() throws {
        let normalized = lexicon("  Ina INA Ma\u{308}lin Mälin O’Neil O'Neil ACME GmbH Jean-Luc 123 x " + String(repeating: "a", count: 65))
        XCTAssertEqual(normalized.words, ["acme", "gmbh", "ina", "jean", "luc", "mälin", "o'neil"])
        XCTAssertTrue(normalized.contains("MA\u{308}LIN"))
        var forward = ProtectedPersonalLexicon.Builder()
        var reverse = ProtectedPersonalLexicon.Builder()
        for i in 0..<2_100 { forward.add("term" + suffix(i)) }
        for i in (0..<2_100).reversed() { reverse.add("term" + suffix(i)) }
        XCTAssertEqual(forward.build(), reverse.build())
        XCTAssertEqual(forward.build().words.count, 2_000)
        XCTAssertEqual(forward.build().words.last, "term" + suffix(1_999))
    }

    func testSerializationRejectsCorruptNoncanonicalAndOversizedInput() throws {
        let value = lexicon("Ina Typr Mälin")
        XCTAssertEqual(ProtectedPersonalLexicon.decode(try value.encoded()), value)
        for text in ["garbage", "{}", "{\"version\":2,\"words\":[]}",
                     "{\"version\":1,\"words\":[\"ina\",\"ina\"]}",
                     "{\"version\":1,\"words\":[\"Typr\"]}",
                     "{\"version\":1,\"words\":[\"two words\"]}"] {
            XCTAssertNil(ProtectedPersonalLexicon.decode(Data(text.utf8)))
        }
        XCTAssertNil(ProtectedPersonalLexicon.decode(Data(repeating: 32, count: ProtectedPersonalLexicon.maximumFileBytes + 1)))
        let overCount: [String: Any] = ["version": 1, "words": (0..<2_001).map { "term" + suffix($0) }]
        XCTAssertNil(ProtectedPersonalLexicon.decode(try JSONSerialization.data(withJSONObject: overCount)))
    }

    func testFileReadMissingCorruptOversizedAndReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(ProtectedPersonalLexicon.load(directory: directory), .empty)
        let value = lexicon("Ina Typr")
        try value.write(directory: directory)
        XCTAssertEqual(ProtectedPersonalLexicon.load(directory: directory), value)
        let url = directory.appendingPathComponent(ProtectedPersonalLexicon.fileName)
        try Data("bad".utf8).write(to: url)
        XCTAssertEqual(ProtectedPersonalLexicon.load(directory: directory), .empty)
        try Data(repeating: 32, count: ProtectedPersonalLexicon.maximumFileBytes + 1).write(to: url)
        XCTAssertEqual(ProtectedPersonalLexicon.load(directory: directory), .empty)
        try FileManager.default.removeItem(at: url)
        let target = directory.appendingPathComponent("target.json")
        try value.encoded().write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertEqual(ProtectedPersonalLexicon.load(directory: directory), .empty)
        let suite = "typr.personal-lexicon.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProtectedPersonalLexicon.contactsKey)
        defaults.set(true, forKey: ProtectedPersonalLexicon.vocabularyKey)
        try ProtectedPersonalLexicon.reset(directory: directory, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: ProtectedPersonalLexicon.contactsKey))
        XCTAssertFalse(defaults.bool(forKey: ProtectedPersonalLexicon.vocabularyKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExistingAppResetLearningAlsoDeletesImportsAndDisablesSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "typr.personal-lexicon.reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try lexicon("Ina Typr").write(directory: directory)
        defaults.set(true, forKey: ProtectedPersonalLexicon.contactsKey)
        defaults.set(true, forKey: ProtectedPersonalLexicon.vocabularyKey)
        let model = KeyboardLearningSettingsModel(directory: directory, defaults: defaults)
        model.resetLearning()
        XCTAssertEqual(ProtectedPersonalLexicon.load(directory: directory), .empty)
        XCTAssertFalse(defaults.bool(forKey: ProtectedPersonalLexicon.contactsKey))
        XCTAssertFalse(defaults.bool(forKey: ProtectedPersonalLexicon.vocabularyKey))
        XCTAssertNotNil(defaults.string(forKey: ProtectedPersonalLexicon.resetKey))
    }

    func testImportedNamesVetoRulesShortcutsAndSpellingWhileOtherRulesRemain() {
        let ac = engine()
        ac.loadLexiconEntries([("ina", "in a")])
        ac.loadProtectedLexicon(lexicon("Ina fuer teh O’Neil"))
        XCTAssertEqual(AutocorrectEngine.currentToken(in: "O’Neil"), "O’Neil")
        for word in ["ina", "INA", "fuer", "teh", "O’Neil", "O'Neil"] {
            XCTAssertTrue(ac.literalIsValid(word))
            XCTAssertNil(ac.replacementOnSpace(beforeInput: word, field: .text, autocorrectionType: .default))
        }
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "dont", field: .text, autocorrectionType: .default)?.replacement, "don't")
        ac.loadProtectedLexicon(.empty)
        XCTAssertEqual(ac.replacementOnSpace(beforeInput: "ina", field: .text, autocorrectionType: .default)?.replacement, "in a")
    }

    func testCompletionsAndAttributionPrefixGuard() {
        let value = lexicon("Malin Maren Marie Marina Typr")
        XCTAssertEqual(value.completions(for: "ma"), ["malin", "maren", "marie"])
        XCTAssertEqual(value.completions(for: "mari", limit: 100), ["marie", "marina"])
        XCTAssertTrue(value.protectsPrefix("MAL"))
        XCTAssertFalse(value.protectsPrefix("mail"))
        let ac = engine()
        ac.loadProtectedLexicon(value)
        XCTAssertTrue(ac.protectsAttribution(prefix: "mali", letter: "n"))
        XCTAssertFalse(ac.protectsAttribution(prefix: "mali", letter: "x"), "unrelated branches remain available")
        XCTAssertTrue(ac.protectsAttribution(prefix: "malin", letter: "x"), "completed imported literal stays protected")
        XCTAssertTrue(ac.protectsAttribution(prefix: "", letter: "m"))
        XCTAssertFalse(ac.protectsAttribution(prefix: "hello", letter: "s"))
        let chips = ac.suggestions(beforeInput: "mal", field: .text, autocorrectionType: .default)
        XCTAssertTrue(chips.contains { $0.replacement == "malin" && $0.isCompletion && !$0.willAutoReplace })
    }

    func testCapSizedLoadWorkEvaluation() throws {
        var builder = ProtectedPersonalLexicon.Builder()
        for i in 0..<2_000 { builder.add(String(repeating: "a", count: 61) + suffix(i)) }
        let value = builder.build()
        let data = try value.encoded()
        XCTAssertEqual(value.words.count, 2_000)
        XCTAssertLessThanOrEqual(data.count, ProtectedPersonalLexicon.maximumFileBytes)
        XCTAssertEqual(ProtectedPersonalLexicon.decode(data), value)
        XCTAssertEqual(value.words.reduce(0) { $0 + $1.utf8.count }, 128_000)
    }
}
