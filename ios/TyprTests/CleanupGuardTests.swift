import XCTest
@testable import Typr

@MainActor
final class CleanupGuardTests: XCTestCase {
    /// Transcript and Apple Intelligence answer of four real dictations.
    private let loggedCases: [(transcript: String, answer: String, reason: CleanupFailureReason)] = [
        ("Aber bewerb dich doch einfach da, warum auch nicht?",
         "1. Aber\n2. bewerb dich doch einfach da\n3. warum auch nicht", .unjustifiedList),
        ("Das ist ein Test. Mal gucken, was jetzt hierbei rumkommt.",
         "1. Das ist ein Test.  \n2. Mal gucken, was jetzt hierbei rumkommt.", .unjustifiedList),
        ("Das ist ein Test, hallo, mein Wissen, ob es jetzt klappt.",
         "1. Das ist ein Test.\n2. Hallo.\n3. Mein Wissen.\n4. Ob es jetzt klappt.", .unjustifiedList),
        ("Ja, oder einfach umstecken.", "Ja, ja, oder einfach umstecken.", .repeatedWord)
    ]

    func testLoggedBadAnswersAreRejected() {
        for item in loggedCases {
            XCTAssertEqual(CleanupGuard.rejection(answer: item.answer, transcript: item.transcript), item.reason, item.transcript)
        }
    }

    func testSpokenEnumerationsMayBecomeLists() {
        let cases = [
            ("erstens Milch zweitens Eier", "1. Milch\n2. Eier"),
            ("Punkt eins Milch Punkt zwei Eier", "1. Milch\n2. Eier"),
            ("point one milk point two eggs", "1. Milk\n2. Eggs"),
            ("first milk second eggs", "1. Milk\n2. Eggs"),
            ("1. Milch 2. Eier", "1. Milch\n2. Eier")
        ]
        for (transcript, answer) in cases {
            XCTAssertNil(CleanupGuard.rejection(answer: answer, transcript: transcript), transcript)
        }
    }

    func testPlainAnswersPass() {
        XCTAssertNil(CleanupGuard.rejection(answer: "Es waren 2. Wahl Schuhe.", transcript: "es waren zweite wahl schuhe"))
        XCTAssertNil(CleanupGuard.rejection(answer: "Ja, das ist, ist das so.", transcript: "ja das ist ist das so"))
        XCTAssertNil(CleanupGuard.rejection(answer: "Aber bewerb dich doch einfach da.", transcript: "Aber bewerb dich doch einfach da"))
    }

    func testCoordinatorPastesTranscriptForInventedList() async {
        for item in loggedCases {
            let session = CleanupTestSession(), bg = CleanupTestBackground(), observer = CleanupTestObserver(), sleeper = CleanupTestSleeper()
            session.result = item.answer
            let deps = TranscriptCleanupDependencies(cleaner: CleanupTestCleaner(session: session), background: bg, isEnabled: { true }, sleep: sleeper.sleep, observer: observer)
            let job = CleanupJob(session: session, background: bg); job.begin()
            let value = await CleanupCoordinator().clean(item.transcript, job: job, dependencies: deps)
            XCTAssertEqual(value, item.transcript)
            XCTAssertEqual(observer.events.map(\.outcome), [.failed(item.reason)])
            job.finish(); sleeper.fire()
            for _ in 0..<30 { await Task.yield() }
        }
    }
}
