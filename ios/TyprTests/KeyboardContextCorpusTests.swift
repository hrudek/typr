import Foundation
import XCTest
@testable import Typr

/// Public source-disjoint test partition; selection never used to tune pruning.
final class KeyboardContextCorpusTests: XCTestCase {
    func testNewSourceHeldoutAndMixedSlots() throws {
        struct Fixture: Decodable { let sentences: [String: [[String]]] }
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "context-heldout-r2", withExtension: "json", subdirectory: "WordData"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        // Pin quality as deterministic integer hits, not wall-clock thresholds.
        let expected: [String: (pairs: Int, hit1: Int, hit3: Int)] = [
            "de_news": (701, 52, 95), "de_opus": (434, 41, 74),
            "de_wiki": (712, 39, 80), "en_news": (835, 86, 142),
            "en_opus": (447, 47, 88), "en_wiki": (811, 92, 168)
        ]
        for name in fixture.sentences.keys.sorted() {
            let sentences = try XCTUnwrap(fixture.sentences[name])
            XCTAssertEqual(sentences.count, 64)
            let german = name.hasPrefix("de_")
            var pairs = 0, hit1 = 0, hit3 = 0, wrong = 0
            var mixedHit1 = 0, mixedHit3 = 0, mixedWrong = 0
            for words in sentences {
                var state = KeyboardContextModel.State()
                for i in 0..<(words.count - 1) {
                    let previous = KeyboardContextModel.key(words[i])
                    let target = KeyboardContextModel.key(words[i + 1])
                    state.consume(previous, model: model)
                    let single = model.suggestions(after: previous, weightDE: state.weightDE,
                                                   german: german, english: !german)
                    let mixed = model.suggestions(after: previous, weightDE: state.weightDE)
                    hit1 += single.first?.key == target ? 1 : 0
                    hit3 += single.contains(where: { $0.key == target }) ? 1 : 0
                    mixedHit1 += mixed.first?.key == target ? 1 : 0
                    mixedHit3 += mixed.contains(where: { $0.key == target }) ? 1 : 0
                    for suggestion in single {
                        let ratio = model.logRatio(suggestion.key)
                        wrong += (german ? ratio <= -log(4) : ratio >= log(4)) ? 1 : 0
                    }
                    for suggestion in mixed {
                        let ratio = model.logRatio(suggestion.key)
                        mixedWrong += (german ? ratio <= -log(4) : ratio >= log(4)) ? 1 : 0
                    }
                    pairs += 1
                }
            }
            let denominator = Double(pairs)
            print(String(format: "EVAL R2_9_new_%@ sentences=64 pairs=%d recall1=%.4f recall3=%.4f wrong_slot_rate=%.4f mixed_recall1=%.4f mixed_recall3=%.4f mixed_wrong_slot_rate=%.4f",
                         name, pairs, Double(hit1) / denominator, Double(hit3) / denominator,
                         Double(wrong) / (denominator * 3), Double(mixedHit1) / denominator,
                         Double(mixedHit3) / denominator, Double(mixedWrong) / (denominator * 3)))
            let counts = try XCTUnwrap(expected[name])
            XCTAssertEqual(pairs, counts.pairs)
            XCTAssertEqual(hit1, counts.hit1)
            XCTAssertEqual(hit3, counts.hit3)
            XCTAssertLessThan(Double(wrong) / (denominator * 3), 0.2)
            XCTAssertLessThan(Double(mixedWrong) / (denominator * 3), 0.2)
        }
    }

    func testNewAlternatingLanguageSentences() throws {
        struct Fixture: Decodable { let sentences: [String: [[String]]] }
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "context-heldout-r2", withExtension: "json", subdirectory: "WordData"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        for source in ["news", "wiki", "opus"] {
            let de = try XCTUnwrap(fixture.sentences["de_" + source])
            let en = try XCTUnwrap(fixture.sentences["en_" + source])
            var pairs = 0, hit1 = 0, hit3 = 0, wrong = 0
            for k in 0..<min(de.count, en.count) {
                let first: [String] = k % 2 == 0 ? de[k] : en[k]
                let second: [String] = k % 2 == 0 ? en[k] : de[k]
                let targetGerman: Bool = k % 2 != 0
                var state = KeyboardContextModel.State()
                for word in first { state.consume(KeyboardContextModel.key(word), model: model) }
                state.sentenceBoundary()
                for i in 0..<(second.count - 1) {
                    let previous = KeyboardContextModel.key(second[i])
                    let target = KeyboardContextModel.key(second[i + 1])
                    state.consume(previous, model: model)
                    let suggestions = model.suggestions(after: previous, weightDE: state.weightDE)
                    hit1 += suggestions.first?.key == target ? 1 : 0
                    hit3 += suggestions.contains(where: { $0.key == target }) ? 1 : 0
                    for suggestion in suggestions {
                        let ratio = model.logRatio(suggestion.key)
                        wrong += (targetGerman ? ratio <= -log(4) : ratio >= log(4)) ? 1 : 0
                    }
                    pairs += 1
                }
            }
            let n = Double(pairs)
            print(String(format: "EVAL R2_9_new_alternating_%@ pairs=%d recall1=%.4f recall3=%.4f wrong_slot_rate=%.4f",
                         source, pairs, Double(hit1) / n, Double(hit3) / n, Double(wrong) / (n * 3)))
            XCTAssertGreaterThan(hit3, 0)
            XCTAssertLessThan(Double(wrong) / (n * 3), 0.10)
        }
    }

    func testCompiledPackDeterministicLoadWork() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let de = try XCTUnwrap(model.de)
        let en = try XCTUnwrap(model.en)
        XCTAssertEqual(de.wordCount, 8_001)
        XCTAssertEqual(en.wordCount, 8_001)
        XCTAssertEqual(de.edgeCount, 15_340)
        XCTAssertEqual(en.edgeCount, 20_065)
        let bytes = de.data.count + en.data.count
        XCTAssertEqual(bytes, 770_630)
        XCTAssertLessThanOrEqual(bytes, KeyboardContextModel.maxPackBytes)
        XCTAssertEqual(model.residentPayloadBytes, bytes + 32_000)
        print("EVAL R2_9_load mapped_bytes=\(bytes) word_records=16002 edge_records=35405 index_bytes=32000 resident_payload_bytes=\(model.residentPayloadBytes) format=TBG1 top_n=8000 top_k=3 min_count=10")
    }
}
