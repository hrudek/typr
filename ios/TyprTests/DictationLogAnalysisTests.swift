import XCTest
@testable import Typr

@MainActor
final class DictationLogAnalysisTests: XCTestCase {
    func testMatcherReportsActualSpansIncludingRepeatedPhrasesAndPossessives() {
        var pass = DictationLogSpellingPass()
        let output = VocabularySpelling.apply(["iPhone", "WeChat"], to: "iphone, we chat's iphone iPhone") {
            pass.record(before: $0, after: $1, term: $2)
        }
        XCTAssertEqual(output, "iPhone, WeChat's iPhone iPhone")
        XCTAssertEqual(pass.totalChanges, 3)
        XCTAssertEqual(pass.changes.map { $0.before.text }, ["iphone", "we chat's", "iphone"])
        XCTAssertEqual(pass.changes.map { $0.after.text }, ["iPhone", "WeChat's", "iPhone"])
        XCTAssertEqual(pass.changes.map { $0.term.text }, ["iPhone", "WeChat", "iPhone"])
        XCTAssertEqual(output, VocabularySpelling.apply(["iPhone", "WeChat"], to: "iphone, we chat's iphone iPhone"))
    }

    func testNoOpAndDisabledVocabularyDoNotReportReplacements() {
        for terms in [[], ["iPhone"]] {
            var calls = 0
            let output = VocabularySpelling.apply(terms, to: "iPhone works") { _, _, _ in calls += 1 }
            XCTAssertEqual(output, "iPhone works")
            XCTAssertEqual(calls, 0)
        }
    }

    func testPassBoundsRetainedEvidenceButCountsEveryReplacement() throws {
        var pass = DictationLogSpellingPass()
        let source = Array(repeating: "iphone", count: 50).joined(separator: " ")
        _ = VocabularySpelling.apply(["iPhone"], to: source) { pass.record(before: $0, after: $1, term: $2) }
        XCTAssertEqual(pass.totalChanges, 50)
        XCTAssertEqual(pass.changes.count, DictationLogSpellingPass.maximumReplacements)
        var entry = DictationLogEntry(context: DictationLogContext())
        entry.firstSpellingPass = pass
        XCTAssertTrue(entry.spellingLines(pass).last?.contains("30 more replacements") == true)
        let reloaded = try JSONDecoder().decode(DictationLogEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(reloaded.firstSpellingPass, pass)
    }

    func testOldSchemaOneEntriesKeepUnknownSettingsAndEvidence() throws {
        var entry = DictationLogEntry(context: DictationLogContext())
        entry.context.vocabularyCount = 3
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        var context = try XCTUnwrap(object["context"] as? [String: Any])
        for key in ["vocabularyEnabled", "upstreamCleanupEnabled", "typrCleanupEnabled"] { context.removeValue(forKey: key) }
        object["context"] = context
        object.removeValue(forKey: "firstSpellingPass")
        object.removeValue(forKey: "secondSpellingPass")
        let old = try JSONDecoder().decode(DictationLogEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.schemaVersion, 1)
        XCTAssertNil(old.context.vocabularyEnabled)
        XCTAssertNil(old.firstSpellingPass)
        XCTAssertTrue(old.vocabularyLabel.contains("Not recorded"))
        XCTAssertTrue(old.spellingLines(old.firstSpellingPass).first?.contains("older entry or pass not reached") == true)
    }

    func testSettingsStagesFeedbackAndTwoPassEvidenceSurviveStorage() async throws {
        let env = LogTestEnvironment()
        var context = DictationLogContext()
        context.cleanupPath = .typr
        context.typrCleanupEnabled = true
        context.upstreamCleanupEnabled = true
        context.vocabularyEnabled = true
        context.vocabularyCount = 1
        let recording = env.begin(context: context)
        var first = DictationLogSpellingPass(), second = DictationLogSpellingPass()
        first.record(before: "iphone", after: "iPhone", term: "iPhone")
        second.record(before: "IPhone", after: "iPhone", term: "iPhone")
        recording.recognized("iphone", spelled: "iPhone", asrMilliseconds: 1, spellingPass: first)
        recording.modelAnswer("iPhone", use: .accepted, modelMilliseconds: 30)
        recording.processingStages(cleanupOutput: "iPhone", formattedText: "IPhone.")
        recording.finish(text: "iPhone.", beforeSpelling: "IPhone.", spellingPass: second)
        env.store.saveFeedback(for: recording.entryID, expectedText: "iPhone!", note: "Lost the exclamation")
        await env.storage.flush()
        let loaded = DictationLogStore(storage: env.storage, settings: env.settings)
        try await LogTestEnvironment.waitUntilLoaded(loaded)
        let entry = try XCTUnwrap(loaded.entries.first)
        XCTAssertEqual(entry.firstSpellingPass, first)
        XCTAssertEqual(entry.secondSpellingPass, second)
        XCTAssertEqual(entry.cleanupOutput?.text, "iPhone")
        XCTAssertEqual(entry.formattedText?.text, "IPhone.")
        XCTAssertEqual(entry.expectedText?.text, "iPhone!")
        XCTAssertEqual(entry.feedbackNote?.text, "Lost the exclamation")
        XCTAssertEqual(entry.context.upstreamCleanupEnabled, true)
        XCTAssertTrue(entry.vocabularyLabel.hasPrefix("Vocabulary: On"))
        XCTAssertTrue(entry.improvementLines.contains(entry.vocabularyLabel))
        XCTAssertEqual(entry.spellingLines(entry.firstSpellingPass).first?.hasPrefix("\"iphone\" → \"iPhone\""), true)
        XCTAssertEqual(entry.spellingLines(entry.secondSpellingPass).first?.hasPrefix("\"IPhone\" → \"iPhone\""), true)
        await env.dispose()
    }

    func testEverySelectedPathAndVocabularyStateHasAnExplicitLabel() {
        for path in [DictationLogCleanupPath.typr, .upstream, .none] {
            var context = DictationLogContext()
            context.cleanupPath = path
            context.vocabularyEnabled = false
            var entry = DictationLogEntry(context: context)
            XCTAssertTrue(entry.improvementLines.contains { $0.hasSuffix("selected cleanup: \(path.rawValue)") })
            XCTAssertEqual(entry.vocabularyLabel, "Vocabulary: Off")
            entry.context.vocabularyEnabled = true
            XCTAssertEqual(entry.vocabularyLabel, "Vocabulary: On (0 terms)")
        }
    }
}
