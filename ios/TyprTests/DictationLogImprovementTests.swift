import XCTest
@testable import Typr

@MainActor
final class DictationLogImprovementTests: XCTestCase {
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
