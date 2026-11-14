import XCTest
import SwiftUI
import UIKit
@testable import Typr

final class TapStatisticsTests: XCTestCase {
    private func summary(_ signature: KeyboardLayoutSignature, n: Int = 64,
                         offsetX: Double = 0, covariance: Double = 0) -> PersonalTypingModel.LayoutSummary {
        .init(signature: signature, lastUpdated: Date(), keys: [
            .init(letter: "a", n: n, offsetX: offsetX, offsetY: 0,
                  sigmaX: 0.2, sigmaY: 0.2, covarianceXY: covariance)
        ])
    }
    func testReconstructionKeepsGeometrySignatureAndHitRegions() {
        for width: CGFloat in [320, 375, 390, 440, 844] {
            for strip in [true, false] {
                for globe in [true, false] {
                    let original = KeyboardLayout(width: width, orientation: width > 500 ? .landscape : .portrait,
                                                  showsGlobe: globe, showsStrip: strip)
                    let signature = KeyboardLayoutSignature(original)
                    let board = TapStatistics.board(signature)
                    XCTAssertEqual(KeyboardLayoutSignature(board), signature)
                    XCTAssertEqual(board.horizontalInset, 0)
                    XCTAssertLessThanOrEqual(abs(board.width - original.width), 4)
                    for key in board.keys {
                        XCTAssertEqual(board.hitTest(CGPoint(x: key.frame.midX, y: key.frame.midY))?.kind, key.kind)
                    }
                    XCTAssertNil(board.hitTest(CGPoint(x: -1, y: -1)))
                }
            }
        }
    }
    func testSparseModelIsNeutralNotPerfect() {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let taps = TapStatistics(signature: signature, model: summary(signature, n: 19), heat: nil)
        XCTAssertEqual(taps.effectiveSamples, 19)
        XCTAssertNil(taps.onTarget)
        XCTAssertNil(taps.keys.first?.onTarget)
        XCTAssertTrue(taps.commonDeviations.isEmpty)
        XCTAssertEqual(TapStatistics.percent(taps.onTarget), "—")
    }
    func testThresholdAndOffsetUseKeyPitchesNotKeyWidths() throws {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let taps = TapStatistics(signature: signature, model: summary(signature, n: 20, offsetX: 0.3), heat: nil)
        let key = try XCTUnwrap(taps.layout.key(.character("a")))
        let stats = try XCTUnwrap(taps.keys.first)
        XCTAssertEqual(Double(stats.center.x - key.frame.midX), Double(key.frame.width + taps.layout.metrics.gap) * 0.3, accuracy: 1e-9)
        XCTAssertEqual(stats.yy, pow(Double(key.frame.height + taps.layout.metrics.rowGap) * 0.2, 2), accuracy: 1e-9)
        XCTAssertNotNil(stats.onTarget)
        XCTAssertGreaterThan(stats.onTarget ?? 0, 0)
        XCTAssertLessThan(stats.onTarget ?? 1, 1)
    }
    func testOffboardAndModifierMassIsNotRenormalizedAway() throws {
        let board = KeyboardLayout(width: 392)
        let edge = try XCTUnwrap(board.key(.character("q")))
        let shares = TapStatistics.landing(center: CGPoint(x: 0, y: edge.frame.midY), xx: 100, xy: 0, yy: 100, layout: board)
        XCTAssertLessThan(shares.values.reduce(0, +), 0.7)
        let space = try XCTUnwrap(board.key(.space))
        let modifier = TapStatistics.landing(center: CGPoint(x: space.frame.midX, y: space.frame.midY), xx: 1, xy: 0, yy: 1, layout: board)
        XCTAssertTrue(modifier.isEmpty)
    }
    func testCorrelatedGaussianAndInvalidCovariance() {
        let board = KeyboardLayout(width: 392)
        let shares = TapStatistics.landing(center: CGPoint(x: 200, y: 100), xx: 200, xy: 120, yy: 200, layout: board)
        XCTAssertFalse(shares.isEmpty)
        XCTAssertTrue(shares.values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertLessThanOrEqual(shares.values.reduce(0, +), 1.0000001)
        for (xx, xy, yy) in [(0.0, 0.0, 1.0), (1, 2, 1), (.nan, 0, 1)] {
            XCTAssertTrue(TapStatistics.landing(center: .zero, xx: xx, xy: xy, yy: yy, layout: board).isEmpty)
        }
    }
    func testDifferentLayoutsDoNotShareModelOrHeat() {
        let a = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let b = KeyboardLayoutSignature(KeyboardLayout(width: 440))
        let heat = UsageHeat(layout: b, geometryVersion: 1, cells: Array(repeating: 1, count: 64 * 24), updatedAt: Date())
        let taps = TapStatistics(signature: a, model: summary(b), heat: heat)
        XCTAssertTrue(taps.keys.isEmpty)
        XCTAssertNil(taps.heat)
        XCTAssertNil(taps.meanDrift)
        XCTAssertNil(taps.half(left: true))
    }
    func testHeatPopulationNeverBecomesAccuracy() {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let heat = UsageHeat(layout: signature, geometryVersion: 1, cells: Array(repeating: 2, count: 64 * 24), updatedAt: Date())
        let taps = TapStatistics(signature: signature, model: nil, heat: heat)
        XCTAssertEqual(taps.heatSamples, 3072)
        XCTAssertEqual(taps.effectiveSamples, 0)
        XCTAssertNil(taps.onTarget)
    }
    func testSummaryWeightsOnlyEligibleModelKeys() {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let sparse = summary(signature, n: 1, offsetX: 0.5).keys[0]
        var model = summary(signature)
        let other = PersonalTypingModel.KeySummary(letter: "s", n: 128, offsetX: 0.45, offsetY: 0,
                                                   sigmaX: 0.3, sigmaY: 0.3)
        model = .init(signature: signature, lastUpdated: Date(), keys: model.keys + [other])
        let taps = TapStatistics(signature: signature, model: model, heat: nil)
        let expected = taps.keys.reduce(0.0) { $0 + ($1.onTarget ?? 0) * Double($1.samples) } / 192
        XCTAssertEqual(taps.onTarget ?? -1, expected, accuracy: 1e-12)
        let mixed = TapStatistics(signature: signature, model: .init(signature: signature, lastUpdated: Date(), keys: [sparse, other]), heat: nil)
        XCTAssertEqual(mixed.onTarget, mixed.keys.first { $0.letter == "s" }?.onTarget)
    }

    func testSummarySkipsUnknownAndEmptyKeysButKeepsSparseKeys() {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let entries: [PersonalTypingModel.KeySummary] = [
            .init(letter: "unknown", n: 64, offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2),
            .init(letter: "a", n: 0, offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2),
            .init(letter: "s", n: 19, offsetX: 0, offsetY: 0, sigmaX: 0.2, sigmaY: 0.2)
        ]
        let model = PersonalTypingModel.LayoutSummary(signature: signature, lastUpdated: Date(), keys: entries)
        let taps = TapStatistics(signature: signature, model: model, heat: nil)
        XCTAssertEqual(taps.keys.map(\.letter), ["s"])
        XCTAssertEqual(taps.effectiveSamples, 19)
        XCTAssertNil(taps.keys.first?.onTarget)
        XCTAssertTrue(taps.keys.first?.neighbors.isEmpty == true)
    }

    func testNeighborsAndCommonDeviationsKeepOrderingAndLimit() throws {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        let entries = ["a", "s", "d", "f", "g"].map { letter in
            PersonalTypingModel.KeySummary(letter: letter, n: 64, offsetX: 0.3, offsetY: 0,
                                           sigmaX: 0.4, sigmaY: 0.4)
        }
        let model = PersonalTypingModel.LayoutSummary(signature: signature, lastUpdated: Date(), keys: entries)
        let taps = TapStatistics(signature: signature, model: model, heat: nil)
        var expected: [(from: String, to: String, share: Double)] = []
        for key in taps.keys {
            XCTAssertFalse(key.neighbors.contains { $0.letter == key.letter })
            for (left, right) in zip(key.neighbors, key.neighbors.dropFirst()) {
                XCTAssertTrue(left.share > right.share || (left.share == right.share && left.letter < right.letter))
            }
            let neighbor = try XCTUnwrap(key.neighbors.first)
            if neighbor.share >= 0.01 {
                expected.append((from: key.letter, to: neighbor.letter, share: neighbor.share))
            }
        }
        expected.sort { lhs, rhs in
            if lhs.share == rhs.share { return lhs.from < rhs.from }
            return lhs.share > rhs.share
        }
        XCTAssertEqual(taps.commonDeviations.count, 3)
        XCTAssertEqual(taps.commonDeviations.map(\.from), expected.prefix(3).map(\.from))
        XCTAssertEqual(taps.commonDeviations.map(\.to), expected.prefix(3).map(\.to))
        XCTAssertEqual(taps.commonDeviations.map(\.share), expected.prefix(3).map(\.share))
    }

    @MainActor
    func testPhysicalSummaryDoesNotInvertClampedDecoderSpread() throws {
        let signature = KeyboardLayoutSignature(KeyboardLayout(width: 392))
        var state = PersonalTypingModel.State()
        state.layouts[signature.id] = .init(signature: signature, lastUpdated: Date(), keys: [
            "a": .init(n: 64, meanX: 0.1, varianceX: 0.04, varianceY: 0.03)
        ])
        let physical = try XCTUnwrap(PersonalTypingModel.summarize(state, physicalTouch: true).layouts.first?.keys.first)
        let decoder = try XCTUnwrap(PersonalTypingModel.summarize(state).layouts.first?.keys.first)
        XCTAssertLessThan(physical.sigmaX, decoder.sigmaX)
        XCTAssertEqual(physical.offsetX, decoder.offsetX)
        XCTAssertLessThanOrEqual(physical.sigmaX, 0.5)
    }

    @MainActor
    func testFixturesAreReadOnlyAndSeparatePopulations() {
        let empty = StatisticsModel(directory: nil, defaults: nil, fixture: .empty)
        XCTAssertNotNil(empty.usage)
        XCTAssertTrue(empty.signatures.isEmpty)
        let sparse = StatisticsModel(directory: nil, defaults: nil, fixture: .sparse)
        XCTAssertEqual(sparse.signatures.count, 1)
        if let signature = sparse.signatures.first {
            let taps = sparse.taps(for: signature)
            XCTAssertEqual(taps.effectiveSamples, 3)
            XCTAssertEqual(taps.heatSamples, 1)
            XCTAssertNil(taps.onTarget)
        }
        let populated = StatisticsModel(directory: nil, defaults: nil, fixture: .populated)
        XCTAssertEqual(populated.signatures.count, 1)
        let saved = populated.learning?.model
        let signature = populated.signatures.first
        if let signature { XCTAssertGreaterThan(populated.taps(for: signature).heatSamples, 0) }
        populated.reset(); populated.refresh()
        XCTAssertTrue(populated.usage?.heat.isEmpty == true)
        XCTAssertEqual(populated.learning?.model, saved)
        if let signature {
            XCTAssertEqual(populated.taps(for: signature).heatSamples, 0)
            XCTAssertNotNil(populated.taps(for: signature).onTarget)
        }
    }

    @MainActor
    func testUnavailableStoreIsNotZeroHistory() {
        let model = StatisticsModel(directory: nil, defaults: nil)
        XCTAssertNil(model.usage)
        XCTAssertNil(model.learning)
        XCTAssertNotNil(model.problem)
        model.reset()
        XCTAssertNotNil(model.resetProblem)
        XCTAssertNil(model.usage)
    }

    @MainActor
    func testCorruptLearningIsUnavailableWithoutHidingMeasuredUsage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("invalid json".utf8).write(to: directory.appendingPathComponent("learning-v1.json"))
        let model = StatisticsModel(directory: directory, defaults: nil)
        XCTAssertNotNil(model.usage)
        XCTAssertNil(model.problem)
        XCTAssertNil(model.learning)
        XCTAssertFalse(KeyboardLearningStore.readSnapshot(directory: directory, defaults: nil).modelAvailable)
    }

