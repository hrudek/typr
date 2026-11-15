import Foundation
#if !NEURAL_CLI
import XCTest
@testable import Typr
#endif

#if NEURAL_CLI || TYPR_RESEARCH
/// Research-only int8-weight / Float32-activation MLP. Not linked into the keyboard.
/// Run its XCTest gates with: bash ios/tools/run-research-tests.sh <simulator destination>.
/// TNN1: magic, UInt32 V/E/H; for embedding/hidden/output, Float32 row scales
/// then signed int8 row-major weights; finally Float32 hidden/output biases.
private struct NeuralSpikeModel {
    let vocabulary: Int
    let embedding: Int
    let hidden: Int
    let weights: [[Int8]]
    let scales: [[Float]]
    let hiddenBias: [Float]
    let outputBias: [Float]
    var macs: Int { 2 * embedding * hidden + vocabulary * hidden }
    var workspaceBytes: Int { 4 * (2 * embedding + hidden + vocabulary) }

    init?(_ data: Data) {
        guard data.count >= 16, Array(data.prefix(4)) == Array("TNN1".utf8) else { return nil }
        let bytes: [UInt8] = Array(data)
        func u32(_ at: Int) -> UInt32 {
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[at + i]) << (8 * i) }
            return value
        }
        let v: Int = Int(u32(4))
        let e: Int = Int(u32(8))
        let h: Int = Int(u32(12))
        guard (4...2048).contains(v), e == 16, h == 32 else { return nil }
        let matrixBytes: Int = v * e + 2 * e * h + v * h
        let scaleBytes: Int = 4 * (2 * v + h)
        let expected: Int = 16 + matrixBytes + scaleBytes + 4 * (h + v)
        guard data.count == expected else { return nil }
        var at: Int = 16
        func floats(_ count: Int) -> [Float] {
            var result: [Float] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                result.append(Float(bitPattern: u32(at)))
                at += 4
            }
            return result
        }
        var parsedWeights: [[Int8]] = []
        var parsedScales: [[Float]] = []
        let shapes: [(Int, Int)] = [(v, e), (h, 2 * e), (v, h)]
        for (rows, columns) in shapes {
            let rowScales: [Float] = floats(rows)
            guard rowScales.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            parsedScales.append(rowScales)
            let end: Int = at + rows * columns
            parsedWeights.append(bytes[at..<end].map { Int8(bitPattern: $0) })
            at = end
        }
        let hb: [Float] = floats(h)
        let ob: [Float] = floats(v)
        guard hb.allSatisfy(\.isFinite), ob.allSatisfy(\.isFinite) else { return nil }
        vocabulary = v; embedding = e; hidden = h
        weights = parsedWeights; scales = parsedScales
        hiddenBias = hb; outputBias = ob
    }

    func logits(_ earlier: Int, _ previous: Int) -> [Float]? {
        guard (0..<vocabulary).contains(earlier), (0..<vocabulary).contains(previous) else { return nil }
        var input: [Float] = Array(repeating: 0, count: 2 * embedding)
        for (slot, word) in [earlier, previous].enumerated() {
            for column in 0..<embedding {
                let index: Int = word * embedding + column
                input[slot * embedding + column] = Float(weights[0][index]) * scales[0][word]
            }
        }
        var state: [Float] = Array(repeating: 0, count: hidden)
        for row in 0..<hidden {
            var sum: Float = 0
            for column in 0..<input.count {
                sum += Float(weights[1][row * input.count + column]) * input[column]
            }
            state[row] = max(0, sum * scales[1][row] + hiddenBias[row])
        }
        var output: [Float] = Array(repeating: 0, count: vocabulary)
        for row in 0..<vocabulary {
            var sum: Float = 0
            for column in 0..<hidden {
                sum += Float(weights[2][row * hidden + column]) * state[column]
            }
            output[row] = sum * scales[2][row] + outputBias[row]
        }
        return output
    }
}

#endif // NEURAL_CLI || TYPR_RESEARCH

