import XCTest
@testable import Typr

@MainActor
final class DictationLogImprovementTests: XCTestCase {
    func testImprovementExportSeparatesModelFormattingAndVocabularyErrors() async throws {
        let env = LogTestEnvironment()
        var context = DictationLogContext()
        context.cleanupPath = .typr
        let recording = env.begin(context: context)
        let raw = "Treffen wir uns um 14:00 Uhr nein besser um 16:00 Uhr."
        let answer = "Treffen wir uns um 14:00 Uhr um 16:00 Uhr."
        let formatted = "Treffen wir uns 14:00 Uhr 16:00 Uhr."
        recording.recognized(raw, spelled: raw, asrMilliseconds: 12, spellingPass: .init())
        recording.modelAnswer(answer, use: .accepted, modelMilliseconds: 30)
        recording.processingStages(cleanupOutput: answer, formattedText: formatted)
        recording.finish(text: formatted, beforeSpelling: formatted, spellingPass: .init())
        let id = try XCTUnwrap(env.store.entries.first?.id)
        env.store.saveFeedback(for: id, expectedText: "Treffen wir uns um 16:00 Uhr.", note: "Self-correction and lost preposition")
        await env.storage.flush()
        let loaded = DictationLogStore(storage: env.storage, settings: env.settings)
        try await LogTestEnvironment.waitUntilLoaded(loaded)
        let entry = try XCTUnwrap(loaded.entries.first)
        XCTAssertEqual(entry.cleanupOutput?.text, answer)
        XCTAssertEqual(entry.formattedText?.text, formatted)
        XCTAssertEqual(entry.expectedText?.text, "Treffen wir uns um 16:00 Uhr.")
        let compact = DictationLogExport.improvement.text(for: [entry])
        XCTAssertTrue(compact.contains(raw))
        XCTAssertTrue(compact.contains(answer))
        XCTAssertTrue(compact.contains("After style formatting:\n" + formatted))
        XCTAssertTrue(compact.contains("Cleanup output actually used: unchanged from [Model answer — accepted]"))
        XCTAssertTrue(compact.contains("Final text provided: unchanged from [After style formatting]"))
        XCTAssertTrue(compact.contains("Desired final text (human reference):\nTreffen wir uns um 16:00 Uhr."))
        XCTAssertTrue(compact.contains("Self-correction and lost preposition"))
        XCTAssertFalse(compact.contains("No replacements."))
        for technical in ["Loudest average", "Copy requested", "Bluetooth input", "Schema:", "First spelling pass changed"] {
            XCTAssertFalse(compact.contains(technical), technical)
            XCTAssertTrue(DictationLogExport.complete.text(for: [entry]).contains(technical), technical)
        }
        await env.dispose()
    }

    func testRejectedAnswerAndFallbackAreKeptDistinctAndLateAnswerCannotChangeStages() async throws {
        let env = LogTestEnvironment()
        let recording = env.begin()
        recording.recognized("raw", spelled: "raw", asrMilliseconds: 1)
        recording.modelAnswer("wrong", use: .rejected(.emptyOutput), modelMilliseconds: 2)
        recording.processingStages(cleanupOutput: "raw", formattedText: "Raw.")
        recording.finish(text: "Raw.", beforeSpelling: "Raw.")
        var entry = try XCTUnwrap(env.store.entries.first)
        XCTAssertTrue(entry.improvementText.contains("wrong"))
        XCTAssertTrue(entry.improvementText.contains("rejected(empty-output); not used"))
        XCTAssertTrue(entry.improvementText.contains("Cleanup output actually used: unchanged from [Recognized]"))
        recording.processingStages(cleanupOutput: "must not overwrite", formattedText: "wrong")
        recording.modelAnswer("late answer", use: .late, modelMilliseconds: 50)
        entry = try XCTUnwrap(env.store.entries.first)
        XCTAssertEqual(entry.cleanupOutput?.text, "raw")
        XCTAssertEqual(entry.formattedText?.text, "Raw.")
        XCTAssertEqual(entry.finalText?.text, "Raw.")
        XCTAssertTrue(entry.improvementText.contains("not used"))
        await env.dispose()
    }