    func testOnlyKnownFixtureRoutesAreAccepted() {
        for fixture in ["empty", "sparse", "populated", "unavailable"] {
            let args = ["Typr", "--snap-state", "settings-statistics-" + fixture]
            XCTAssertNotNil(StatisticsFixture.launchFixture(arguments: args))
            XCTAssertEqual(SettingsDestination.snapshotDestination(arguments: args), .statistics)
        }
        XCTAssertNil(StatisticsFixture.launchFixture(arguments: ["--snap-state", "settings-statistics-unknown"]))
        XCTAssertNil(SettingsDestination.snapshotDestination(arguments: ["--snap-state", "settings-statistics-unknown"]))
    }

    @MainActor
    func testAllBoardModesHaveFiniteSharedGeometryAtSmallWidth() throws {
        let snapshots = StatisticsFixture.populated.snapshots()
        let model = try XCTUnwrap(snapshots.1?.model.layouts.first)
        let taps = TapStatistics(signature: model.signature, model: model, heat: snapshots.0?.heat.first)
        for mode in TapDisplayMode.allCases {
            let host = UIHostingController(rootView: TapStatisticsBoard(taps: taps, mode: mode, selected: .constant("a")))
            let size = host.sizeThatFits(in: CGSize(width: 280, height: 400))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertLessThanOrEqual(size.width, 280.5)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    @MainActor
    func testStatisticsHostingFitsSmallPhoneAndAccessibilityText() {
        for fixture in [StatisticsFixture.empty, .sparse, .populated, .unavailable] {
            let host = UIHostingController(rootView: StatisticsView(fixture: fixture).environment(\.dynamicTypeSize, .accessibility3))
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 4000))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertLessThanOrEqual(size.width, 320.5)
        }
    }
}
