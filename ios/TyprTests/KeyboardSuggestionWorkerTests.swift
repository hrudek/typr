import Foundation
import XCTest
@testable import Typr

@MainActor
final class KeyboardSuggestionWorkerTests: XCTestCase {
    private final class Checker: TextChecking {
        var calls = 0
        func isWordValid(_ word: String) -> Bool { calls += 1; return ["the", "hello"].contains(word) }
        func guesses(for word: String) -> [String] {
            calls += 1
            return ["helo": ["hello"], "teh": ["the"]][word.lowercased()] ?? []
        }
        func completions(for prefix: String) -> [String] { calls += 1; return [] }
    }

    /// Explicit continuation gate, not sleeps: a job can stay blocked across edits/cancellation.
    private actor Gate {
        var requests: [KeyboardSuggestionWorker.Request] = []
        var continuation: CheckedContinuation<KeyboardSuggestionWorker.Result, Never>?
        func rank(_ request: KeyboardSuggestionWorker.Request) async -> KeyboardSuggestionWorker.Result {
            requests.append(request)
            return await withCheckedContinuation { continuation = $0 }
        }
        func count() -> Int { requests.count }
        func request(at index: Int) -> KeyboardSuggestionWorker.Request { requests[index] }
        func release(requestIndex: Int? = nil) {
            let request = requestIndex.map { requests[$0] } ?? requests.last
            guard let request, let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: .init(request: request, outcome: nil, seconds: 0))
        }
    }

    private func waitForJob(_ gate: Gate, count: Int = 1) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.count() < count, ContinuousClock.now < limit { await Task.yield() }
        let actual = await gate.count()
        XCTAssertEqual(actual, count)
    }

    private func keyboard(worker: KeyboardSuggestionWorker? = nil,
                          session: KeyboardLearningSession? = nil,
                          context: KeyboardContextResources? = nil) -> (FullKeyboardEngine, FixtureTextTarget, Checker) {
        let target = FixtureTextTarget()
        let checker = Checker()
        // Freeze the original worker-policy fixtures without corpus context. Otherwise a
        // real asynchronous bundled load can refresh a continuation-gated job mid-test,
        // and Space now legitimately queues a prediction instead of leaving no job.
        let engine = FullKeyboardEngine(target: target,
                                        autocorrect: AutocorrectEngine(checker: checker, learning: session, spatialDecoder: nil,
                                                                       contextResources: context ?? .init(model: nil)),
                                        suggestionWorker: worker)
        engine.width = 393
        engine.configureForField()
        return (engine, target, checker)
    }

    private func type(_ text: String, _ engine: FullKeyboardEngine) throws {
        for letter in text {
            let key = try XCTUnwrap(engine.layout.key(.character(String(letter))))
            let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
            engine.touchBegan(id: 1, at: point)
            engine.touchEnded(id: 1, at: point)
        }
    }

    func testAimSnapshotIsFrozenAndLearningDropsOldResultWithoutPollChurn() async throws {
        let session = KeyboardLearningSession()
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, target, checker) = keyboard(worker: worker, session: session)
        try type("teh", engine)
        let e = try XCTUnwrap(engine.layout.key(.character("e"))).frame
        func train(_ x: Double) {
            for i in 0..<40 {
                let delta = i % 2 == 0 ? 0.1 : -0.1
                session.learn([.init(point: CGPoint(
                    x: e.midX + (x + delta) * (e.width + engine.layout.metrics.gap),
                    y: e.midY + delta * (e.height + engine.layout.metrics.rowGap)), letter: "e")],
                    layout: engine.layout, source: .keep)
            }
        }
        train(0.2)
        engine.refreshSuggestions()
        await waitForJob(gate)
        let request = await gate.request(at: 0)
        let frozen = try XCTUnwrap(request.calibration)
        XCTAssertNotEqual(frozen.keys["e"]?.covarianceXY, 0)
        let chip = try XCTUnwrap(engine.suggestions.first)
        train(-0.2)
        XCTAssertNotEqual(session.calibration(for: engine.layout), frozen)
        XCTAssertEqual(request.calibration, frozen, "Live aim changes must not mutate a Sendable request")
        let calls = checker.calls
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(checker.calls, calls, "Stale aim result must be refused before checker/cache/diagnostics")
        engine.acceptSuggestion(chip)
        XCTAssertEqual(target.text, "Teh")
        XCTAssertTrue(session.protections.kept.isEmpty)
        await waitForJob(gate, count: 2)
        let second = await gate.request(at: 1)
        XCTAssertEqual(second.ownership.learning, session.generation)
        train(0)
        XCTAssertNotEqual(second.ownership.learning, session.generation)
        let learnedGeneration = session.generation
        for _ in 0..<100 { _ = session.calibration(for: engine.layout) }
        XCTAssertEqual(session.generation, learnedGeneration, "Read-only snapshots cannot churn ownership")
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(checker.calls, calls)
        engine.refreshSuggestionsIfStale()
        await waitForJob(gate, count: 3)
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.last?.replacement, "The")
        print("EVAL M114_aimOwnership frozen=true staleLearnDropped=true snapshotReads=100 generationStable=true")
    }

    func testManualChoiceLearnsAimAndEmptyDiscardsKeepOwnership() async throws {
        let (engine, target, _) = keyboard()
        try type("teh", engine)
        await engine.waitForSuggestions()
        let choice = try XCTUnwrap(engine.suggestions.first { $0.replacement.lowercased() == "the" })
        engine.acceptSuggestion(choice)
        XCTAssertEqual(target.text, "The ")
        let session = engine.autocorrect.learning
        let id = KeyboardLayoutSignature(engine.layout).id
        XCTAssertFalse(session.model.state.layouts[id]?.aims?.isEmpty ?? true, "Applied manual choice taught its keys' aim")
        let trained = session.generation
        engine.discardTouchEvidence()
        engine.discardTouchEvidence()
        XCTAssertEqual(session.generation, trained, "Repeated empty discards do not refresh learning ownership")
        await engine.waitForSuggestions()
    }

    func testInsertionNeverCallsCheckerAndReadyResultUsesSamePolicy() async throws {
        let (engine, target, checker) = keyboard()
        try type("teh", engine)
        XCTAssertEqual(checker.calls, 0, "No checker call on key insertion")
        XCTAssertEqual(target.text.lowercased(), "teh")
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.map(\.replacement), ["Teh", "The"])
        let choice = try XCTUnwrap(engine.suggestions.last)
        engine.acceptSuggestion(choice)
        XCTAssertEqual(target.text, "The ")
    }

    func testHeldChipKeepsTouchDownChoiceAndRejectsNewTokenOnRelease() async throws {
        let (engine, target, _) = keyboard()
        try type("teh", engine)
        var selection = KeyboardSuggestionSelection()
        let original = try XCTUnwrap(engine.suggestions.last)
        selection.begin(slot: 1, suggestions: engine.suggestions)
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.last?.replacement, "The")
        XCTAssertEqual(selection.finish(slot: 1), original, "Ranking during a hold must not change the chosen chip")
        selection.begin(slot: 1, suggestions: engine.suggestions)
        try type("x", engine)
        engine.acceptSuggestion(try XCTUnwrap(selection.finish(slot: 1)))
        XCTAssertEqual(target.text, "Tehx", "Held chip from an older token is refused on release")
        for slot in 0..<100 { selection.begin(slot: slot, suggestions: engine.suggestions) }
        XCTAssertLessThanOrEqual(selection.count, 3)
        selection.cancel(slot: 0)
        XCTAssertNil(selection.finish(slot: 0), "Cancelled touch must not pick the newer slot")
        XCTAssertNil(selection.finish(slot: 99))
        engine.cancelSuggestions()
    }

    func testOneRunningPlusOneLatestAndStaleCompletionCannotPublish() async throws {
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, target, _) = keyboard(worker: worker)
        try type("t", engine)
        await waitForJob(gate)
        let staleChip = try XCTUnwrap(engine.suggestions.first)
        try type("eh", engine)
        for _ in 0..<100 { engine.refreshSuggestions() }
        XCTAssertEqual(worker.queuedCount, 1)
        engine.acceptSuggestion(staleChip)
        XCTAssertEqual(target.text, "Teh", "Stale chip cannot edit or learn")
        XCTAssertTrue(engine.autocorrect.learning.protections.kept.isEmpty)
        await gate.release()
        await waitForJob(gate, count: 2)
        XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace), "Old completion was dropped")
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.last?.replacement, "The")
        let total = await gate.count()
        XCTAssertEqual(total, 2, "Intermediate 101 requests were replaced, not enqueued")
    }

    func testConfigurationLearningAndEpochChangesDropInFlightResults() async throws {
        for mutation in 0..<5 {
            let gate = Gate()
            let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
            let (engine, target, _) = keyboard(worker: worker)
            try type("teh", engine)
            await waitForJob(gate)
            let staleChip = try XCTUnwrap(engine.suggestions.first)
            switch mutation {
            case 0: engine.autocorrect.englishEnabled = false
            case 1: engine.autocorrect.learning.keep("teh")
            case 2: engine.autocorrect.isEnabled = false
            case 3: engine.width = 430
            default:
                // Same text, different field lifetime must still fail ownership.
                engine.configureForField()
            }
            engine.acceptSuggestion(staleChip)
            XCTAssertEqual(target.text, "Teh")
            // Field/layout changes may have queued a new request; cancellation drops both.
            worker.cancel()
            await gate.release()
            await engine.waitForSuggestions()
            XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace))
        }
    }

    func testOutOfOrderResultCannotFinishNewerRequest() async throws {
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, _, _) = keyboard(worker: worker)
        try type("t", engine)
        await waitForJob(gate)
        try type("eh", engine)
        await gate.release()
        await waitForJob(gate, count: 2)
        await gate.release(requestIndex: 0) // Deliver old result through newer callback.
        await engine.waitForSuggestions()
        XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace))
        engine.refreshSuggestions()
        await waitForJob(gate, count: 3)
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.last?.replacement, "The")
    }

    func testLearningSwitchAndBothResetEpochsRejectOldJobAndChip() async throws {
        for mutation in 0..<3 {
            let name = "P1-epoch-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let session = KeyboardLearningSession(defaults: defaults)
            let store = KeyboardLearningStore(directory: nil, defaults: defaults)
            let gate = Gate()
            let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
            let (engine, target, _) = keyboard(worker: worker, session: session)
            try type("teh", engine)
            await waitForJob(gate)
            let chip = try XCTUnwrap(engine.suggestions.first)
            if mutation == 0 { defaults.set(false, forKey: "keyboard.personalLearning") }
            else if mutation == 1 { XCTAssertTrue(store.requestLearningReset()) }
            else { XCTAssertTrue(store.requestDiagnosticsReset()) }
            engine.autocorrect.syncLearning()
            engine.acceptSuggestion(chip)
            XCTAssertEqual(target.text, "Teh")
            XCTAssertTrue(session.protections.kept.isEmpty)
            // Refusal refreshes the strip now; isolate the old job's cancellation here.
            worker.cancel()
            await gate.release()
            await engine.waitForSuggestions()
            XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace))
        }
    }

    func testResourceInstallationMidJobRejectsLoadingSnapshot() async throws {
        let source = SpatialWordDecoder(bundle: Bundle.main)
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let target = FixtureTextTarget()
        let ac = AutocorrectEngine(checker: Checker(), spatialDecoder: source, contextResources: .init(model: nil))
        let engine = FullKeyboardEngine(target: target, autocorrect: ac, suggestionWorker: worker)
        engine.configureForField()
        try type("teh", engine)
        await waitForJob(gate)
        let chip = try XCTUnwrap(engine.suggestions.first)
        source.prepareResources()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while source.isResourceLoading, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(source.isResourceLoading)
        XCTAssertEqual(source.resourceRevision, 1)
        engine.acceptSuggestion(chip)
        XCTAssertEqual(target.text, "Teh")
        XCTAssertTrue(engine.suggestions.allSatisfy { $0.ownership == engine.suggestionOwnership })
        worker.cancel() // The refreshed strip is tested separately; drop its queued job here.
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace))
    }

    func testCancelAndSuspensionNeverReadHiddenTargetOrPublishLate() async throws {
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, _, checker) = keyboard(worker: worker)
        try type("teh", engine)
        await waitForJob(gate)
        engine.suspendSuggestions()
        engine.refreshSuggestions()
        XCTAssertEqual(worker.queuedCount, 0)
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertTrue(engine.suggestions.isEmpty)
        XCTAssertEqual(checker.calls, 0)
        engine.configureForField()
        await waitForJob(gate, count: 2)
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.last?.replacement, "The")
    }

    func testBoundaryDoesNotWaitForWorkerAndRolloverKeepsOrder() async throws {
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, target, _) = keyboard(worker: worker)
        let t = try XCTUnwrap(engine.layout.key(.character("t"))).frame
        let e = try XCTUnwrap(engine.layout.key(.character("e"))).frame
        let h = try XCTUnwrap(engine.layout.key(.character("h"))).frame
        func point(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        engine.touchBegan(id: 1, at: point(t))
        engine.touchBegan(id: 2, at: point(e)) // commits held t
        await waitForJob(gate)
        engine.touchBegan(id: 3, at: point(h)) // commits held e
        engine.touchEnded(id: 3, at: point(h))
        engine.touchEnded(id: 2, at: point(e))
        engine.touchEnded(id: 1, at: point(t))
        XCTAssertEqual(target.text, "Teh")
        XCTAssertEqual(engine.autocorrect.touchInput.evidence(beforeInput: target.text)?.text, "Teh")
        let start = ContinuousClock.now
        engine.typeSpaceFromTyprKey()
        let boundaryDuration = start.duration(to: .now)
        // The continuation is still blocked: returning with the correction proves independence
        // from the worker, without asserting scheduler-dependent elapsed time.
        XCTAssertTrue(worker.isRunning)
        let rankedCalls = await gate.count()
        XCTAssertEqual(rankedCalls, 1)
        XCTAssertEqual(worker.queuedCount, 0)
        XCTAssertEqual(target.text, "The ", "Authoritative fallback does not await a blocked worker")
        print("EVAL P1_blockedBoundary duration=\(boundaryDuration) rankedCalls=\(rankedCalls) maxRunning=1 queued=\(worker.queuedCount) workerStillBlocked=true")
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertTrue(engine.suggestions.isEmpty)
        engine.deleteBackward()
        XCTAssertEqual(target.text, "Teh", "Immediate undo remains linked")
        engine.cancelSuggestions()
    }

    func testBoundaryQueuesPredictionsWithoutWaitingAndPreservesImmediateUndo() async throws {
        let model = try XCTUnwrap(BundledKeyboardData.contextModel)
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, target, _) = keyboard(worker: worker, context: .init(model: model))
        try type("teh", engine)
        await waitForJob(gate)
        engine.typeSpaceFromTyprKey()
        XCTAssertEqual(target.text, "The ", "Space must not wait for the blocked current-word job")
        XCTAssertTrue(engine.suggestions.isEmpty, "Never leave prior-token chips pickable")
        XCTAssertEqual(worker.queuedCount, 1, "One replaceable latest prediction, not another worker")
        await gate.release()
        await waitForJob(gate, count: 2)
        let prediction = await gate.request(at: 1)
        XCTAssertNil(prediction.ownership.token)
        XCTAssertNil(prediction.evidence)
        XCTAssertTrue(engine.suggestions.isEmpty, "Stale current-word result was dropped")
        await gate.release()
        await engine.waitForSuggestions()
        XCTAssertEqual(engine.suggestions.count, 3)
        XCTAssertTrue(engine.suggestions.allSatisfy { !$0.willAutoReplace && $0.kind != .keepLiteral })
        engine.deleteBackward()
        XCTAssertEqual(target.text, "Teh", "Prediction publication must not clear the boundary undo")
        engine.cancelSuggestions()
    }

    func testContextTokenAndUnicodeByteCapsDoNotQueueOversizedSnapshots() throws {
        let worker = KeyboardSuggestionWorker()
        let (engine, target, _) = keyboard(worker: worker)
        target.insertText(String(repeating: "word ", count: 100) + "teh")
        engine.textDidChange()
        XCTAssertLessThanOrEqual(engine.suggestionOwnership.context?.count ?? 0, 256)
        XCTAssertEqual(engine.suggestionOwnership.token, "teh")
        for _ in 0..<target.text.count { target.deleteBackward() }
        target.insertText(String(repeating: "a", count: 65))
        engine.textDidChange()
        XCTAssertTrue(engine.suggestions.isEmpty)
        XCTAssertEqual(worker.queuedCount, 0)
        for _ in 0..<65 { target.deleteBackward() }
        target.insertText("a" + String(repeating: "\u{0301}", count: 2_048))
        engine.textDidChange()
        XCTAssertNil(engine.suggestionOwnership.context, "A single grapheme must not defeat the UTF-8 byte cap")
        XCTAssertTrue(engine.suggestions.isEmpty)
        XCTAssertEqual(worker.queuedCount, 0)
        // Emoji/ZWJ-heavy text beyond 2,048 bytes keeps a byte-bounded suffix: the word still gets chips.
        for _ in 0..<target.text.count { target.deleteBackward() }
        target.insertText(String(repeating: "👨‍👩‍👧‍👦", count: 200) + " teh")
        engine.textDidChange()
        let context = try XCTUnwrap(engine.suggestionOwnership.context)
        XCTAssertLessThanOrEqual(context.utf8.count, FullKeyboardEngine.suggestionContextUTF8Limit)
        XCTAssertLessThanOrEqual(context.count, FullKeyboardEngine.suggestionContextLimit)
        XCTAssertTrue(target.text.hasSuffix(context))
        XCTAssertEqual(engine.suggestionOwnership.token, "teh")
        XCTAssertEqual(engine.suggestions.first?.kind, .keepLiteral)
        engine.cancelSuggestions()
    }

    // MARK: - Review R-P1 regressions

    /// Accepting the final "The" chip must work: proves the strip holds live, current chips.
    private func assertLiveRanking(_ engine: FullKeyboardEngine, _ target: FixtureTextTarget,
                                   _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(engine.suggestions.isEmpty, "Strip blanked: \(message)", file: file, line: line)
        XCTAssertTrue(engine.suggestions.allSatisfy { $0.ownership == engine.suggestionOwnership },
                      "Chips not owned by the current revision: \(message)", file: file, line: line)
        await engine.waitForSuggestions()
        let choice = try XCTUnwrap(engine.suggestions.first { $0.replacement == "The" }, message, file: file, line: line)
        engine.acceptSuggestion(choice)
        XCTAssertEqual(target.text, "The ", message, file: file, line: line)
    }

    func testEvidenceDiscardRepublishesLiveChipsInsteadOfBlankingTheStrip() async throws {
        for scenario in ["123 key", "#+= key", "width change", "selection change", "key slide", "trackpad", "cancelled touch"] {
            let (engine, target, _) = keyboard()
            try type("teh", engine)
            await engine.waitForSuggestions()
            switch scenario {
            case "123 key", "#+= key":
                let layer = try XCTUnwrap(engine.layout.key(.layerSwitch(.numbers))).frame
                engine.touchBegan(id: 5, at: CGPoint(x: layer.midX, y: layer.midY))
                engine.touchEnded(id: 5, at: CGPoint(x: layer.midX, y: layer.midY))
                if scenario == "#+= key" {
                    let symbols = try XCTUnwrap(engine.layout.key(.layerSwitch(.symbols))).frame
                    engine.touchBegan(id: 6, at: CGPoint(x: symbols.midX, y: symbols.midY))
                    engine.touchEnded(id: 6, at: CGPoint(x: symbols.midX, y: symbols.midY))
                }
                XCTAssertNotEqual(engine.layerState.layer, .letters)
            case "width change":
                engine.width = 430
            case "selection change":
                engine.discardTouchEvidence() // KeyboardViewController.selectionDidChange
            case "key slide":
                let q = try XCTUnwrap(engine.layout.key(.character("q"))).frame
                let w = try XCTUnwrap(engine.layout.key(.character("w"))).frame
                engine.touchBegan(id: 7, at: CGPoint(x: q.midX, y: q.midY))
                engine.touchMoved(id: 7, to: CGPoint(x: w.midX, y: w.midY))
                XCTAssertFalse(engine.suggestions.isEmpty, "Strip blanked during key slide")
                engine.touchCancelled(id: 7)
            case "trackpad":
                let space = try XCTUnwrap(engine.layout.key(.space)).frame
                engine.touchBegan(id: 8, at: CGPoint(x: space.midX, y: space.midY))
                engine.touchMoved(id: 8, to: CGPoint(x: space.midX + 12, y: space.midY))
                XCTAssertTrue(engine.isTrackpadActive)
                XCTAssertFalse(engine.suggestions.isEmpty, "Strip blanked on trackpad activation")
                engine.touchCancelled(id: 8)
            default:
                let e = try XCTUnwrap(engine.layout.key(.character("e"))).frame
                engine.touchBegan(id: 9, at: CGPoint(x: e.midX, y: e.midY))
                engine.touchCancelled(id: 9)
            }
            XCTAssertEqual(target.text, "Teh", scenario)
            try await assertLiveRanking(engine, target, scenario)
        }
    }

    func testRefusedChipAfterLearningSyncRepublishesLiveChips() async throws {
        for mutation in 0..<3 {
            let name = "P1-refusal-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let session = KeyboardLearningSession(defaults: defaults)
            let store = KeyboardLearningStore(directory: nil, defaults: defaults)
            let (engine, target, _) = keyboard(session: session)
            try type("teh", engine)
            await engine.waitForSuggestions()
            let chip = try XCTUnwrap(engine.suggestions.first { $0.replacement == "The" })
            if mutation == 0 { defaults.set(false, forKey: "keyboard.personalLearning") }
            else if mutation == 1 { XCTAssertTrue(store.requestLearningReset()) }
            else { XCTAssertTrue(store.requestDiagnosticsReset()) }
            // acceptSuggestion's own sync consumes the change, so a settings poll would not see it.
            engine.acceptSuggestion(chip)
            XCTAssertEqual(target.text, "Teh", "Chip from the old learning state is refused")
            try await assertLiveRanking(engine, target, "mutation \(mutation)")
        }
    }

    func testResourceInstallationRepublishesThroughTheStalePoll() async throws {
        let source = SpatialWordDecoder(bundle: Bundle.main)
        let target = FixtureTextTarget()
        let engine = FullKeyboardEngine(target: target,
                                        autocorrect: AutocorrectEngine(checker: Checker(), spatialDecoder: source))
        engine.width = 393
        engine.configureForField()
        try type("teh", engine)
        await engine.waitForSuggestions()
        let before = engine.suggestions
        engine.refreshSuggestionsIfStale()
        XCTAssertEqual(engine.suggestions, before, "A current strip is not republished by the poll")
        source.prepareResources()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while source.isResourceLoading, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(source.isResourceLoading)
        XCTAssertNotEqual(engine.suggestions.first?.ownership, engine.suggestionOwnership)
        engine.refreshSuggestionsIfStale() // FullKeyboardView.syncSettings, 4 Hz poll
        try await assertLiveRanking(engine, target, "after resource installation")
    }

    func testHostResumeKeepsLayerShiftAndUndoAndAKeyTouchResumes() async throws {
        let (engine, target, _) = keyboard()
        try type("teh", engine)
        engine.typeSpaceFromTyprKey()
        XCTAssertEqual(target.text, "The ")
        let layer = try XCTUnwrap(engine.layout.key(.layerSwitch(.numbers))).frame
        engine.touchBegan(id: 5, at: CGPoint(x: layer.midX, y: layer.midY))
        engine.touchEnded(id: 5, at: CGPoint(x: layer.midX, y: layer.midY))
        let shift = engine.shift
        engine.suspendSuggestions() // NSExtensionHostWillResignActive
        engine.resumeSuggestions()  // NSExtensionHostDidBecomeActive
        XCTAssertTrue(engine.suggestionsAreActive)
        XCTAssertEqual(engine.layerState.layer, .numbers, "Host activation must not reset the layer")
        XCTAssertEqual(engine.shift, shift)
        engine.deleteBackward()
        XCTAssertEqual(target.text, "Teh", "Immediate autocorrect undo survives host activation")

        // A missed activation notice: the first keyboard touch resumes suggestions.
        engine.suspendSuggestions()
        XCTAssertTrue(engine.suggestions.isEmpty)
        let lettersKey = try XCTUnwrap(engine.layout.key(.layerSwitch(.letters))).frame
        engine.touchBegan(id: 6, at: CGPoint(x: lettersKey.midX, y: lettersKey.midY))
        engine.touchEnded(id: 6, at: CGPoint(x: lettersKey.midX, y: lettersKey.midY))
        XCTAssertTrue(engine.suggestionsAreActive)
        XCTAssertEqual(engine.suggestions.first?.replacement, "Teh")
        await engine.waitForSuggestions()
        let literal = try XCTUnwrap(engine.suggestions.first)
        XCTAssertEqual(literal.kind, .keepLiteral)
        XCTAssertEqual(literal.ownership, engine.suggestionOwnership)
        // Undo's rejected-pair/session protection must survive too: "The" is no longer an auto fix.
        XCTAssertFalse(engine.suggestions.contains(where: \.willAutoReplace))
        engine.acceptSuggestion(literal)
        XCTAssertEqual(target.text, "Teh ")
    }

    func testResumePreservesCapsLockAndHeldTouchesAndTyprEditAlsoResumes() async throws {
        let (engine, target, _) = keyboard()
        var now: TimeInterval = 10
        engine.clock = { now }
        let key = try XCTUnwrap(engine.layout.key(.shift)).frame
        let point = CGPoint(x: key.midX, y: key.midY)
        for id in 20..<22 {
            engine.touchBegan(id: id, at: point)
            engine.touchEnded(id: id, at: point)
            now += 0.1
        }
        XCTAssertEqual(engine.shift.state, .locked)
        try type("teh", engine)
        XCTAssertEqual(target.text, "TEH")
        let q = try XCTUnwrap(engine.layout.key(.character("q"))).frame
        engine.touchBegan(id: 22, at: CGPoint(x: q.midX, y: q.midY))
        let touches = engine.touches
        let evidence = engine.autocorrect.touchInput.evidence(beforeInput: target.text)
        engine.suspendSuggestions()
        engine.resumeSuggestions()
        XCTAssertEqual(engine.shift.state, .locked)
        XCTAssertEqual(engine.touches, touches)
        XCTAssertEqual(engine.autocorrect.touchInput.evidence(beforeInput: target.text), evidence)
        engine.touchCancelled(id: 22)
        await engine.waitForSuggestions()
        XCTAssertFalse(engine.suggestions.isEmpty)

        // Typr's tap does not enter touchBegan on the letter plane; didEdit must resume too.
        engine.suspendSuggestions()
        engine.typeSpaceFromTyprKey()
        XCTAssertTrue(engine.suggestionsAreActive)
        XCTAssertEqual(target.text, "TEH ")
        try type("hello", engine)
        await engine.waitForSuggestions()
        XCTAssertFalse(engine.suggestions.isEmpty)
    }

    func testUnchangedRefreshReusesFinishedRankingWithoutSearchOrFlicker() async throws {
        let gate = Gate()
        let worker = KeyboardSuggestionWorker(rank: { await gate.rank($0) })
        let (engine, target, _) = keyboard(worker: worker)
        try type("teh", engine)
        await waitForJob(gate)
        await gate.release()
        await engine.waitForSuggestions()
        let finished = engine.suggestions.map { "\($0.replacement)|\($0.kind)|\($0.isCompletion)" }
        XCTAssertTrue(finished.contains { $0.hasPrefix("The|") })
        var changes = 0
        engine.onChange = { changes += 1 }
        for _ in 0..<5 { engine.refreshSuggestions() } // warmup, lexicon-free remount, poll
        XCTAssertEqual(engine.suggestions.map { "\($0.replacement)|\($0.kind)|\($0.isCompletion)" }, finished,
                       "No flicker back to interim literal chips")
        await engine.waitForSuggestions()
        let searches = await gate.count()
        XCTAssertEqual(searches, 1, "The identical search is not re-run")
        XCTAssertEqual(changes, 5, "Only ownership re-stamping, no interim strip")
        try await assertLiveRanking(engine, target, "reused ranking")
    }

    func testContextAndFieldRevalidationAndUnownedChoicesAreRejected() async throws {
        let (engine, target, _) = keyboard()
        try type("teh", engine)
        await engine.waitForSuggestions()
        let chip = try XCTUnwrap(engine.suggestions.last)
        for _ in 0..<3 { target.deleteBackward() }
        target.insertText("other Teh") // host changed context without callback yet
        engine.acceptSuggestion(chip)
        XCTAssertEqual(target.text, "other Teh")
        for _ in 0..<9 { target.deleteBackward() }
        target.insertText("Teh")
        target.autocorrectionType = .no
        engine.acceptSuggestion(chip)
        XCTAssertEqual(target.text, "Teh")
        target.autocorrectionType = .default
        target.keyboardType = .URL
        engine.acceptSuggestion(chip)
        XCTAssertEqual(target.text, "Teh", "Unnotified field trait change must also refuse")
        target.keyboardType = .default
        engine.acceptSuggestion(.init(displayText: "the", replacement: "the", kind: .secondary))
        XCTAssertEqual(target.text, "Teh")
    }
}
