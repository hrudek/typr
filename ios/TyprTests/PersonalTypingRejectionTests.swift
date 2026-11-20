import Foundation
import XCTest
@testable import Typr

@MainActor
final class PersonalTypingRejectionTests: XCTestCase {
    func testSchemaFourMigrationPreservesPermanentRejections() throws {
        var state = PersonalTypingModel.State()
        state.schemaVersion = 4
        state.rejected = [RejectedCorrection(typed: "teh", replacement: "the")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["rejected"] = [["typed": "teh", "replacement": "the"]]
        let decoded = try JSONDecoder().decode(PersonalTypingModel.State.self,
            from: JSONSerialization.data(withJSONObject: object))
        let migrated = try XCTUnwrap(decoded.validated())
        XCTAssertEqual(migrated.schemaVersion, 5)
        let model = PersonalTypingModel(state: migrated)
        for _ in 0..<300 { model.recordWord("hello") }
        XCTAssertTrue(model.lexicon.isRejected(typed: "teh", replacement: "the"))
        XCTAssertNil(model.state.rejected.first?.remaining)
    }

    func testEventDecayContextsRefreshAndLearningOff() throws {
        let model = PersonalTypingModel()
        model.rejectCorrection(typed: "teh", replacement: "the", context: "send to")
        for _ in 0..<63 { model.recordWord("hello") }
        XCTAssertTrue(model.lexicon.isRejected(typed: "teh", replacement: "the", context: "other"))
        model.recordWord("hello")
        XCTAssertFalse(model.lexicon.isRejected(typed: "teh", replacement: "the", context: "other"))
        XCTAssertTrue(model.lexicon.isRejected(typed: "teh", replacement: "the", context: "send to"))
        model.isLearningEnabled = false
        for _ in 0..<300 { model.recordWord("hello") }
        XCTAssertEqual(model.state.rejected.first?.remaining, 192)
        model.isLearningEnabled = true
        for _ in 0..<192 { model.recordWord("hello") }
        XCTAssertTrue(model.state.rejected.isEmpty)
        model.rejectCorrection(typed: "teh", replacement: "the", context: "send to")
        model.recordWord("hello")
        model.rejectCorrection(typed: "teh", replacement: "the", context: "reply to")
        XCTAssertEqual(model.state.rejected.count, 1)
        XCTAssertEqual(model.state.rejected.first?.remaining, 256)
        XCTAssertEqual(model.state.rejected.first?.context, "reply to")
        model.forgetRejection(.init(typed: "teh", replacement: "the"))
        XCTAssertTrue(model.state.rejected.isEmpty)
    }

    func testContextExtractionAndValidation() {
        XCTAssertEqual(RejectedCorrection.context(before: "please send to teh", token: "teh"), "send to")
        XCTAssertEqual(RejectedCorrection.context(before: "Hello. to teh", token: "teh"), "to")
        XCTAssertNil(RejectedCorrection.context(before: "hello. teh", token: "teh"))
        XCTAssertNil(RejectedCorrection.context(before: nil, token: "teh"))
        let model = PersonalTypingModel()
        model.rejectCorrection(typed: "teh", replacement: "the", context: "send to")
        var state = model.state
        state.rejected[0].remaining = 257
        XCTAssertNil(state.validated())
        state = model.state; state.rejected[0].context = "bad."
        XCTAssertNil(state.validated())
        state = model.state; state.rejected[0].globalRemaining = -1
        XCTAssertNil(state.validated())
    }

    func testCapsRoundTripAndLiteralConfirmation() throws {
        let model = PersonalTypingModel()
        // Distinct letter-only pairs, no accidental dependence on timestamps.
        for index in 0..<600 {
            let a = String(UnicodeScalar(97 + index / 26)!)
            let b = String(UnicodeScalar(97 + index % 26)!)
            model.rejectCorrection(typed: "term" + a + b, replacement: "word", context: "send to")
        }
        XCTAssertEqual(model.state.rejected.count, 512)
        XCTAssertFalse(model.lexicon.isRejected(typed: "termaa", replacement: "word"))
        let data = try JSONEncoder().encode(model.state)
        XCTAssertLessThan(data.count, KeyboardLearningStore.maximumLearningBytes)
        let decoded = try JSONDecoder().decode(PersonalTypingModel.State.self, from: data)
        XCTAssertNotNil(decoded.validated())
        XCTAssertEqual(decoded.rejected.first?.remaining, 256)
        XCTAssertEqual(decoded.rejected.first?.context, "send to")
        model.rejectCorrection(typed: "teh", replacement: "the")
        XCTAssertFalse(model.lexicon.isKept("teh"))
        model.confirmLiteral("teh")
        XCTAssertTrue(model.lexicon.isKept("teh"))
    }
}
