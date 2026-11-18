import XCTest
@testable import Typr

@MainActor
final class DictationLogImprovementTests: XCTestCase {
    func testStagesAndHumanFeedbackSurviveStorage() async throws {
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
        XCTAssertEqual(entry.feedbackNote?.text, "Self-correction and lost preposition")
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
        XCTAssertEqual(entry.aiAnswer?.text, "wrong")
        XCTAssertEqual(entry.answerLabel, "rejected(empty-output); not used")
        XCTAssertEqual(entry.cleanupOutput?.text, "raw")
        recording.processingStages(cleanupOutput: "must not overwrite", formattedText: "wrong")
        recording.modelAnswer("late answer", use: .late, modelMilliseconds: 50)
        entry = try XCTUnwrap(env.store.entries.first)
        XCTAssertEqual(entry.cleanupOutput?.text, "raw")
        XCTAssertEqual(entry.formattedText?.text, "Raw.")
        XCTAssertEqual(entry.finalText?.text, "Raw.")
        XCTAssertTrue(entry.answerLabel.hasSuffix("not used"))
        await env.dispose()
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

    func testNewFieldsAreRecapped() {
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
    }
}
