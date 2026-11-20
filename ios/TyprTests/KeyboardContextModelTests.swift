import Foundation
import XCTest
@testable import Typr

final class KeyboardContextModelTests: XCTestCase {
    func testAllD3bReferenceVectors() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "swift-reference-vectors", withExtension: "json", subdirectory: "WordData"))
        let spec = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(model.unionSize, spec.union_size)
        // D3b vectors pin pack math and its historical accumulator, not R2-4's new
        // sentence filter. Keep their probability/top-three resource oracle intact.
        var state = (value: 0.0, weightDE: 0.5), sequence: [String] = []
        for v in spec.vectors {
            if v.sequence != sequence { state = (0, 0.5); sequence = v.sequence }
            if let word = v.consumed {
                XCTAssertEqual(model.evidence(word), try XCTUnwrap(v.evidence), accuracy: 1e-12)
                state.value = min(6, max(-6, 0.75 * state.value + model.evidence(word)))
            } else { state.value *= 0.5 }
            state.weightDE = 0.05 + 0.90 / (1 + exp(-state.value))
            XCTAssertEqual(state.value, v.state, accuracy: 1e-12)
            XCTAssertEqual(state.weightDE, v.weight_de, accuracy: 1e-12)
            for (suppress, expected) in [(Set<String>(), v.top3), (KeyboardContextModel.suppressed, v.top3_suppressed)] {
                let got = model.suggestions(after: v.context, weightDE: state.weightDE, suppress: suppress)
                XCTAssertEqual(got.map(\.key), expected.map(\.key), "\(v.sequence), \(v.context)")
                for (a, b) in zip(got, expected) { XCTAssertEqual(a.probability, b.probability, accuracy: 1e-12) }
            }
        }
    }

    func testCorruptTruncatedAndHostileFormat() throws {
        let data = try XCTUnwrap(BundledKeyboardData.contextModel?.de?.data)
        for length in [0, 1, 63, 64, 65, data.count - 1] {
            XCTAssertNil(KeyboardContextModel.Pack(data: Data(data.prefix(length))))
        }
        // Header counts, offsets, flags, discount, checksum and reserved fields.
        for offset in [0, 4, 6, 8, 10, 12, 16, 20, 24, 28, 32, 36, 44, 48, 52, 54, 56, 60] {
            var bad = data; bad[offset] ^= 0xff
            XCTAssertNil(KeyboardContextModel.Pack(data: bad), "header \(offset)")
        }
        // Repair CRC to reach the structural validator, not just the integrity check.
        for (offset, value) in [(64, UInt8(255)), (64 + 12, 1), (64 + 20 + 8, 0),
                                (try XCTUnwrap(BundledKeyboardData.contextModel?.de?.edgeOffset) + 1, 255),
                                (try XCTUnwrap(BundledKeyboardData.contextModel?.de?.edgeOffset) + 2, 1),
                                (try XCTUnwrap(BundledKeyboardData.contextModel?.de?.stringOffset), 255)] {
            var bad = data; bad[offset] = value
            repairCRC(&bad)
            XCTAssertFalse(KeyboardContextModel.Pack(data: bad) != nil, "record \(offset)")
        }
        XCTAssertNil(KeyboardContextModel.Pack(data: Data(repeating: 0, count: 1_048_577)))
    }

    func testFileReaderBoundsBeforeMappingAndSlicedData() throws {
        let data = try XCTUnwrap(BundledKeyboardData.contextModel?.de?.data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("context.tbg")
        XCTAssertNil(KeyboardContextModel.Pack(contentsOf: url))
        XCTAssertNil(KeyboardContextModel.Pack(contentsOf: directory))
        try data.write(to: url)
        let mapped = try XCTUnwrap(KeyboardContextModel.Pack(contentsOf: url))
        XCTAssertEqual(mapped.data, data)
        var prefixed = Data([0xff]); prefixed.append(data)
        let slice = prefixed.dropFirst()
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(KeyboardContextModel.Pack(data: slice)?.data, data)
        for size in [63, KeyboardContextModel.maxPackBytes + 1] {
            try Data(repeating: 0, count: size).write(to: url)
            XCTAssertNil(KeyboardContextModel.Pack(contentsOf: url), "size=\(size)")
        }
    }

    func testNormalizedBackoffAndSingleLanguageSelection() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel), de = try XCTUnwrap(model.de), en = try XCTUnwrap(model.en)
        for pack in [de, en] {
            for h: String? in [nil, "<s>", "ich", "i", "tom"] {
                let distribution = pack.distribution(h)
                let sum = (1..<pack.wordCount).reduce(0.0) { $0 + pack.probability(pack.word($1), distribution: distribution) }
                XCTAssertEqual(sum, 1, accuracy: 1e-12)
            }
        }
        XCTAssertEqual(de.probability("ich", after: nil), de.probability("ich", after: "unseenxyz"))
        XCTAssertNotEqual(de.probability("ich", after: nil), de.probability("ich", after: "<s>"))
        XCTAssertEqual(KeyboardContextModel.key("STRAẞE"), "straße")
        XCTAssertEqual(KeyboardContextModel.key("A\u{308}PFEL"), "äpfel")
        XCTAssertNotEqual(KeyboardContextModel.key("Maße"), KeyboardContextModel.key("Masse"))
        let single = try XCTUnwrap(KeyboardContextModel(de: de, en: nil))
        XCTAssertTrue(single.suggestions(after: "ich", weightDE: 0.5).isEmpty)
        XCTAssertEqual(single.suggestions(after: "ich", weightDE: 0, german: true, english: false),
                       model.suggestions(after: "ich", weightDE: 1, german: true, english: false))
        XCTAssertTrue(model.suggestions(after: "ich", weightDE: 0.5, german: false, english: false).isEmpty)
        for weight in [0.0, 0.05, 0.5, 0.95, 1.0] {
            XCTAssertEqual(model.suggestions(after: "tom", weightDE: weight).count, 3)
        }
    }

    func testSuffixRetokenizationBarriersAndReset() throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let c = model.context(before: "ich habe ein meeting morgen ", currentToken: nil)
        var state = KeyboardContextModel.State()
        for w in ["ich", "habe", "ein", "meeting", "morgen"] { state.consume(w, model: model) }
        XCTAssertEqual(c.state.value, state.value)
        XCTAssertEqual(c.previous, "morgen")
        XCTAssertEqual(model.context(before: "ich habe ein meeting mor", currentToken: "mor").previous, "meeting")
        XCTAssertEqual(model.context(before: "ich habe. ", currentToken: nil).previous, "<s>")
        XCTAssertEqual(model.context(before: "ich habe...!? ", currentToken: nil).state.value,
                       model.context(before: "ich habe. ", currentToken: nil).state.value)
        // A line break is a sentence start: no cross-line pair, the state halves once.
        XCTAssertEqual(model.context(before: "ich habe\n", currentToken: nil).previous, "<s>")
        XCTAssertEqual(model.context(before: "ich habe.\n\n", currentToken: nil).state.value,
                       model.context(before: "ich habe. ", currentToken: nil).state.value)
        XCTAssertEqual(model.context(before: "ich habe\nmeeting ", currentToken: nil).previous, "meeting")
        XCTAssertFalse(model.context(before: "\n\n", currentToken: nil).canPredict)
        XCTAssertEqual(KeyboardContextModel.stripOrder([1, 2, 3]), [2, 1, 3])
        XCTAssertEqual(KeyboardContextModel.stripOrder([1]), [1])
        XCTAssertTrue(model.supports(german: true, english: true))
        XCTAssertFalse(try XCTUnwrap(KeyboardContextModel(de: nil, en: model.en)).supports(german: true, english: true))
        for input: String? in [nil, "", "   ", "123 ", "ich 123 ", "https://example.com ", "x@y.com ", "camel_case "] {
            XCTAssertFalse(model.context(before: input, currentToken: nil).canPredict, "\(input ?? "nil")")
        }
        for barrier in ["x\u{0001}y", "ha\u{200b}be", "rock''n", "'", "a/b", "a_b", "x@y.com", "12.5"] {
            XCTAssertFalse(model.context(before: "ich \(barrier) ", currentToken: nil).canPredict, barrier)
            XCTAssertEqual(model.context(before: "ich \(barrier) habe ", currentToken: nil).previous, "habe")
        }
        XCTAssertEqual(model.context(before: "I don’t ", currentToken: nil).previous, "don't")
        XCTAssertEqual(model.context(before: "ich\thabe ", currentToken: nil).previous, "habe")
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 5_000)
        XCTAssertEqual(model.context(before: hugeGrapheme + " ich habe ", currentToken: nil).previous, "habe")
        XCTAssertFalse(model.context(before: hugeGrapheme + " ", currentToken: nil).canPredict)
        let long = String(repeating: "english ", count: 1000) + "ich habe "
        XCTAssertEqual(model.context(before: long, currentToken: nil).previous, "habe")
        XCTAssertEqual(model.context(before: nil, currentToken: nil).state.value, 0)
        let ranked = model.rerank(["glaube", "bin", "habe"], context: model.context(before: "ich ", currentToken: nil), german: true, english: false)
        XCTAssertEqual(ranked, ["bin", "habe", "glaube"])
        // Noisy channel within spatial readings: bounded gain, never across evidence kinds.
        let ich = model.context(before: "ich ", currentToken: nil)
        XCTAssertEqual(model.contextGain("habe", context: ich, german: true, english: false), log(20), accuracy: 1e-12)
        XCTAssertEqual(model.contextGain("velqora", context: ich, german: true, english: true), 0)
        XCTAssertEqual(model.contextGain("habe", context: model.context(before: "123 ", currentToken: nil),
                                         german: true, english: true), 0)
        XCTAssertEqual(model.rerank(["hase", "habe"], spatialScores: ["hase": -2, "habe": -2.5], context: ich,
                                    german: true, english: false), ["habe", "hase"])
        XCTAssertEqual(model.rerank(["hase", "habe"], spatialScores: ["hase": -1, "habe": -5], context: ich,
                                    german: true, english: false), ["hase", "habe"])
        XCTAssertEqual(model.rerank(["glaube", "hase", "habe"], spatialScores: ["hase": -2], context: ich,
                                    german: true, english: false), ["habe", "hase", "glaube"])
        XCTAssertEqual(model.rerank(["velqora", "hase"], spatialScores: ["velqora": -2, "hase": -2.1], context: ich,
                                    german: true, english: true), ["velqora", "hase"])
        XCTAssertEqual(model.rerank(Array(repeating: "word", count: 100), context: c, german: true, english: true).count, 32)
    }

    nonisolated private static let crcTable: [UInt32] = (0..<256).map { byte in
        (0..<8).reduce(UInt32(byte)) { crc, _ in (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
    }

    private func repairCRC(_ data: inout Data) {
        var crc: UInt32 = 0xffffffff
        for b in data.dropFirst(64) { crc = (crc >> 8) ^ Self.crcTable[Int((crc ^ UInt32(b)) & 0xff)] }
        crc ^= 0xffffffff
        for i in 0..<4 { data[56 + i] = UInt8(truncatingIfNeeded: crc >> (8 * i)) }
    }

    private struct Vectors: Decodable {
        let union_size: Int
        let vectors: [Vector]
    }
    private struct Vector: Decodable {
        let sequence: [String]
        let consumed: String?
        let evidence: Double?
        let state: Double
        let weight_de: Double
        let context: String
        let top3: [Pair]
        let top3_suppressed: [Pair]
    }
    private struct Pair: Decodable {
        let key: String
        let probability: Double
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            key = try container.decode(String.self); probability = try container.decode(Double.self)
        }
    }
}
