import XCTest
@testable import Typr

@MainActor
final class CleanupGuardTests: XCTestCase {
    private let loggedCases: [(transcript: String, answer: String, accepted: Bool)] = [
        ("Aber bewerb dich doch einfach da, warum auch nicht?",
         "1. Aber\n2. bewerb dich doch einfach da\n3. warum auch nicht", false),
        ("Das ist ein Test. Mal gucken, was jetzt hierbei rumkommt.",
         "1. Das ist ein Test.  \n2. Mal gucken, was jetzt hierbei rumkommt.", false),
        ("Das ist ein Test, hallo, mein Wissen, ob es jetzt klappt.",
         "1. Das ist ein Test.\n2. Hallo.\n3. Mein Wissen.\n4. Ob es jetzt klappt.", false),
        ("Ja, oder einfach umstecken.", "Ja, ja, oder einfach umstecken.", true)
    ]

    func testHexGuardOnLoggedAnswers() {
        for item in loggedCases {
            XCTAssertEqual(CleanupGuard.isAcceptable(original: item.transcript, cleaned: item.answer), item.accepted, item.transcript)
        }
    }

    func testHexGuardAcceptsCorrectionsAndRejectsNegationOrNumberChanges() {
        XCTAssertTrue(CleanupGuard.isAcceptable(original: "see you tuesday, no wait, wednesday", cleaned: "see you wednesday"))
        XCTAssertTrue(CleanupGuard.isAcceptable(original: "ich gehe zu open ai", cleaned: "ich gehe zu OpenAI"))
        XCTAssertFalse(CleanupGuard.isAcceptable(original: "I can come at 5", cleaned: "I can come at 6"))
        XCTAssertFalse(CleanupGuard.isAcceptable(original: "I do not agree with this plan", cleaned: "I agree with this plan"))
        XCTAssertFalse(CleanupGuard.isAcceptable(original: "hello there", cleaned: "  "))
    }

    func testCoordinatorPastesTranscriptWhenTheEngineRejectsTheAnswer() async {
        for item in loggedCases where !item.accepted {
            let session = CleanupTestSession(), bg = CleanupTestBackground(), observer = CleanupTestObserver(), sleeper = CleanupTestSleeper()
            session.result = item.answer
            session.acceptance = { CleanupGuard.isAcceptable(original: $1, cleaned: $0) }
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true }, sleep: sleeper.sleep, observer: observer)
            let job = CleanupJob(session: session, background: bg); job.begin()
            let value = await CleanupCoordinator().clean(item.transcript, job: job, dependencies: deps)
            XCTAssertEqual(value, item.transcript)
            XCTAssertEqual(observer.events.map(\.outcome), [.failed(.unacceptable)])
            job.finish(); sleeper.fire()
            for _ in 0..<30 { await Task.yield() }
        }
    }
}