    func testMissingOldEvidenceIsNotInferredAndTruncatedPrefixesAreNeverDeduplicated() throws {
        var entry = DictationLogEntry(context: .init())
        let long = String(repeating: "a", count: 4_100)
        entry.recognized = DictationLogText(long + " first")
        entry.finalText = DictationLogText(long + " second")
        let encoded = try JSONEncoder().encode(entry)
        let old = try JSONDecoder().decode(DictationLogEntry.self, from: encoded)
        XCTAssertNil(old.cleanupOutput)
        XCTAssertNil(old.expectedText)
        XCTAssertTrue(old.improvementText.contains("Cleanup output actually used: not recorded"))
        XCTAssertTrue(old.improvementText.contains("After style formatting: not recorded"))
        XCTAssertTrue(old.improvementText.contains("Final text provided [TRUNCATED;"))
        XCTAssertFalse(old.improvementText.contains("Final text provided: unchanged"))
        XCTAssertTrue(old.improvementText.contains("not a labelled training example"))
    }

    func testFeedbackCanBeClearedAndNeverResurrectsDeletedEntries() async throws {
        let env = LogTestEnvironment()
        let recording = env.begin()
        let id = try XCTUnwrap(env.store.entries.first?.id)
        env.store.saveFeedback(for: id, expectedText: "correct", note: "note")
        XCTAssertEqual(env.store.entries.first?.expectedText?.text, "correct")
        env.store.saveFeedback(for: id, expectedText: "", note: "")
        XCTAssertNil(env.store.entries.first?.expectedText)
        XCTAssertNil(env.store.entries.first?.feedbackNote)
        env.store.clear()
        env.store.saveFeedback(for: id, expectedText: "stale editor", note: "")
        recording.processingStages(cleanupOutput: "stale", formattedText: "stale")
        await env.storage.flush(); await mainActorBarrier() // Storage completions hop to the main actor.
        XCTAssertTrue(env.store.entries.isEmpty)
        await env.dispose()
    }

    func testNewFieldsAreRecappedAndIncludedInCompleteExport() {
        var entry = DictationLogEntry(context: .init())
        entry.context.vocabularyTerms = ["Herder", "pi"] + (0..<120).map { "term\($0)" + String(repeating: "x", count: 80) }
        entry.cleanupOutput = DictationLogText("cleanup result")
        entry.formattedText = DictationLogText("Formatted result.")
        entry.expectedText = DictationLogText(String(repeating: "x", count: 8_000))
        entry.feedbackNote = DictationLogText("feedback")
        entry.upstreamReason = "cleaner unavailable"
        entry.recap()
        XCTAssertTrue(entry.expectedText?.truncated == true)
        XCTAssertLessThanOrEqual(entry.expectedText?.text.utf8.count ?? 0, 4_000)
        XCTAssertEqual(entry.context.vocabularyTerms?.count, 100)
        XCTAssertEqual(entry.context.vocabularyTerms.map { Array($0.prefix(2)) }, ["Herder", "pi"])
        XCTAssertTrue(entry.context.vocabularyTerms?.allSatisfy { $0.count <= 64 } == true)
        for text in ["Herder", "pi", "cleanup result", "Formatted result.", "feedback", "cleaner unavailable"] {
            XCTAssertTrue(entry.plainText.contains(text), text)
        }
    }

    func testBatchExportsAllEntriesWithOneSharedCaveat() {
        let entries = [DictationLogEntry(context: .init()), DictationLogEntry(context: .init())]
        for format in DictationLogExport.allCases {
            let text = format.text(for: entries)
            for entry in entries { XCTAssertTrue(text.contains(entry.id.uuidString)) }
            XCTAssertEqual(text.components(separatedBy: "No audio is retained").count - 1, 1)
        }
    }
}
