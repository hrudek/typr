import Foundation
import Darwin
import XCTest
@testable import Typr

@MainActor
final class KeyboardLearningStoreTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            suite = "KeyboardLearningStoreTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func store() -> KeyboardLearningStore { KeyboardLearningStore(directory: directory, defaults: defaults) }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testIndividualDeletionsWinOverDirtyKeyboardAndPreserveOtherDomains() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let session = KeyboardLearningSession(store: fixture.store(), defaults: fixture.defaults)
        session.keep("hello")
        session.keep("world")
        session.recordWord("hello")
        session.rejectCorrection(typed: "teh", replacement: "the")
        session.flush()
        let staleWriter = fixture.store()
        let stale = try XCTUnwrap(staleWriter.load().0)
        session.keep("unsaved")
        let initialDiagnostics = session.diagnostics

        XCTAssertTrue(fixture.store().deleteLearnedEntry(.kept("hello")))
        var counters = initialDiagnostics
        XCTAssertFalse(staleWriter.save(model: stale, diagnostics: &counters))
        XCTAssertTrue(staleWriter.resetObserved)
        session.flush()
        XCTAssertFalse(session.protections.isKept("hello"))
        XCTAssertTrue(session.protections.isKept("world"))
        XCTAssertEqual(session.protections.counts["hello"], 1)
        XCTAssertFalse(session.protections.isKept("unsaved"), "Explicit edit installs disk state, not dirty RAM")

        XCTAssertTrue(fixture.store().deleteLearnedEntry(.count("hello")))
        session.flush()
        XCTAssertNil(session.protections.counts["hello"])
        let pair = RejectedCorrection(typed: "teh", replacement: "the")
        XCTAssertTrue(fixture.store().deleteLearnedEntry(.rejected(pair)))
        session.flush()
        let final = try XCTUnwrap(fixture.store().load().0)
        XCTAssertNil(final.kept["hello"])
        XCTAssertTrue(final.counts.isEmpty)
        XCTAssertTrue(final.rejected.isEmpty)
        XCTAssertNotNil(final.kept["world"])
        XCTAssertEqual(session.diagnostics, initialDiagnostics, "Learning edits leave statistics alone")
    }

    func testRejectionCapHonorsWholeFileByteCeiling() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = PersonalTypingModel()
        let stem = String(repeating: "𐐨", count: 30)
        let contextWord = String(repeating: "𐐨", count: 32)
        for index in 0..<512 {
            let a = String(UnicodeScalar(97 + index / 26)!)
            let b = String(UnicodeScalar(97 + index % 26)!)
            model.rejectCorrection(typed: stem + a + b, replacement: contextWord,
                                   context: contextWord + " " + contextWord)
        }
        XCTAssertEqual(model.state.rejected.count, 512)
        let rawBytes = try JSONEncoder().encode(model.state).count
        var counters = KeyboardDiagnostics()
        XCTAssertTrue(fixture.store().save(model: model.state, diagnostics: &counters))
        let bytes = try Data(contentsOf: fixture.file("learning-v1.json")).count
        let saved = try XCTUnwrap(fixture.store().load().0)
        XCTAssertLessThanOrEqual(bytes, KeyboardLearningStore.maximumLearningBytes)
        XCTAssertLessThan(saved.rejected.count, 512, "Byte limit may evict FIFO protections")
        XCTAssertFalse(saved.rejected.isEmpty)
        XCTAssertEqual(saved.rejected.first?.remaining, 256)
        print("EVAL R2_3_file_cap input_pairs=512 raw_state_bytes=\(rawBytes) saved_pairs=\(saved.rejected.count) saved_file_bytes=\(bytes) cap=262144")
    }

    func testContextRejectionDeletionReloadAndReset() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let session = KeyboardLearningSession(store: fixture.store(), defaults: fixture.defaults)
        session.keep("send")
        session.rejectCorrection(typed: "teh", replacement: "the", context: "send to")
        for _ in 0..<64 { session.recordWord("hello") }
        session.flush()
        let loaded = try XCTUnwrap(fixture.store().load().0)
        XCTAssertEqual(loaded.rejected.first?.remaining, 192)
        XCTAssertEqual(loaded.rejected.first?.globalRemaining, 0)
        XCTAssertEqual(loaded.rejected.first?.context, "send to")
        XCTAssertTrue(fixture.store().deleteLearnedEntry(.kept("send")))
        XCTAssertTrue(try XCTUnwrap(fixture.store().load().0).rejected.isEmpty)
        session.refresh()
        session.rejectCorrection(typed: "teh", replacement: "the", context: "reply to")
        session.flush()
        XCTAssertTrue(fixture.store().deleteLearnedEntry(.rejected(.init(typed: "teh", replacement: "the"))))
        XCTAssertTrue(try XCTUnwrap(fixture.store().load().0).rejected.isEmpty)
        XCTAssertTrue(fixture.store().requestLearningReset())
        session.refresh()
        XCTAssertTrue(session.model.state.rejected.isEmpty)
        print("EVAL R2_3_store reloaded_remaining=192 reloaded_global=0 predecessor_deletion_remaining=0 pair_deletion_remaining=0 reset_remaining=0")
    }

    func testDeleteWithoutPersistentStorageDoesNotPretendToSucceed() {
        XCTAssertFalse(KeyboardLearningStore(directory: nil, defaults: nil).deleteLearnedEntry(.kept("hello")))
    }

    func testRoundTripSummaryAndFileMetadata() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = PersonalTypingModel()
        model.keep("hello"); model.recordWord("hello")
        model.rejectCorrection(typed: "hello", replacement: "help")
        let layout = KeyboardLayout(width: 393)
        let key = try XCTUnwrap(layout.key(.character("a")))
        model.learn([.init(point: CGPoint(x: key.frame.midX, y: key.frame.midY), letter: "a")], layout: layout, source: .keep)
        var diagnostics = KeyboardDiagnostics()
        diagnostics.increment(.boundaries)
        let store = fixture.store()
        XCTAssertTrue(store.save(model: model.state, diagnostics: &diagnostics))
        let (loaded, counters) = fixture.store().load()
        XCTAssertEqual(loaded, model.state)
        XCTAssertEqual(counters, diagnostics)
        let snapshot = KeyboardLearningStore.readSnapshot(directory: fixture.directory, defaults: fixture.defaults)
        XCTAssertTrue(snapshot.isPersistent)
        XCTAssertEqual(snapshot.model, model.summary)
        XCTAssertEqual(snapshot.diagnostics, diagnostics)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.learningFile.bytes), 0)
        XCTAssertNotNil(snapshot.learningFile.modifiedAt)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.diagnosticsFile.bytes), 0)
        XCTAssertNotNil(snapshot.diagnosticsFile.modifiedAt)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let values = try fixture.file("learning-v1.json").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testSchemaOneMigratesInPlaceWithoutLosingProtections() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = PersonalTypingModel()
        model.keep("hallo"); model.recordWord("hello")
        model.rejectCorrection(typed: "hallo", replacement: "hello")
        let grid = KeyboardLayout(width: 393)
        let key = try XCTUnwrap(grid.key(.character("a")))
        model.learn(Array(repeating: .init(point: CGPoint(x: key.frame.midX, y: key.frame.midY), letter: "a"), count: 20),
                    layout: grid, source: .keep)
        var counters = KeyboardDiagnostics()
        let store = fixture.store()
        XCTAssertTrue(store.save(model: model.state, diagnostics: &counters))
        let file = fixture.file("learning-v1.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var value = try XCTUnwrap(object["value"] as? [String: Any])
        value["schemaVersion"] = 1
        var layouts = try XCTUnwrap(value["layouts"] as? [String: [String: Any]])
        for id in layouts.keys {
            layouts[id]!.removeValue(forKey: "global")
            var keys = layouts[id]!["keys"] as! [String: [String: Any]]
            for letter in keys.keys { keys[letter]!.removeValue(forKey: "covarianceXY") }
            layouts[id]!["keys"] = keys
        }
        value["layouts"] = layouts; object["value"] = value
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let (loaded, diagnostics) = store.load()
        let migrated = try XCTUnwrap(loaded)
        XCTAssertEqual(migrated.schemaVersion, 5)
        XCTAssertEqual(migrated.kept, model.state.kept)
        XCTAssertEqual(migrated.counts, model.state.counts)
        XCTAssertEqual(migrated.rejected, model.state.rejected)
        XCTAssertEqual(diagnostics[.storeCorruptDiscarded], 0)
        XCTAssertNil(migrated.layouts.values.first?.global)
        XCTAssertEqual(migrated.layouts.values.first?.keys["a"]?.covarianceXY, 0)
        XCTAssertTrue(store.save(model: migrated, diagnostics: &counters))
        XCTAssertEqual(store.load().0, migrated)
        XCTAssertLessThan(try Data(contentsOf: file).count, KeyboardLearningStore.maximumLearningBytes)
    }

    func testOversizedFilesAreDiscardedBeforeDecode() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try Data(repeating: 32, count: KeyboardLearningStore.maximumLearningBytes + 1).write(to: fixture.file("learning-v1.json"))
        try Data(repeating: 32, count: KeyboardLearningStore.maximumDiagnosticsBytes + 1).write(to: fixture.file("diagnostics-v1.json"))
        let (model, diagnostics) = fixture.store().load()
        XCTAssertNil(model)
        XCTAssertEqual(diagnostics[.storeCorruptDiscarded], 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(),
                       ["diagnostics-v1.json", "learning-v1.json", "learning.lock"])
    }

    func testCorruptJSONAndInvalidStateDiscardWithoutQuarantine() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try Data("not json".utf8).write(to: fixture.file("learning-v1.json"))
        try Data("{}".utf8).write(to: fixture.file("diagnostics-v1.json"))
        let store = fixture.store()
        var (state, diagnostics) = store.load()
        XCTAssertNil(state)
        XCTAssertEqual(diagnostics[.storeCorruptDiscarded], 2)
        XCTAssertTrue(store.save(model: .init(), diagnostics: &diagnostics))
        let data = try Data(contentsOf: fixture.file("learning-v1.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var value = try XCTUnwrap(object["value"] as? [String: Any]); value["schemaVersion"] = 99
        object["value"] = value
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.file("learning-v1.json"))
        (state, diagnostics) = store.load()
        XCTAssertNil(state)
        XCTAssertEqual(diagnostics[.storeCorruptDiscarded], 3)
    }

    func testLearningResetRefusesStaleSaveAndIgnoresRestoredOldFile() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writer = fixture.store()
        let model = PersonalTypingModel(); model.keep("hello")
        var diagnostics = KeyboardDiagnostics(); diagnostics.increment(.boundaries)
        XCTAssertTrue(writer.save(model: model.state, diagnostics: &diagnostics))
        let old = try Data(contentsOf: fixture.file("learning-v1.json"))
        let before = writer.currentEpochs
        XCTAssertTrue(fixture.store().requestLearningReset())
        XCTAssertEqual(writer.currentEpochs.learning, before.learning + 1)
        XCTAssertEqual(writer.currentEpochs.diagnostics, before.diagnostics)
        XCTAssertFalse(writer.save(model: model.state, diagnostics: &diagnostics))
        XCTAssertTrue(writer.resetObserved)
        XCTAssertEqual(diagnostics[.storeWriteFailed], 0)
        try old.write(to: fixture.file("learning-v1.json"))
        let (loaded, retained) = writer.load()
        XCTAssertNil(loaded)
        XCTAssertEqual(retained[.boundaries], 1)
        XCTAssertEqual(retained[.storeCorruptDiscarded], 0)
        XCTAssertFalse(writer.resetObserved)
        model.reset()
        XCTAssertTrue(writer.save(model: model.state, diagnostics: &diagnostics))
        XCTAssertEqual(fixture.store().load().0?.kept.count, 0)
    }

    func testDiagnosticsResetKeepsLearningAndRejectsStaleDiagnostics() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writer = fixture.store()
        let model = PersonalTypingModel(); model.keep("hello")
        var diagnostics = KeyboardDiagnostics(); diagnostics.increment(.boundaries)
        XCTAssertTrue(writer.save(model: model.state, diagnostics: &diagnostics))
        let old = try Data(contentsOf: fixture.file("diagnostics-v1.json"))
        XCTAssertTrue(fixture.store().requestDiagnosticsReset())
        XCTAssertFalse(writer.save(model: model.state, diagnostics: &diagnostics))
        XCTAssertTrue(writer.resetObserved)
        try old.write(to: fixture.file("diagnostics-v1.json"))
        let (loaded, reset) = writer.load()
        XCTAssertEqual(loaded, model.state)
        XCTAssertEqual(reset[.boundaries], 0)
        XCTAssertEqual(reset[.storeCorruptDiscarded], 0)
    }

    func testRAMOnlyModeAndResetEpochs() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = KeyboardLearningStore(directory: nil, defaults: fixture.defaults)
        XCTAssertFalse(store.isPersistent)
        let model = PersonalTypingModel(); model.keep("hello")
        var diagnostics = KeyboardDiagnostics(); diagnostics.increment(.boundaries)
        XCTAssertTrue(store.save(model: model.state, diagnostics: &diagnostics))
        XCTAssertEqual(store.load().0, model.state)
        XCTAssertEqual(store.load().1, diagnostics)
        let resetter = KeyboardLearningStore(directory: nil, defaults: fixture.defaults)
        XCTAssertTrue(resetter.requestLearningReset())
        XCTAssertFalse(store.save(model: model.state, diagnostics: &diagnostics))
        XCTAssertTrue(store.resetObserved)
        XCTAssertNil(store.load().0)
        XCTAssertEqual(store.load().1[.boundaries], 1)
        XCTAssertTrue(resetter.requestDiagnosticsReset())
        XCTAssertEqual(store.load().1[.boundaries], 0)
        let snapshot = KeyboardLearningStore.readSnapshot(directory: nil, defaults: fixture.defaults)
        XCTAssertFalse(snapshot.isPersistent)
        XCTAssertNil(snapshot.learningFile.bytes)
        XCTAssertNil(snapshot.diagnosticsFile.modifiedAt)
    }

    func testWriteByteCeilingDropsOldLexiconEntries() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var state = PersonalTypingModel.State()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let date = Date(timeIntervalSince1970: 1)
        for index in 0..<2000 {
            let suffix = String(alphabet[index / 676]) + String(alphabet[(index / 26) % 26]) + String(alphabet[index % 26])
            let word = String(repeating: "界", count: 29) + suffix
            state.kept[word] = date
            state.counts[word] = .init(count: 1, lastUpdated: date)
        }
        XCTAssertNotNil(state.validated())
        var diagnostics = KeyboardDiagnostics()
        XCTAssertTrue(fixture.store().save(model: state, diagnostics: &diagnostics))
        let data = try Data(contentsOf: fixture.file("learning-v1.json"))
        XCTAssertLessThanOrEqual(data.count, KeyboardLearningStore.maximumLearningBytes)
        let loaded = try XCTUnwrap(fixture.store().load().0)
        XCTAssertNotNil(loaded.validated())
        XCTAssertLessThan(loaded.kept.count + loaded.counts.count, state.kept.count + state.counts.count)
    }

    func testWriteFailureAndInvalidStateAreReported() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let file = fixture.file("not-a-directory")
        try Data().write(to: file)
        let store = KeyboardLearningStore(directory: file, defaults: fixture.defaults)
        var diagnostics = KeyboardDiagnostics()
        XCTAssertFalse(store.save(model: .init(), diagnostics: &diagnostics))
        XCTAssertFalse(store.isPersistent)
        XCTAssertFalse(store.resetObserved)
        XCTAssertEqual(diagnostics[.storeWriteFailed], 1)
        var invalid = PersonalTypingModel.State(); invalid.schemaVersion = 99
        XCTAssertFalse(fixture.store().save(model: invalid, diagnostics: &diagnostics))
        XCTAssertEqual(diagnostics[.storeWriteFailed], 2)
    }

    func testAimMemoriesSurviveReloadRepairNonFiniteWeightsAndReset() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let layout = KeyboardLayout(width: 375)
        let id = KeyboardLayoutSignature(layout).id
        let e = try XCTUnwrap(layout.key(.character("e"))).frame
        let session = KeyboardLearningSession(store: fixture.store(), defaults: fixture.defaults)
        for dx in [0.0, 0.3, 0.3, 0.3] {
            session.learn([.init(point: CGPoint(x: e.midX + dx * e.width, y: e.midY), letter: "e")], layout: layout, source: .keep)
        }
        session.flush()
        let saved = try XCTUnwrap(fixture.store().load().0)
        XCTAssertEqual(saved, session.model.state)
        XCTAssertNotNil(saved.layouts[id]?.aims?["e"])
        XCTAssertEqual(PersonalTypingModel(state: saved).calibration(for: layout), session.calibration(for: layout))

        var broken = saved
        broken.layouts[id]?.aims?["e"]?.weights = [.infinity, 0, 0]
        let store = fixture.store()
        _ = store.load()
        var diagnostics = KeyboardDiagnostics()
        XCTAssertTrue(store.save(model: broken, diagnostics: &diagnostics))
        XCTAssertEqual(diagnostics[.storeWriteFailed], 1)
        let repaired = try XCTUnwrap(fixture.store().load().0)
        XCTAssertNil(repaired.layouts[id]?.aims?["e"])
        XCTAssertEqual(repaired.layouts[id]?.keys, saved.layouts[id]?.keys, "statistics survive the repair")

        XCTAssertTrue(fixture.store().requestLearningReset())
        session.refresh()
        XCTAssertNil(fixture.store().load().0)
        XCTAssertNil(session.calibration(for: layout))
        XCTAssertTrue(session.model.state.layouts.isEmpty)
    }

    func testInvalidKeyStatsAreDroppedWithoutLosingProtectionOrBlockingLaterSaves() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let layout = KeyboardLayout(width: 375)
        let signature = KeyboardLayoutSignature(layout)
        let model = PersonalTypingModel()
        model.keep("hello"); model.recordWord("world")
        model.rejectCorrection(typed: "teh", replacement: "the")
        var state = model.state
        state.layouts[signature.id] = .init(signature: signature, lastUpdated: Date(),
            keys: ["g": .init(n: 1, meanX: 1.0000000000000004), "h": .init(n: 2, varianceX: .nan),
                   "a": .init(n: 1)])
        XCTAssertNil(state.validated())
        let store = fixture.store()
        var diagnostics = KeyboardDiagnostics()
        XCTAssertTrue(store.save(model: state, diagnostics: &diagnostics))
        XCTAssertTrue(store.isPersistent)
        XCTAssertEqual(diagnostics[.storeWriteFailed], 1)
        XCTAssertTrue(state.discardInvalidTouchStats()) // Same repair the session applies to RAM.
        XCTAssertFalse(state.discardInvalidTouchStats())
        XCTAssertNotNil(state.validated())
        XCTAssertEqual(Set(state.layouts[signature.id]?.keys.map(\.key) ?? []), ["a"])
        XCTAssertTrue(store.save(model: state, diagnostics: &diagnostics))
        XCTAssertEqual(diagnostics[.storeWriteFailed], 1)
        XCTAssertEqual(fixture.store().load().0, state)
    }

    func testSessionRetriesContendedInitialLoadAndCountsItOnlyOnce() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = PersonalTypingModel()
        model.keep("hello")
        model.rejectCorrection(typed: "dont", replacement: "don't")
        var diagnostics = KeyboardDiagnostics()
        diagnostics.increment(.boundaries, by: 7)
        XCTAssertTrue(fixture.store().save(model: model.state, diagnostics: &diagnostics))
        let fd = open(fixture.file("learning.lock").path, O_RDWR)
        guard fd >= 0 else { return XCTFail("Could not open synthetic store lock") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        var allowed = true
        let session = KeyboardLearningSession(store: fixture.store(), defaults: fixture.defaults,
                                              allowsPersistence: { allowed })
        XCTAssertFalse(session.isPersistent)
        XCTAssertFalse(session.protections.isKept("hello"))
        for _ in 0..<3 { session.refresh() }
        XCTAssertEqual(session.diagnostics[.storeLoadDeferred], 1)
        XCTAssertFalse(session.isPersistent)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        allowed = false
        session.refresh()
        XCTAssertFalse(session.isPersistent, "Do not read the shared store without Full Access")
        allowed = true
        session.refresh()
        XCTAssertTrue(session.isPersistent)
        XCTAssertTrue(session.protections.isKept("hello"))
        XCTAssertTrue(session.protections.isRejected(typed: "dont", replacement: "don't"))
        XCTAssertEqual(session.diagnostics[.boundaries], 7)
        XCTAssertEqual(session.diagnostics[.storeLoadDeferred], 1)
        for _ in 0..<3 { session.refresh(); session.flush() }
        XCTAssertEqual(fixture.store().load().1[.storeLoadDeferred], 1)
        XCTAssertEqual(fixture.store().load().0, model.state)
    }

    func testInitialLoadWaitsForPermissionThenRestoresSavedProtection() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = PersonalTypingModel(); model.keep("hello")
        var diagnostics = KeyboardDiagnostics()
        XCTAssertTrue(fixture.store().save(model: model.state, diagnostics: &diagnostics))
        var allowed = false
        let session = KeyboardLearningSession(store: fixture.store(), defaults: fixture.defaults,
                                              allowsPersistence: { allowed })
        session.refresh()
        XCTAssertFalse(session.isPersistent)
        XCTAssertEqual(session.diagnostics[.storeLoadDeferred], 0, "No attempted load failed")
        allowed = true
        session.refresh()
        XCTAssertTrue(session.isPersistent)
        XCTAssertTrue(session.protections.isKept("hello"))
        XCTAssertEqual(session.diagnostics[.storeLoadDeferred], 0)
    }

    func testLearningSettingDefaultsOnAndSharesKey() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let settings = TyprSettings(defaults: fixture.defaults)
        XCTAssertTrue(settings.personalLearning)
        settings.personalLearning = false
        XCTAssertEqual(fixture.defaults.object(forKey: "keyboard.personalLearning") as? Bool, false)
        XCTAssertFalse(TyprSettings(defaults: fixture.defaults).personalLearning)
    }
}
