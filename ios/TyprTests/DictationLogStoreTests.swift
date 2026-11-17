import XCTest
@testable import Typr

/// Isolated defaults + app-container stand-in. Never opens the owner's production log.
@MainActor
final class LogTestEnvironment {
    let suite = "dictation-log.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let settings: TyprSettings
    let storage: DictationLogStorage
    let store: DictationLogStore

    init(enabled: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        settings = TyprSettings(defaults: defaults)
        settings.dictationLog = enabled
        storage = DictationLogStorage(url: directory.appendingPathComponent("dictation-log.json"))
        store = DictationLogStore(storage: storage, settings: settings)
    }

    func begin(context: DictationLogContext = DictationLogContext(),
               clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) -> DictationLogRecording {
        store.begin(token: store.token(), context: context, clock: clock)!
    }

    static func waitUntilLoaded(_ store: DictationLogStore, file: StaticString = #filePath,
                                line: UInt = #line) async throws {
        try await waitForState("archive loaded", file: file, line: line) {
            await store.storage.flush(); await mainActorBarrier()
            return !store.isLoading && store.metadata.prefix(50).allSatisfy { store.entry($0.id) != nil }
        }
    }

    var persistedEntryCount: Int {
        ((try? FileManager.default.contentsOfDirectory(at: storage.root.appendingPathComponent("entries"),
            includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.count
    }

    func dispose() async {
        await storage.flush()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class DictationLogStoreTests: XCTestCase {
    func testDefaultOnAndTextCapsAtCharacterBoundaries() {
        let suite = "dictation-log.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TyprSettings(defaults: defaults)
        XCTAssertTrue(settings.dictationLog)
        settings.dictationLog = false
        XCTAssertFalse(TyprSettings(defaults: defaults).dictationLog)
        for source in [String(repeating: "ä", count: 4_000), String(repeating: "👩🏽‍💻", count: 1_000),
                       String(repeating: "e\u{301}", count: 3_000), String(repeating: "x", count: 4_000)] {
            let field = DictationLogText(source)
            XCTAssertEqual(field.originalUTF8Bytes, source.utf8.count)
            XCTAssertLessThanOrEqual(field.text.utf8.count, 4_000)
            XCTAssertEqual(field.truncated, source.utf8.count > 4_000)
            if field.truncated {
                XCTAssertTrue(field.text.hasSuffix("…"))
                XCTAssertTrue(source.hasPrefix(String(field.text.dropLast())))
            } else { XCTAssertEqual(field.text, source) }
        }
        let wordField = DictationLogText(String(repeating: "hello ", count: 1_000))
        XCTAssertEqual(wordField.wordCount, 1_000) // Computed before the cap.
    }

    private func settle(_ store: DictationLogStore) async throws {
        try await LogTestEnvironment.waitUntilLoaded(store)
    }
    func testArchiveRetainsMoreThanTwentyAndStartupDoesNotOverwriteNewCapture() async throws {
        let env = LogTestEnvironment()
        let count = DictationLogStore.maximumEntries + 5
        for index in 0..<count { env.begin().finish(text: "synthetic \(index)", beforeSpelling: "synthetic \(index)") }
        try await settle(env.store)
        XCTAssertEqual(env.store.metadata.count, count)
        XCTAssertLessThanOrEqual(env.store.entries.count, DictationLogStore.maximumEntries)
        let disk = DictationLogStorage(url: env.storage.url)
        let loaded = DictationLogStore(storage: disk, settings: env.settings)
        let fresh = loaded.begin(token: loaded.token(), context: .init())!
        fresh.finish(text: "fresh", beforeSpelling: "fresh")
        try await settle(loaded)
        XCTAssertEqual(loaded.metadata.count, count + 1)
        XCTAssertEqual(loaded.entry(fresh.entryID)?.finalText?.text, "fresh")
        let values = try disk.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        await env.dispose()
    }
    func testOffFinalizesThenFencesButKeepsReadRateAndExport() async throws {
        let env = LogTestEnvironment(); let recording = env.begin(); let token = env.store.token()
        recording.recognized("synthetic", spelled: "synthetic", asrMilliseconds: 1)
        env.store.setEnabled(false)
        recording.finish(text: "stale", beforeSpelling: "stale")
        XCTAssertEqual(env.store.entry(recording.entryID)?.status, .interrupted)
        XCTAssertNil(env.store.entry(recording.entryID)?.finalText)
        XCTAssertNil(env.store.begin(token: token, context: .init()))
        env.store.rate(recording.entryID, rating: "good")
        env.store.saveFeedback(for: recording.entryID, expectedText: "reference", note: "note")
        try await settle(env.store)
        let loaded = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(loaded)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.metadata.count, 1)
        XCTAssertEqual(loaded.entries.first?.rating, "good")
        XCTAssertEqual(loaded.entries.first?.expectedText?.text, "reference")
        await env.dispose()
    }
    func testClearDuringLoadAndWritesDoesNotRemoveFreshCaptureOrReviveEditor() async throws {
        let env = LogTestEnvironment(); let old = env.begin()
        env.store.clear()
        env.store.saveFeedback(for: old.entryID, expectedText: "stale editor", note: "")
        let fresh = env.begin(); fresh.finish(text: "fresh", beforeSpelling: "fresh")
        old.finish(text: "stale capture", beforeSpelling: "stale capture")
        try await settle(env.store)
        XCTAssertEqual(env.store.metadata.map(\.id), [fresh.entryID])
        let loaded = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(loaded)
        XCTAssertEqual(loaded.metadata.map(\.id), [fresh.entryID])
        await env.dispose()
    }
    func testMigrationPreservesFeedbackAndDowngradeCannotReplaceNewerEntry() async throws {
        let env = LogTestEnvironment(enabled: false)
        await env.storage.flush()
        var entry = DictationLogEntry(context: .init())
        entry.expectedText = DictationLogText("reference"); entry.feedbackNote = DictationLogText("note")
        entry.revision = nil // Real schema-1 data predates this optional field.
        try JSONEncoder().encode(DictationLogDocument(entries: [entry])).write(to: env.storage.url)
        let migrated = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(migrated)
        XCTAssertEqual(migrated.entries.first?.expectedText?.text, "reference")
        XCTAssertEqual(migrated.entries.first?.status, .interrupted)
        XCTAssertNil(migrated.entries.first?.rating)
        XCTAssertEqual(migrated.entries.first?.revision, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.storage.url.path))
        migrated.rate(entry.id, rating: "bad", issues: ["future_issue"])
        await migrated.storage.flush()
        try JSONEncoder().encode(DictationLogDocument(entries: [entry])).write(to: env.storage.url)
        let again = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(again)
        XCTAssertEqual(again.entries.first?.rating, "bad")
        XCTAssertEqual(again.entries.first?.issues, ["future_issue"])
        await env.dispose()
    }
    func testDeleteDuringUnfinishedMigrationCannotReappearAfterReloadOrDowngrade() async throws {
        let env = LogTestEnvironment(); await env.storage.flush()
        var good = DictationLogEntry(context: .init()); good.status = .finished; good.revision = nil
        let unresolved = DictationLogEntry(context: .init())
        let broken = env.storage.root.appendingPathComponent("entries/\(unresolved.id.uuidString).json")
        try Data("unreadable newer copy".utf8).write(to: broken)
        let legacy = try JSONEncoder().encode(DictationLogDocument(entries: [good, unresolved]))
        try legacy.write(to: env.storage.url)
        let migrated = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(migrated)
        XCTAssertNotNil(migrated.entry(good.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.storage.url.path))
        migrated.delete(good.id); await migrated.storage.flush()
        await mainActorBarrier() // The delete completion hops to the main actor.
        let reloaded = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(reloaded)
        XCTAssertFalse(reloaded.metadata.contains { $0.id == good.id })
        XCTAssertNil(reloaded.entry(good.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.storage.root
            .appendingPathComponent("deleted/\(good.id.uuidString).deleted").path))
        // Even after a downgrade reintroduces exactly the original schema-1 document.
        try legacy.write(to: env.storage.url)
        let downgraded = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
        try await settle(downgraded)
        XCTAssertFalse(downgraded.metadata.contains { $0.id == good.id })
        await env.dispose()
    }

    func testCorruptAndUnknownLegacyIsPreservedAndDoesNotBlockNewCaptures() async throws {
        for data in [Data("not JSON".utf8), Data(repeating: 32, count: 1_000_001),
                     Data(#"{"schemaVersion":999,"entries":[]}"#.utf8)] {
            let env = LogTestEnvironment(); await env.storage.flush()
            try data.write(to: env.storage.url)
            let loaded = DictationLogStore(storage: DictationLogStorage(url: env.storage.url), settings: env.settings)
            try await settle(loaded)
            XCTAssertNotNil(loaded.storageProblem)
            XCTAssertEqual(try Data(contentsOf: env.storage.url), data)
            loaded.begin(token: loaded.token(), context: .init())?.finish(text: "fresh", beforeSpelling: "fresh")
            await loaded.storage.flush()
            XCTAssertEqual(loaded.metadata.count, 1)
            loaded.clear(); try await settle(loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: env.storage.url.path))
            await env.dispose()
        }
    }
    func testDeleteThenOffAndRetryCannotRewriteDirtyEntry() async throws {
        let env = LogTestEnvironment()
        let recording = env.begin() // Source completion has not reached the main actor yet: dirty.
        let id = recording.entryID
        env.store.delete(id)
        env.store.setEnabled(false)
        env.store.retry()
        recording.finish(text: "stale", beforeSpelling: "stale")
        await env.storage.flush()
        await mainActorBarrier() // Storage completions hop to the main actor.
        XCTAssertNil(env.store.entry(id))
        XCTAssertFalse(env.store.metadata.contains { $0.id == id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.storage.root
            .appendingPathComponent("entries/\(id.uuidString).json").path))
        await env.dispose()
    }

    func testFeedbackOrderAndEditorFieldOwnership() async throws {
        let env = LogTestEnvironment(); let recording = env.begin(); let id = recording.entryID
        let time = Date()
        let first = DictationFeedbackOrder(modifiedAt: time, origin: "keyboard", eventID: "a")
        let next = DictationFeedbackOrder(modifiedAt: time, origin: "keyboard", eventID: "b")
        env.store.rate(id, rating: "bad", issues: ["misheard"], order: next)
        let revision = env.store.entry(id)?.revision
        env.store.rate(id, rating: "good", order: first)
        env.store.rate(id, rating: "good", order: next)
        XCTAssertEqual(env.store.entry(id)?.revision, revision)
        env.store.saveFeedback(for: id, expectedText: "reference", note: "note")
        XCTAssertEqual(env.store.entry(id)?.rating, "bad")
        env.store.rate(id, rating: "unrated")
        XCTAssertEqual(env.store.entry(id)?.expectedText?.text, "reference")
        XCTAssertEqual(env.store.entry(id)?.issues, ["misheard"])
        await env.dispose()
    }
    func testWholeArchiveJSONAndIndexRebuild() async throws {
        let env = LogTestEnvironment()
        let count = DictationLogStore.maximumEntries + 5
        for index in 0..<count { env.begin().finish(text: "synthetic \(index)", beforeSpelling: "synthetic \(index)") }
        try await settle(env.store)
        try Data("stale index".utf8).write(to: env.storage.root.appendingPathComponent("index.json"))
        let disk = DictationLogStorage(url: env.storage.url)
        let loaded = DictationLogStore(storage: disk, settings: env.settings)
        try await settle(loaded)
        XCTAssertEqual(loaded.metadata.count, count)
        let result: Result<URL, any Error> = await withCheckedContinuation { continuation in
            disk.export(ids: nil, build: "synthetic-test") { continuation.resume(returning: $0) }
        }
        let file = try result.get()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "typr.dictation-log")
        XCTAssertEqual(object["exportVersion"] as? Int, 1)
        XCTAssertEqual((object["entries"] as? [Any])?.count, count)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.allSatisfy { $0["schemaVersion"] as? Int == 2 })
        loaded.clear(); try await settle(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await env.dispose()
    }

    func testPreparedJSONIsOnlyExposedForItsExactScope() async throws {
        let env = LogTestEnvironment()
        let first = env.begin(); first.finish(text: "first", beforeSpelling: "first")
        let second = env.begin(); second.finish(text: "second", beforeSpelling: "second")
        try await settle(env.store)
        env.store.prepareJSON(ids: [first.entryID])
        try await waitForState("scoped export prepared") { !env.store.exporting }
        XCTAssertNotNil(env.store.preparedJSON(for: [first.entryID]))
        XCTAssertNil(env.store.preparedJSON(for: nil))
        XCTAssertNil(env.store.preparedJSON(for: [second.entryID]))
        env.store.prepareJSON()
        try await waitForState("complete export prepared") { !env.store.exporting }
        XCTAssertNotNil(env.store.preparedJSON(for: nil))
        XCTAssertNil(env.store.preparedJSON(for: [first.entryID]))
        await env.dispose()
    }

    func testBlockedStreamDoesNotBlockWritesAndClearCancelsWithoutResurrection() async throws {
        let env = LogTestEnvironment()
        env.begin().finish(text: "before snapshot", beforeSpelling: "before snapshot")
        await env.storage.flush()
        let started = expectation(description: "stream started")
        let gate = DispatchSemaphore(value: 0)
        let disk = DictationLogStorage(url: env.storage.url, beforeExportStream: {
            started.fulfill(); gate.wait()
        })
        let loaded = DictationLogStore(storage: disk, settings: env.settings)
        try await settle(loaded)
        let completed = expectation(description: "cancelled export completed")
        disk.export(ids: nil, build: "synthetic") { result in
            if case .success = result { XCTFail("Clear must cancel the export") }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
        let fresh = loaded.begin(token: loaded.token(), context: .init())!
        fresh.finish(text: "during blocked export", beforeSpelling: "during blocked export")
        await disk.flush() // Would deadlock if streaming occupied the source queue.
        XCTAssertEqual(loaded.metadata.count, 2)
        loaded.clear(); await disk.flush()
        gate.signal()
        await fulfillment(of: [completed], timeout: 5)
        try await settle(loaded)
        XCTAssertTrue(loaded.metadata.isEmpty)
        let exports = disk.root.appendingPathComponent("exports")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
        await env.dispose()
    }

    func testRetryWithoutClearResolvesSaveFailureBanner() async throws {
        let env = LogTestEnvironment()
        await env.storage.flush()
        try FileManager.default.removeItem(at: env.directory)
        try Data("parent is a file".utf8).write(to: env.directory)
        let recording = env.begin()
        recording.finish(text: "retained for retry", beforeSpelling: "retained for retry")
        await env.storage.flush(); await mainActorBarrier() // The failed save reports on the main actor.
        XCTAssertNotNil(env.store.storageProblem)
        try FileManager.default.removeItem(at: env.directory)
        env.store.retry()
        try await settle(env.store)
        XCTAssertNil(env.store.storageProblem)
        XCTAssertEqual(env.store.entry(recording.entryID)?.finalText?.text, "retained for retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.storage.root
            .appendingPathComponent("entries/\(recording.entryID.uuidString).json").path))
        await env.dispose()
    }

    func testStorageProblemCanBeRecoveredWithoutAnOldCompletionReplacingIt() async throws {
        let env = LogTestEnvironment()
        // The store's initial load creates this directory on the storage queue.
        await env.storage.flush()
        try FileManager.default.removeItem(at: env.directory)
        try Data("parent is a file".utf8).write(to: env.directory)
        env.begin().finish(text: "still delivered", beforeSpelling: "still delivered")
        await env.storage.flush()
        await mainActorBarrier() // Drain the main-actor completion, not disk.
        XCTAssertNotNil(env.store.storageProblem)
        try FileManager.default.removeItem(at: env.directory)
        env.store.clear()
        await env.storage.flush()
        await mainActorBarrier() // The clear completion reports on the main actor.
        XCTAssertNil(env.store.storageProblem)
        XCTAssertTrue(env.store.entries.isEmpty)
        await env.dispose()
    }

    func testTerminalRulesLateLabelsAndExactlyOneStatus() async throws {
        let env = LogTestEnvironment()
        for failure in [CleanupFailureReason.deadline, .expired] {
            let recording = env.begin()
            recording.recognized("plain words here", spelled: "plain words here", asrMilliseconds: 1)
            recording.cleanupResolved(.init(outcome: .failed(failure), latencyMilliseconds: 4_000), changed: nil)
            recording.finish(text: "Plain words here.", beforeSpelling: "Plain words here.")
            let finished = try XCTUnwrap(env.store.entries.first)
            recording.finishIfOpen(.cancelled)
            recording.modelAnswer("late answer", use: .late, modelMilliseconds: 6_000)
            let late = try XCTUnwrap(env.store.entries.first)
            XCTAssertEqual(late.status, .finished)
            XCTAssertEqual(late.finalText, finished.finalText)
            XCTAssertEqual(late.cleanupOutcome, finished.cleanupOutcome)
            XCTAssertEqual(late.stopToFinalMilliseconds, finished.stopToFinalMilliseconds)
            XCTAssertEqual(late.modelMilliseconds, 6_000)
            XCTAssertEqual(late.aiAnswer?.text, "late answer")
            XCTAssertEqual(late.answerLabel, failure == .deadline
                ? "arrived after the cleanup deadline; not used"
                : "arrived after iOS ended the background time; not used")
            recording.modelAnswer("not late", use: .accepted, modelMilliseconds: 7_000)
            XCTAssertEqual(env.store.entries.first, late)
        }
        let failed = env.begin()
        failed.failASR(ParakeetTranscriber.TranscriberError.emptyTranscript, milliseconds: 3)
        failed.modelAnswer("late", use: .late, modelMilliseconds: 7)
        XCTAssertEqual(env.store.entries.first?.status, .asrFailed)
        XCTAssertEqual(env.store.entries.first?.asrFailure, .noSpeech)
        XCTAssertEqual(env.store.entries.first?.aiAnswer?.text, "late")
        XCTAssertNil(env.store.entries.first?.finalText)
        XCTAssertEqual(env.store.entries.first?.answerLabel, "arrived after cleanup had resolved; not used")
        for status in [DictationLogStatus.cancelled, .interrupted] {
            let recording = env.begin()
            recording.finishIfOpen(status)
            let terminal = env.store.entries.first
            recording.recognized("ignored", spelled: "ignored", asrMilliseconds: 1)
            recording.modelAnswer("ignored", use: .late, modelMilliseconds: 1)
            recording.cleanupResolved(.init(outcome: .completed, latencyMilliseconds: 1), changed: true)
            recording.finish(text: "ignored", beforeSpelling: "ignored")
            XCTAssertEqual(env.store.entries.first, terminal)
        }
        await env.dispose()
    }
}
