import XCTest
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import Typr

@MainActor
final class DictationKeyboardFeedbackTests: XCTestCase {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "keyboard.feedback.\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: TyprSettings
        let bridge: DictationFeedbackBridge
        let store: DictationLogStore
        init() {
            defaults = UserDefaults(suiteName: suite)!
            settings = TyprSettings(defaults: defaults)
            settings.dictationLog = true; settings.dictationFeedbackStrip = true
            bridge = DictationFeedbackBridge(defaults: defaults, directory: root.appendingPathComponent("queue"))
            store = DictationLogStore(storage: DictationLogStorage(url: root.appendingPathComponent("archive/legacy.json")),
                settings: settings, feedbackBridge: bridge)
        }
        func ready() async throws { try await LogTestEnvironment.waitUntilLoaded(store) }
        func offer() -> DictationFeedbackOffer {
            var context = DictationLogContext(); context.keyboardJob = true
            let recording = store.begin(token: store.token(), context: context)!
            recording.finish(text: "Synthetic result.", beforeSpelling: "Synthetic result.")
            return store.makeKeyboardFeedbackOffer(recording: recording, jobID: UUID().uuidString,
                resultID: UUID().uuidString, expiresAt: Date().addingTimeInterval(600))!
        }
        func enqueue(_ event: DictationFeedbackEvent) async -> Bool {
            await withCheckedContinuation { c in bridge.enqueue(event) { c.resume(returning: $0) } }
        }
        func pending() async -> [DictationFeedbackEvent] {
            await withCheckedContinuation { c in bridge.pending { events, _ in c.resume(returning: events) } }
        }
        func drain() async throws {
            for _ in 0..<30 {
                store.drainKeyboardFeedback(force: true)
                await store.storage.flush(); await bridge.flush()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func diskEntry(_ id: UUID) throws -> DictationLogEntry {
            try JSONDecoder().decode(DictationLogEntry.self, from: Data(contentsOf: store.storage.root
                .appendingPathComponent("entries/\(id.uuidString).json")))
        }
        func dispose() async {
            await store.storage.flush(); await bridge.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func event(_ offer: DictationFeedbackOffer, rating: String = "bad", issues: [String]? = nil,
                       id: UUID = UUID(), date: Date = Date()) -> DictationFeedbackEvent {
        .init(eventID: id, offer: offer, rating: rating, issues: issues, createdAt: date)
    }

    func testColdStartArchiveReadinessAndRecreatedKeyboardOwnership() async throws {
        let f = Fixture()
        XCTAssertTrue(f.store.isLoading)
        var context = DictationLogContext(); context.keyboardJob = true
        let recording = try XCTUnwrap(f.store.begin(token: f.store.token(), context: context))
        recording.recognized("Original.", spelled: "Original.", asrMilliseconds: 12)
        let job = UUID().uuidString
        KeyboardBridge(defaults: f.defaults).ownFeedbackJob(job)
        await f.store.waitForFeedbackReadiness()
        recording.finish(text: "Original.", beforeSpelling: "Original.")
        let offer = try XCTUnwrap(f.store.makeKeyboardFeedbackOffer(recording: recording,
            jobID: job, resultID: UUID().uuidString, expiresAt: Date().addingTimeInterval(600)))
        // No controller-local job state survives; the new extension instance reads the bridge.
        let recreated = KeyboardBridge(defaults: f.defaults)
        let presentation = DictationFeedbackPresentation.inserted(offer: offer, resultID: offer.resultID,
            ownedJobs: recreated.feedbackJobs, permission: f.bridge.permission, now: Date())
        XCTAssertEqual(presentation?.panelContent, .ask)
        f.store.saveFeedback(for: offer.entryID, expectedText: nil, note: "I expected the name to be preserved.")
        try await f.drain()
        let saved = try f.diskEntry(offer.entryID)
        XCTAssertNil(saved.expectedText)
        XCTAssertEqual(saved.feedbackNote?.text, "I expected the name to be preserved.")
        XCTAssertEqual(saved.recognized?.text, "Original.")
        XCTAssertEqual(saved.finalText?.text, "Original.")
        await f.dispose()
    }

    func testNoteEditorPreservesLegacyReferenceRatingAndTextVersions() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer()
        f.store.saveFeedback(for: offer.entryID, expectedText: "Legacy reference.", note: "Old note.")
        f.store.rate(offer.entryID, rating: "bad", issues: ["unwanted_rewrite"])
        f.store.saveFeedback(for: offer.entryID, expectedText: nil, note: "Please keep my informal tone.")
        await f.store.storage.flush()
        var saved = try f.diskEntry(offer.entryID)
        XCTAssertEqual(saved.expectedText?.text, "Legacy reference.")
        XCTAssertEqual(saved.feedbackNote?.text, "Please keep my informal tone.")
        XCTAssertEqual(saved.rating, "bad")
        XCTAssertEqual(saved.issues, ["unwanted_rewrite"])
        XCTAssertEqual(saved.finalText?.text, "Synthetic result.")
        f.store.saveFeedback(for: offer.entryID, expectedText: nil, note: String(repeating: "ü", count: 2_001))
        XCTAssertEqual(f.store.entry(offer.entryID)?.feedbackNote?.text, saved.feedbackNote?.text)
        f.store.saveFeedback(for: offer.entryID, expectedText: nil, note: "")
        await f.store.storage.flush()
        saved = try f.diskEntry(offer.entryID)
        XCTAssertNil(saved.feedbackNote)
        XCTAssertEqual(saved.expectedText?.text, "Legacy reference.")
        await f.dispose()
    }

    func testFeedbackJobOwnershipIsBoundedAndSurvivesBridgeRecreation() {
        let suite = "feedback.jobs.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = KeyboardBridge(defaults: defaults)
        let jobs = (0..<40).map { _ in UUID().uuidString }
        jobs.forEach { bridge.ownFeedbackJob($0) }
        XCTAssertEqual(KeyboardBridge(defaults: defaults).feedbackJobs, Set(jobs.suffix(32)))
    }

    func testFeedbackShowsOnlyAcceptedAIOutputAndKeepsRecognitionUnchanged() {
        var context = DictationLogContext(); context.cleanupPath = .typr
        var entry = DictationLogEntry(context: context)
        entry.recognized = DictationLogText("uh original")
        entry.finalText = DictationLogText("Formatted.")
        entry.cleanupOutput = DictationLogText("AI revision")
        entry.aiAnswer = DictationLogText("Rejected or late answer")
        for use in [nil, "late", "rejected(empty); not used"] as [String?] {
            entry.answerUse = use
            XCTAssertNil(entry.feedbackAIText)
        }
        entry.answerUse = "accepted"
        XCTAssertEqual(entry.feedbackAIText?.text, "AI revision")
        entry.context.cleanupPath = .upstream
        entry.upstreamOutcome = "no result"
        XCTAssertNil(entry.feedbackAIText)
        entry.upstreamOutcome = "changed"
        XCTAssertEqual(entry.feedbackAIText?.text, "AI revision")
        entry.context.cleanupPath = .none
        XCTAssertNil(entry.feedbackAIText)
        XCTAssertEqual(entry.recognized?.text, "uh original")
    }

    func testDefaultOnAndFreshInsertedExactMatchingOnly() {
        let suite = "feedback.defaults.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TyprSettings(defaults: defaults).dictationFeedbackStrip)
        let offer = DictationFeedbackOffer(resultID: UUID().uuidString, jobID: UUID().uuidString,
            entryID: UUID(), archiveID: UUID(), generation: UUID(), expiresAt: Date().addingTimeInterval(600))
        let permission = DictationFeedbackPermission(archiveID: offer.archiveID, generation: offer.generation, enabled: true)
        XCTAssertNotNil(DictationFeedbackPresentation.inserted(offer: offer, resultID: offer.resultID,
            ownedJobs: [offer.jobID], permission: permission, now: Date()))
        XCTAssertNil(DictationFeedbackPresentation.inserted(offer: nil, resultID: offer.resultID,
            ownedJobs: [offer.jobID], permission: permission, now: Date()))
        XCTAssertNil(DictationFeedbackPresentation.inserted(offer: offer, resultID: "previous-result",
            ownedJobs: [offer.jobID], permission: permission, now: Date()))
        XCTAssertNil(DictationFeedbackPresentation.inserted(offer: offer, resultID: offer.resultID,
            ownedJobs: [], permission: permission, now: Date()))
        XCTAssertNil(DictationFeedbackPresentation.inserted(offer: offer, resultID: offer.resultID,
            ownedJobs: [offer.jobID], permission: nil, now: Date()))
        XCTAssertNil(DictationFeedbackPresentation.inserted(offer: offer, resultID: offer.resultID,
            ownedJobs: [offer.jobID], permission: permission, now: offer.expiresAt.addingTimeInterval(1)))
    }
    func testQueueRoundTripCategoryWholeSetAndReferenceOwnership() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer()
        let first = event(offer, issues: ["misheard"])
        let second = event(offer, issues: ["misheard", "too_slow"], date: first.createdAt.addingTimeInterval(0.001))
        let queuedFirst = await f.enqueue(first), queuedSecond = await f.enqueue(second)
        XCTAssertTrue(queuedFirst && queuedSecond)
        f.store.saveFeedback(for: offer.entryID, expectedText: "Human reference.", note: "Synthetic note.")
        try await f.drain()
        XCTAssertEqual(try f.diskEntry(offer.entryID).issues, ["misheard", "too_slow"])
        XCTAssertEqual(try f.diskEntry(offer.entryID).expectedText?.text, "Human reference.")
        XCTAssertEqual(try f.diskEntry(offer.entryID).feedbackNote?.text, "Synthetic note.")
        let pending = await f.pending(); XCTAssertTrue(pending.isEmpty)
        await f.dispose()
    }
    /// The inline "What I said" editor saves only the reference and keeps the separate note.
    func testInlineReferenceSaveKeepsNote() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer()
        f.store.saveFeedback(for: offer.entryID, expectedText: "First.", note: "Keep me.")
        f.store.saveFeedback(for: offer.entryID, expectedText: "What I actually said.", note: nil)
        XCTAssertEqual(f.store.entry(offer.entryID)?.expectedText?.text, "What I actually said.")
        XCTAssertEqual(f.store.entry(offer.entryID)?.feedbackNote?.text, "Keep me.")
        f.store.saveFeedback(for: offer.entryID, expectedText: "", note: nil)
        XCTAssertNil(f.store.entry(offer.entryID)?.expectedText)
        XCTAssertEqual(f.store.entry(offer.entryID)?.feedbackNote?.text, "Keep me.")
        await f.store.storage.flush()
        XCTAssertEqual(try f.diskEntry(offer.entryID).feedbackNote?.text, "Keep me.")
        await f.dispose()
    }
    func testSameTimestampTotalOrderAndAppEditsResolveByDefinedOrder() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer(), time = Date()
        let lower = event(offer, rating: "good", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, date: time)
        let upper = event(offer, issues: ["other"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, date: time)
        let a = await f.enqueue(upper), b = await f.enqueue(lower); XCTAssertTrue(a && b)
        try await f.drain()
        XCTAssertEqual(try f.diskEntry(offer.entryID).ratingOrder, upper.order)
        f.store.rate(offer.entryID, rating: "good", order: .init(modifiedAt: time.addingTimeInterval(1), origin: "app", eventID: UUID().uuidString))
        let duplicate = await f.enqueue(upper); XCTAssertTrue(duplicate)
        try await f.drain()
        XCTAssertEqual(try f.diskEntry(offer.entryID).rating, "good")
        await f.dispose()
    }
    func testCrashAfterDurableWriteBeforeQueueRemovalIsIdempotent() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer(), queued = event(offer)
        let success = await f.enqueue(queued); XCTAssertTrue(success)
        f.store.rate(offer.entryID, rating: queued.rating, order: queued.order)
        await f.store.storage.flush()
        let revision = try f.diskEntry(offer.entryID).revision
        let reloaded = DictationLogStore(storage: DictationLogStorage(url: f.store.storage.url), settings: f.settings, feedbackBridge: f.bridge)
        try await LogTestEnvironment.waitUntilLoaded(reloaded)
        for _ in 0..<30 {
            reloaded.drainKeyboardFeedback(force: true)
            await reloaded.storage.flush(); await f.bridge.flush(); try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try f.diskEntry(offer.entryID).revision, revision)
        let pending = await f.pending(); XCTAssertTrue(pending.isEmpty)
        await f.dispose()
    }
    func testSourceWriteFailureKeepsEventUntilDurableRetry() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer()
        await f.store.storage.flush()
        let directory = f.store.storage.root.appendingPathComponent("entries")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let queued = await f.enqueue(event(offer, issues: ["misheard"])); XCTAssertTrue(queued)
        try await f.drain()
        let pending = await f.pending(); XCTAssertEqual(pending.count, 1)
        XCTAssertNil(try f.diskEntry(offer.entryID).rating)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        f.store.retry(); try await f.drain()
        XCTAssertEqual(try f.diskEntry(offer.entryID).rating, "bad")
        let remaining = await f.pending(); XCTAssertTrue(remaining.isEmpty)
        await f.dispose()
    }
    func testOffClearDeleteAndToggleCannotAttachOldOffers() async throws {
        let f = Fixture(); try await f.ready(); let old = f.offer()
        f.store.setEnabled(false)
        let offQueued = await f.enqueue(event(old)); XCTAssertFalse(offQueued)
        f.store.setEnabled(true)
        let onQueued = await f.enqueue(event(old)); XCTAssertFalse(onQueued)
        let current = f.offer(); f.store.delete(current.entryID)
        let deletedQueued = await f.enqueue(event(current)); XCTAssertTrue(deletedQueued)
        try await f.drain()
        XCTAssertFalse(f.store.metadata.contains { $0.id == current.entryID })
        f.store.clear(); await f.store.storage.flush(); try await Task.sleep(for: .milliseconds(20))
        let clearQueued = await f.enqueue(event(current)); XCTAssertFalse(clearQueued)
        f.settings.dictationFeedbackStrip = false; f.store.feedbackSettingsChanged()
        let disabledQueued = await f.enqueue(event(old))
        XCTAssertFalse(disabledQueued)
        await f.dispose()
    }
    func testLoadingOfferDoesNotRevokePreviousSessionQueue() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer()
        await f.store.storage.flush()
        let queued = await f.enqueue(event(offer)); XCTAssertTrue(queued)
        let permission = f.bridge.permission
        let reloaded = DictationLogStore(storage: DictationLogStorage(url: f.store.storage.url), settings: f.settings, feedbackBridge: f.bridge)
        XCTAssertTrue(reloaded.isLoading)
        var context = DictationLogContext(); context.keyboardJob = true
        let recording = reloaded.begin(token: reloaded.token(), context: context)!
        recording.finish(text: "Synthetic cold result.", beforeSpelling: "Synthetic cold result.")
        XCTAssertNil(reloaded.makeKeyboardFeedbackOffer(recording: recording, jobID: UUID().uuidString,
            resultID: UUID().uuidString, expiresAt: Date().addingTimeInterval(600)))
        XCTAssertEqual(f.bridge.permission, permission)
        try await LogTestEnvironment.waitUntilLoaded(reloaded)
        for _ in 0..<30 {
            reloaded.drainKeyboardFeedback(force: true)
            await reloaded.storage.flush(); await f.bridge.flush(); try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try f.diskEntry(offer.entryID).rating, "bad")
        XCTAssertEqual(f.bridge.permission, permission)
        await f.dispose()
    }

    func testUnloadedOldEntryCanReceiveItsExactQueuedFeedback() async throws {
        let f = Fixture(); try await f.ready()
        var offer: DictationFeedbackOffer? = f.offer()
        let original = offer!
        for _ in 0..<DictationLogStore.maximumEntries {
            let rec = f.store.begin(token: f.store.token(), context: .init())!
            rec.finish(text: "Other synthetic result.", beforeSpelling: "Other synthetic result.")
        }
        await f.store.storage.flush(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(f.store.entry(original.entryID))
        let queued = await f.enqueue(event(original, issues: ["too_slow"])); XCTAssertTrue(queued)
        offer = nil
        try await f.drain()
        XCTAssertEqual(try f.diskEntry(original.entryID).rating, "bad")
        XCTAssertEqual(try f.diskEntry(original.entryID).issues, ["too_slow"])
        await f.dispose()
    }

    #if canImport(UIKit)
    private func visibleButtons(_ root: UIView) -> [UIButton] {
        guard !root.isHidden, root.alpha > 0 else { return [] }
        return (root as? UIButton).map { [$0] } ?? root.subviews.flatMap(visibleButtons)
    }

    private func pumpMainRunLoop() {
        // FullKeyboardView observes the model with `receive(on: RunLoop.main)`.
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func visibleButton(_ label: String, in root: UIView) -> UIButton? {
        visibleButtons(root).first { $0.accessibilityLabel == label }
    }

    private func makeKeyboard(
        model: KeyboardViewModel,
        target: FixtureTextTarget = FixtureTextTarget(text: "Host text"),
        showsBar: Bool = false
    ) -> FullKeyboardView {
        let view = FullKeyboardView(model: model, target: target,
            autocorrect: AutocorrectEngine(spatialDecoder: nil))
        view.suggestionBarOverride = showsBar
        view.frame = CGRect(x: 0, y: 0, width: 393, height: view.preferredHeight)
        view.layoutIfNeeded()
        return view
    }

    func testCompactSurfaceUsesFullPanelAndSharedActions() {
        let model = KeyboardViewModel()
        model.configureFixture(snapshot: .offline, now: 10_000)
        model.feedback = .snapshotFixture()
        var ratings: [String] = []
        var opened: URL?
        model.onFeedbackRating = { rating, _ in ratings.append(rating) }
        model.onOpenURL = { opened = $0 }
        let host = UIHostingController(rootView: KeyboardSurfaceView(model: model))
        // SwiftUI mounts UIViewRepresentable children as part of window presentation.
        // A detached hosting view can have no feedback panel in its UIKit hierarchy.
        // Visible without becoming key: making a window key starts the system text input
        // machinery, which takes seconds on a CI simulator.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 140))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        pumpMainRunLoop()
        let problem = visibleButton("Problem", in: host.view)
        XCTAssertNotNil(problem, "the compact surface has full-size rating tiles, not a reduced tray")
        problem?.sendActions(for: .touchUpInside)
        pumpMainRunLoop()
        XCTAssertEqual(ratings, ["bad"])
        let entryID = model.feedback?.offer.entryID
        visibleButton(TyprFeedbackPanel.openAccessibilityLabel, in: host.view)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened.flatMap { TyprFeedbackLink.entryID(from: $0) }, entryID)
        XCTAssertNotNil(opened)
        XCTAssertNil(model.feedback)

        model.feedback = .snapshotFixture()
        pumpMainRunLoop()
        visibleButton("Good", in: host.view)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(ratings, ["bad", "good"])
        XCTAssertNil(model.feedback)
    }

    func testFeedbackPanelTilesAreLargeAndInsideInBothAppearances() {
        for (dark, height) in [(false, CGFloat(140)), (true, CGFloat(140)),
                               (false, KeyboardLayout.height(for: .portrait, showsStrip: false)),
                               (true, KeyboardLayout.height(for: .portrait, showsStrip: false))] {
            let panel = TyprFeedbackPanel(frame: CGRect(x: 0, y: 0, width: 393, height: height))
            panel.palette = FullKeyboardPalette(isDark: dark)
            panel.metrics = KeyboardMetrics.for(.portrait, innerWidth: 393, showsStrip: false)
            let cases: [(TyprFeedbackPanel.Content, [String])] = [
                (.ask, ["Good", "Problem", TyprFeedbackPanel.dismissFeedbackLabel]),
                (.problem, [TyprFeedbackPanel.openAccessibilityLabel, TyprFeedbackPanel.dismissFeedbackLabel]),
                (.retry("Not queued: full, expired or unavailable"), ["Retry feedback", TyprFeedbackPanel.dismissFeedbackLabel]),
                (.notice("Turn on Keep mic warm in Typr first"), [TyprFeedbackPanel.dismissMessageLabel]),
            ]
            for (content, labels) in cases {
                panel.content = content
                panel.layoutIfNeeded()
                for label in labels {
                    guard let button = visibleButton(label, in: panel) else {
                        XCTFail("\(label) not visible (\(content), dark: \(dark))"); continue
                    }
                    let rect = button.convert(button.bounds, to: panel)
                    XCTAssertTrue(panel.bounds.contains(rect), label)
                    XCTAssertGreaterThanOrEqual(rect.width, 44, label)
                    XCTAssertGreaterThanOrEqual(rect.height, 30, label)
                }
            }
            panel.content = .ask
            panel.layoutIfNeeded()
            // The rating tiles take the room the keys had.
            let goodButton = visibleButton("Good", in: panel)!
            let good = goodButton.convert(goodButton.bounds, to: panel)
            XCTAssertGreaterThan(good.height, height == 140 ? 70 : 120)
            XCTAssertGreaterThan(good.width, 150)
            // Problem offers only Fix in Typr and ✕.
            panel.content = .problem
            panel.layoutIfNeeded()
            XCTAssertNil(visibleButton("Good", in: panel))
            XCTAssertNil(visibleButton("Problem", in: panel))
        }
    }

    /// On a device the full keyboard is mounted first and the feedback arrives with the inserted
    /// result. The panel must cover the keys then, not only when present at construction.
    func testFullKeyboardShowsFeedbackPanelThatArrivesAfterMount() {
        let model = KeyboardViewModel()
        model.configureFixture(snapshot: .offline, now: 10_000)
        var received: [String] = []
        model.onFeedbackRating = { rating, _ in received.append(rating) }
        let view = makeKeyboard(model: model)
        pumpMainRunLoop()
        XCTAssertNil(visibleButton("Good", in: view))
        XCTAssertNotNil(view.engine.layout.key(.character("q")))

        view.didInsertDictation()
        model.feedback = .snapshotFixture()
        pumpMainRunLoop()
        view.layoutIfNeeded()
        XCTAssertEqual(view.shownPanelContent, .ask)
        for label in ["Good", "Problem", TyprFeedbackPanel.dismissFeedbackLabel] {
            guard let button = visibleButton(label, in: view) else {
                XCTFail("\(label) not visible after a late feedback offer"); continue
            }
            XCTAssertTrue(view.bounds.contains(button.convert(button.bounds, to: view)), label)
        }

        visibleButton("Problem", in: view)?.sendActions(for: .touchUpInside)
        pumpMainRunLoop()
        view.layoutIfNeeded()
        XCTAssertEqual(received, ["bad"])
        XCTAssertEqual(view.shownPanelContent, .problem)
        XCTAssertNil(visibleButton("Good", in: view))
        XCTAssertNotNil(visibleButton(TyprFeedbackPanel.dismissFeedbackLabel, in: view))
        var opened: URL?
        model.onOpenURL = { opened = $0 }
        let open = visibleButton(TyprFeedbackPanel.openAccessibilityLabel, in: view)
        XCTAssertNotNil(open)
        open?.sendActions(for: .touchUpInside)
        let entryID = DictationFeedbackPresentation.snapshotFixture().offer.entryID
        XCTAssertEqual(opened, TyprFeedbackLink.url(entryID: entryID))
        XCTAssertNil(model.feedback)
        pumpMainRunLoop()
        XCTAssertNil(view.shownPanelContent)
    }

    func testFeedbackLinkRoundTripAndRouting() {
        let id = UUID()
        let url = TyprFeedbackLink.url(entryID: id)
        XCTAssertEqual(TyprFeedbackLink.entryID(from: url), id)
        XCTAssertNil(KeyboardLaunchRequest(url: url), "must never start a dictation session")
        XCTAssertNil(TyprFeedbackLink.entryID(from: KeyboardLaunchRequest.setup.url))
        XCTAssertNil(TyprFeedbackLink.entryID(from: URL(string: "typr://typr/feedback?entry=nope")!))
        let router = TyprFeedbackRouter()
        XCTAssertFalse(router.handle(KeyboardLaunchRequest.setup.url))
        XCTAssertNil(router.requestedEntry)
        XCTAssertTrue(router.handle(url))
        XCTAssertEqual(router.consume(), id)
        XCTAssertNil(router.requestedEntry)
    }

    func testFullKeyboardGoodClosesThePanelAtOnceAndLeavesHostText() {
        let target = FixtureTextTarget(text: "Original host text")
        let model = KeyboardViewModel()
        model.configureFixture(snapshot: .offline, now: 10_000)
        model.feedback = .snapshotFixture()
        var received: String?
        model.onFeedbackRating = { rating, _ in received = rating }
        let view = makeKeyboard(model: model, target: target)
        XCTAssertEqual(view.shownPanelContent, .ask)
        XCTAssertNil(visibleButton("Undo dictation", in: view), "Undo dictation is gone")
        visibleButton("Good", in: view)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(received, "good")
        XCTAssertNil(model.feedback)
        pumpMainRunLoop()
        XCTAssertNil(view.shownPanelContent)
        XCTAssertEqual(target.text, "Original host text")
        let key = view.engine.layout.key(.character("x"))!
        let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
        view.engine.touchBegan(id: 99, at: point); view.engine.touchEnded(id: 99, at: point)
        XCTAssertTrue(target.text.contains("x"))
    }

    func testFeedbackPanelCloseAndProblemTimeout() {
        let model = KeyboardViewModel()
        model.configureFixture(snapshot: .offline, now: 10_000)
        model.feedback = .snapshotFixture()
        var received: [String] = []
        model.onFeedbackRating = { rating, _ in received.append(rating) }
        let view = makeKeyboard(model: model)
        visibleButton(TyprFeedbackPanel.dismissFeedbackLabel, in: view)?.sendActions(for: .touchUpInside)
        XCTAssertNil(model.feedback)
        XCTAssertTrue(received.isEmpty, "✕ rates nothing")
        pumpMainRunLoop()
        XCTAssertNil(view.shownPanelContent)

        view.problemPanelDuration = 0.05
        model.feedback = .snapshotFixture(problem: true)
        // The panel's .problem content is covered by testFullKeyboardShowsFeedbackPanelThatArrivesAfterMount.
        // Pumping for a fixed interval before asserting it here races the 50 ms close timer.
        // Wait for both the timer's model update and the view's RunLoop-delivered update instead.
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                model.feedback == nil && view.shownPanelContent == nil
            }
        }, object: nil)
        wait(for: [closed], timeout: 5)
        XCTAssertNil(model.feedback, "Fix in Typr stays only for a moment")
        XCTAssertNil(view.shownPanelContent)
    }

    func testFeedbackThatFailedToQueueOffersRetry() {
        let model = KeyboardViewModel()
        model.configureFixture(snapshot: .offline, now: 10_000)
        var feedback = DictationFeedbackPresentation.snapshotFixture()
        feedback.message = "Not queued: full, expired or unavailable"
        feedback.retryRating = "good"
        model.feedback = feedback
        var received: [String] = []
        model.onFeedbackRating = { rating, _ in received.append(rating) }
        let view = makeKeyboard(model: model)
        XCTAssertEqual(view.shownPanelContent, .retry("Not queued: full, expired or unavailable"))
        visibleButton("Retry feedback", in: view)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(received, ["good"])
        XCTAssertNil(model.feedback)
    }

    func testHiddenBarShowsTyprMessagesInThePanel() {
        let model = KeyboardViewModel()
        let failed = KeyboardSnapshot(state: .failed, heartbeat: 9_999.9, expiresAt: 10_600, message: "Microphone unavailable")
        model.configureFixture(snapshot: failed, now: 10_000)
        let view = makeKeyboard(model: model)
        XCTAssertEqual(view.shownPanelContent, .notice("Microphone unavailable"))
        visibleButton(TyprFeedbackPanel.dismissMessageLabel, in: view)?.sendActions(for: .touchUpInside)
        XCTAssertNil(view.shownPanelContent, "a closed message stays closed")
        pumpMainRunLoop()
        XCTAssertNil(view.shownPanelContent)

        // With the bar on, the message stays in the bar as before.
        let barModel = KeyboardViewModel()
        barModel.configureFixture(snapshot: failed, now: 10_000)
        let withBar = makeKeyboard(model: barModel, showsBar: true)
        XCTAssertNil(withBar.shownPanelContent)
    }
    #endif

    func testTwoWritersCapAndMalformedExpiredEvents() async throws {
        let f = Fixture(); try await f.ready(); let offer = f.offer()
        let other = DictationFeedbackBridge(defaults: f.defaults, directory: f.root.appendingPathComponent("queue"))
        let events = (0..<101).map { _ in event(offer) }
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for (i, event) in events.enumerated() {
                let bridge = i.isMultiple(of: 2) ? f.bridge : other
                group.addTask { await withCheckedContinuation { c in bridge.enqueue(event) { c.resume(returning: $0) } } }
            }
            var count = 0; for await result in group { if result { count += 1 } }; return count
        }
        XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, 100)
        // A contending writer may honestly report Not queued; explicit retries fill the remaining slots.
        for event in events { _ = await f.enqueue(event) }
        let pending = await f.pending(); XCTAssertEqual(pending.count, 100)
        let badFile = f.root.appendingPathComponent("queue/\(UUID().uuidString).json")
        try Data(repeating: 32, count: DictationFeedbackBridge.maximumEventBytes + 1).write(to: badFile)
        _ = await f.pending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: badFile.path))
        let stale = event(offer, date: Date().addingTimeInterval(-31 * 24 * 60 * 60))
        let expired = await f.enqueue(stale); XCTAssertFalse(expired)
        await other.flush(); await f.dispose()
    }
}