#if NEURAL_CLI
@main
struct NeuralSpikeCLI {
    static func main() throws {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--empty" {
            print("EVAL R2_10_swift_empty model_bytes=0")
            return
        }
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "arguments", code: 1) }
        let url: URL = URL(fileURLWithPath: CommandLine.arguments[1])
        // Preflight before reading untrusted model bytes.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= 124176 else {
            throw NSError(domain: "size", code: 2)
        }
        guard let model = NeuralSpikeModel(try Data(contentsOf: url)) else {
            throw NSError(domain: "format", code: 3)
        }
        let parity: String = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        var worst: Float = 0
        var calls: Int = 0
        let start: Double = ProcessInfo.processInfo.systemUptime
        for line in parity.split(separator: "\n") {
            let fields: [Float] = line.split(separator: " ").compactMap { Float($0) }
            guard fields.count == model.vocabulary + 2, fields.allSatisfy(\.isFinite),
                  fields[0] >= 0, fields[0] < Float(model.vocabulary),
                  fields[1] >= 0, fields[1] < Float(model.vocabulary),
                  let got = model.logits(Int(fields[0]), Int(fields[1])) else {
                throw NSError(domain: "vector", code: 4)
            }
            for i in got.indices { worst = max(worst, abs(got[i] - fields[i + 2])) }
            calls += 1
        }
        guard calls > 0, worst < 0.0001 else { throw NSError(domain: "parity", code: 5) }
        var checksum: Float = 0
        for _ in 0..<1000 { checksum += model.logits(1, 1)?[2] ?? 0 }
        let elapsed: Double = ProcessInfo.processInfo.systemUptime - start
        print("EVAL R2_10_swift vectors=\(calls) max_abs_error=\(worst) macs=\(model.macs) workspace_bytes=\(model.workspaceBytes) calls=1000 checksum=\(checksum) seconds=\(elapsed)")
    }
}
#else
final class KeyboardNeuralEvaluationTests: XCTestCase {
#if TYPR_RESEARCH
    private func fixture() -> Data {
        let v: Int = 4, e: Int = 16, h: Int = 32
        var data: Data = Data("TNN1".utf8)
        func append(_ value: UInt32) {
            var little: UInt32 = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for n in [v, e, h] { append(UInt32(n)) }
        for (rows, cols) in [(v, e), (h, 2 * e), (v, h)] {
            for _ in 0..<rows { append(Float(0.5).bitPattern) }
            data.append(Data(repeating: 1, count: rows * cols))
        }
        for _ in 0..<(h + v) { append(Float(0).bitPattern) }
        return data
    }

    func testDeterministicInt8ForwardAndBounds() throws {
        let data: Data = fixture()
        let model = try XCTUnwrap(NeuralSpikeModel(data))
        let first: [Float] = try XCTUnwrap(model.logits(1, 2))
        XCTAssertEqual(first, [128, 128, 128, 128])
        XCTAssertEqual(first, model.logits(1, 2))
        XCTAssertNil(model.logits(-1, 0)); XCTAssertNil(model.logits(0, 4))
        XCTAssertEqual(model.macs, 1152)
        XCTAssertEqual(model.workspaceBytes, 272)
        print("EVAL R2_10_contract deterministic=1 tiny_logits=128 macs=1152 workspace_bytes=272 automatic_changes=0 production_integration=0")
    }

    func testMalformedModelsAreRejected() {
        let valid: Data = fixture()
        for length in [0, 15, 16, valid.count - 1] {
            XCTAssertNil(NeuralSpikeModel(Data(valid.prefix(length))))
        }
        for offset in [0, 4, 8, 12] {
            var bad: Data = valid; bad[offset] = 255
            XCTAssertNil(NeuralSpikeModel(bad))
        }
        var bad: Data = valid
        bad[16] = 0; bad[17] = 0; bad[18] = 128; bad[19] = 127
        XCTAssertNil(NeuralSpikeModel(bad)) // infinity scale
        bad = valid; bad.append(0)
        XCTAssertNil(NeuralSpikeModel(bad))
    }

#else
    // Production regression: remains in the default TyprTests target.
    func testPersonalTrigramPrecedenceAndDeletionUnchanged() {
        var profile: PersonalBigramModel = .init()
        profile.record("morgen", after: "wir", earlier: "sehen")
        profile.record("morgen", after: "wir", earlier: "sehen")
        let selected = profile.select(after: "wir", earlier: "sehen")
        XCTAssertEqual(selected.context, "sehen wir")
        XCTAssertEqual(profile.probability("morgen", after: selected.context, corpus: 0.1), 0.55, accuracy: 1e-12)
        profile.purge("sehen")
        XCTAssertEqual(profile.select(after: "wir", earlier: "sehen").context, "wir")
        profile = .init()
        XCTAssertEqual(profile.probability("morgen", after: nil, corpus: 0.1), 0.1)
        print("EVAL R2_10_learning trigram_precedence=1 probability=0.55 delete_backoff=1 reset_corpus=1 neural_storage_bytes=0")
    }
#endif // TYPR_RESEARCH
}
#endif
