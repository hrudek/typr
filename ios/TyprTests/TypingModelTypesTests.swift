import Foundation
import XCTest
@testable import Typr

@MainActor
final class TypingModelTypesTests: XCTestCase {
    func testSignatureBucketsAndID() throws {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 393, showsGlobe: true))
        XCTAssertEqual(signature.orientation, "portrait")
        XCTAssertEqual(signature.widthBucket, 392)
        XCTAssertEqual(signature.id, "portrait-392-strip-globe")
        XCTAssertEqual(signature, KeyboardLayoutSignature(KeyboardLayout(width: 395.9, showsGlobe: true)))
        XCTAssertEqual(KeyboardLayoutSignature(KeyboardLayout(width: 388)).widthBucket, 392)
        XCTAssertEqual(KeyboardLayoutSignature(KeyboardLayout(width: 396)).widthBucket, 400)
        XCTAssertEqual(KeyboardLayoutSignature(KeyboardLayout(width: 387.9)).widthBucket, 384)

        let landscape = KeyboardLayoutSignature(KeyboardLayout(
            width: 393, orientation: .landscape, showsGlobe: false, showsStrip: false
        ))
        XCTAssertEqual(landscape.id, "landscape-392-no-strip-no-globe")
        XCTAssertNotEqual(signature, landscape)
        XCTAssertNotEqual(signature, KeyboardLayoutSignature(KeyboardLayout(width: 393)))
        XCTAssertNotEqual(signature, KeyboardLayoutSignature(KeyboardLayout(width: 393, showsGlobe: true, showsStrip: false)))
        XCTAssertEqual(try JSONDecoder().decode(KeyboardLayoutSignature.self, from: JSONEncoder().encode(signature)), signature)
    }

    func testCalibrationClampsAndPreservesValidEntries() {
        let valid = SpatialTouchCalibration.Key(offsetX: 0.1, offsetY: -0.2, sigmaX: 0.3, sigmaY: 0.4)
        let calibration = SpatialTouchCalibration(keys: [
            "a": .init(offsetX: -4, offsetY: 4, sigmaX: -1, sigmaY: 2),
            "b": .init(offsetX: 4, offsetY: -4, sigmaX: 2, sigmaY: -1),
            "c": valid,
        ])
        // ±.5 pitch: far-side one-hand thumb aim; the one-pitch label gate is unchanged.
        let bounds = SpatialTouchCalibration.scaleRange(degrees: 9)
        XCTAssertEqual(bounds.lowerBound, 0.08 * sqrt(7.0 / 9), accuracy: 1e-15)
        XCTAssertEqual(calibration.keys["a"], .init(offsetX: -0.5, offsetY: 0.5,
                                                    sigmaX: bounds.lowerBound, sigmaY: bounds.upperBound))
        XCTAssertEqual(calibration.keys["b"], .init(offsetX: 0.5, offsetY: -0.5,
                                                    sigmaX: bounds.upperBound, sigmaY: bounds.lowerBound))
        XCTAssertEqual(calibration.keys["c"], valid)
    }

    func testCalibrationDropsNonFiniteAndNonLowercaseLetterEntries() {
        let calibration = SpatialTouchCalibration(keys: [
            "a": .init(offsetX: .nan, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35),
            "b": .init(offsetX: 0, offsetY: .infinity, sigmaX: 0.35, sigmaY: 0.35),
            "c": .init(offsetX: 0, offsetY: 0, sigmaX: -.infinity, sigmaY: 0.35),
            "d": .init(offsetX: 0, offsetY: 0, sigmaX: 0.35, sigmaY: .nan),
            "A": .init(offsetX: 0, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35),
            "1": .init(offsetX: 0, offsetY: 0, sigmaX: 0.35, sigmaY: 0.35),
        ])
        XCTAssertTrue(calibration.keys.isEmpty)
    }

    func testNormalizationAndKeptLookup() {
        XCTAssertEqual(PersonalLexiconSnapshot.normalize("Straße"), "straße")
        let normalized = PersonalLexiconSnapshot.normalize("Mu\u{0308}ller")
        XCTAssertEqual(Array(normalized.unicodeScalars), Array("müller".unicodeScalars))
        let snapshot = PersonalLexiconSnapshot(kept: ["müller", "straße"], counts: [:], rejected: [])
        XCTAssertTrue(snapshot.isKept("Mu\u{0308}ller"))
        XCTAssertTrue(snapshot.isKept("Straße"))
        XCTAssertFalse(snapshot.isKept("strasse"))
    }

    func testBonusIsNormalizedNonnegativeAndBounded() {
        let snapshot = PersonalLexiconSnapshot(
            kept: [], counts: ["cat": 1, "dog": 3, "house": 15, "world": Int.max,
                               "müller": 1, "zero": 0, "negative": -1], rejected: []
        )
        XCTAssertEqual(snapshot.bonus(for: "cat"), 0.25, accuracy: 0.000001)
        XCTAssertEqual(snapshot.bonus(for: "dog"), 0.5, accuracy: 0.000001)
        XCTAssertEqual(snapshot.bonus(for: "house"), PersonalLexiconSnapshot.maxBonus)
        XCTAssertEqual(snapshot.bonus(for: "world"), PersonalLexiconSnapshot.maxBonus)
        XCTAssertEqual(snapshot.bonus(for: "Mu\u{0308}ller"), 0.25, accuracy: 0.000001)
        for word in ["missing", "zero", "negative"] { XCTAssertEqual(snapshot.bonus(for: word), 0) }
        XCTAssertEqual(PersonalLexiconSnapshot.empty.bonus(for: "cat"), 0)
    }

    func testPersonalScanPreparesSortedNormalizedAlphabetLabelsAndMaximumBonus() {
        let snapshot = PersonalLexiconSnapshot(kept: ["hello", "HELLO", "word1", "über"],
            counts: ["world": 2, "once": 1, "cat": 2], rejected: [])
        XCTAssertEqual(snapshot.scan.entries.map(\.word), ["cat", "hello", "world", "über"])
        for entry in snapshot.scan.entries {
            XCTAssertEqual(String(entry.labels.map { SpatialWordLexicon.alphabet[$0] }), entry.word)
            XCTAssertEqual(entry.bonus, snapshot.bonus(for: entry.word))
        }
        XCTAssertTrue(snapshot.scan.complete)
        XCTAssertEqual(snapshot.scan.maxBonus, snapshot.bonus(for: "cat"))
        let copy = snapshot
        XCTAssertTrue(copy.scan === snapshot.scan)
        let model = PersonalTypingModel()
        model.keep("hello")
        let first = model.lexicon
        XCTAssertTrue(first.scan === model.lexicon.scan)
        model.recordWord("world")
        XCTAssertFalse(first.scan === model.lexicon.scan)
        XCTAssertEqual(first.kept, model.lexicon.kept)
    }

    func testScanBonusesIgnoreNoncanonicalCountKeysButIncludeUnscannedWords() {
        let snapshot = PersonalLexiconSnapshot(kept: ["cat", "kept"],
            counts: ["cat": 2, "CAT": 10_000, "UPPER": 10_000, "once": 1, "negative": -1], rejected: [])
        XCTAssertEqual(snapshot.scan.entries.map(\.word), ["cat", "kept"])
        XCTAssertEqual(snapshot.scan.entries.first?.bonus, snapshot.bonus(for: "cat"))
        XCTAssertEqual(snapshot.scan.entries.last?.bonus, 0)
        XCTAssertEqual(snapshot.scan.maxBonus, snapshot.bonus(for: "cat"))
        // A count of one is not scanned, but still bounds the corpus search bonus.
        let single = PersonalLexiconSnapshot(kept: [], counts: ["once": 1], rejected: [])
        XCTAssertTrue(single.scan.entries.isEmpty)
        XCTAssertEqual(single.scan.maxBonus, 0.25)
        let unsupported = PersonalLexiconSnapshot(kept: [], counts: ["word1": 15], rejected: [])
        XCTAssertTrue(unsupported.scan.entries.isEmpty)
        XCTAssertEqual(unsupported.scan.maxBonus, PersonalLexiconSnapshot.maxBonus)
    }

    func testRejectedPairNormalizationLookupAndCodable() throws {
        let pair = RejectedCorrection(typed: "Mu\u{0308}ller", replacement: "Straße")
        XCTAssertEqual(Array(pair.typed.unicodeScalars), Array("müller".unicodeScalars))
        XCTAssertEqual(pair.replacement, "straße")
        let snapshot = PersonalLexiconSnapshot(kept: [], counts: [:], rejected: [pair])
        XCTAssertTrue(snapshot.isRejected(typed: "MÜLLER", replacement: "Straße"))
        XCTAssertFalse(snapshot.isRejected(typed: "Straße", replacement: "Müller"))
        XCTAssertFalse(snapshot.isRejected(typed: "Müller", replacement: "strasse"))
        XCTAssertEqual(try JSONDecoder().decode(RejectedCorrection.self, from: JSONEncoder().encode(pair)), pair)
        let raw = Data(#"{"typed":"Mu\u0308ller","replacement":"Straße"}"#.utf8)
        let decoded = try JSONDecoder().decode(RejectedCorrection.self, from: raw)
        XCTAssertEqual(Array(decoded.typed.unicodeScalars), Array("müller".unicodeScalars))
        XCTAssertEqual(decoded, pair)
    }
}
