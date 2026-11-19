import Foundation
import CoreFoundation
import Darwin

nonisolated struct KeyboardLearningSnapshot: Sendable {
    let model: PersonalTypingModel.Summary
    let diagnostics: KeyboardDiagnostics
    let learningFile: FileInfo
    let diagnosticsFile: FileInfo
    let isPersistent: Bool
    var modelAvailable = true

    nonisolated struct FileInfo: Sendable {
        let bytes: Int?
        let modifiedAt: Date?
    }
}

/// One keyboard writer, app read/reset access. Pass directory: nil without Full Access.
@MainActor
final class KeyboardLearningStore {
    static let learningResetKey = "keyboard.learning.resetEpoch"
    static let diagnosticsResetKey = "keyboard.diagnostics.resetEpoch"
    nonisolated static let changedNotification = "dev.rudek.typr.keyboard.learning-changed"
    static let maximumLearningBytes = 256 * 1024
    static let maximumDiagnosticsBytes = 64 * 1024
    private static let learningName = "learning-v1.json"
    private static let diagnosticsName = "diagnostics-v1.json"

    nonisolated struct Epochs: Equatable, Sendable {
        let learning: Int
        let diagnostics: Int
    }

    nonisolated private struct Saved<Value: Codable>: Codable {
        let epoch: Int
        let value: Value
    }
    nonisolated private struct Header: Decodable { let epoch: Int }

    private let directory: URL?
    private let defaults: UserDefaults?
    private var loadedEpochs: Epochs
    private var ramModel: PersonalTypingModel.State?
    private var ramDiagnostics = KeyboardDiagnostics()
    private var learningReadFailed = false
    private(set) var isPersistent: Bool
    /// A false save with this flag means reload/clear RAM, not a storage error.
    private(set) var resetObserved = false

    static var sharedDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)?
            .appendingPathComponent("Typr/Keyboard", isDirectory: true)
    }

    init(directory: URL? = KeyboardLearningStore.sharedDirectory,
         defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.directory = directory
        self.defaults = defaults
        isPersistent = directory != nil
        loadedEpochs = Self.epochs(defaults)
    }

    var currentEpochs: Epochs { Self.epochs(defaults) }

    private static func epochs(_ defaults: UserDefaults?) -> Epochs {
        // Force a cross-process refresh before comparing a reset made by the containing app.
        defaults?.synchronize()
        return Epochs(learning: max(0, defaults?.integer(forKey: learningResetKey) ?? 0),
                      diagnostics: max(0, defaults?.integer(forKey: diagnosticsResetKey) ?? 0))
    }

    func load() -> (PersonalTypingModel.State?, KeyboardDiagnostics) {
        resetObserved = false
        learningReadFailed = false
        guard directory != nil else {
            let epochs = currentEpochs
            if epochs.learning != loadedEpochs.learning { ramModel = nil }
            if epochs.diagnostics != loadedEpochs.diagnostics { ramDiagnostics = KeyboardDiagnostics() }
            loadedEpochs = epochs
            return (ramModel, ramDiagnostics)
        }
        do {
            let result = try withLock { root -> (PersonalTypingModel.State?, KeyboardDiagnostics) in
                loadedEpochs = currentEpochs
                var corrupt = 0
                let model: PersonalTypingModel.State? = read(root.appendingPathComponent(Self.learningName),
                    limit: Self.maximumLearningBytes, epoch: loadedEpochs.learning, corrupt: &corrupt)
                let validModel = model?.validated()
                if model != nil && validModel == nil { corrupt += 1 }
                learningReadFailed = corrupt > 0
                var diagnostics: KeyboardDiagnostics = read(root.appendingPathComponent(Self.diagnosticsName),
                    limit: Self.maximumDiagnosticsBytes, epoch: loadedEpochs.diagnostics, corrupt: &corrupt) ?? KeyboardDiagnostics()
                diagnostics.increment(.storeCorruptDiscarded, by: corrupt)
                return (validModel, diagnostics)
            }
            isPersistent = true
            return result
        } catch {
            isPersistent = false
            return (nil, KeyboardDiagnostics())
        }
    }

    /// The caller owns debouncing (at least ten seconds) and saving on disappearance.
    /// Diagnostics is inout so write failures are observable even when disk access fails.
    @discardableResult
    func save(model: PersonalTypingModel.State, diagnostics: inout KeyboardDiagnostics) -> Bool {
        resetObserved = false
        guard currentEpochs == loadedEpochs else { resetObserved = true; return false }
        var model = model
        let repaired = model.validated() == nil && model.discardInvalidTouchStats()
        if repaired { diagnostics.increment(.storeWriteFailed) }
        guard let validated = model.validated() else {
            if !repaired { diagnostics.increment(.storeWriteFailed) }
            isPersistent = false // An unrecoverable state must not fail on every session flush.
            return false
        }
        model = validated
        guard directory != nil else {
            ramModel = model
            ramDiagnostics = diagnostics
            return true
        }
        do {
            let saved = try withLock { root -> Bool in
                guard currentEpochs == loadedEpochs else { resetObserved = true; return false }
                var bounded = model
                var modelData = try JSONEncoder().encode(Saved(epoch: loadedEpochs.learning, value: bounded))
                while modelData.count > Self.maximumLearningBytes {
                    // Batches avoid quadratic re-encoding at the largest allowed word collections.
                    let batch = max(1, (bounded.kept.count + bounded.counts.count + bounded.rejected.count
                                        + (bounded.bigrams?.pairCount ?? 0)) / 16)
                    guard bounded.dropOldestLexiconEntries(batch) else { throw CocoaError(.fileWriteOutOfSpace) }
                    modelData = try JSONEncoder().encode(Saved(epoch: loadedEpochs.learning, value: bounded))
                }
                let diagnosticData = try JSONEncoder().encode(Saved(epoch: loadedEpochs.diagnostics, value: diagnostics))
                guard diagnosticData.count <= Self.maximumDiagnosticsBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                // Resets use the same lock. No reset can interleave these two atomic writes.
                try write(modelData, to: root.appendingPathComponent(Self.learningName))
                try write(diagnosticData, to: root.appendingPathComponent(Self.diagnosticsName))
                return true
            }
            if saved { isPersistent = true; Self.postChanged() }
            return saved
        } catch {
            diagnostics.increment(.storeWriteFailed)
            isPersistent = false
            return false
        }
    }

    static func readSnapshot(directory: URL? = KeyboardLearningStore.sharedDirectory,
                             defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup),
                             physicalTouch: Bool = false) -> KeyboardLearningSnapshot {
        let store = KeyboardLearningStore(directory: directory, defaults: defaults)
        let (model, diagnostics) = store.load()
        return KeyboardLearningSnapshot(model: PersonalTypingModel.summarize(model ?? .init(), physicalTouch: physicalTouch), diagnostics: diagnostics,
            learningFile: store.fileInfo(Self.learningName), diagnosticsFile: store.fileInfo(Self.diagnosticsName),
            isPersistent: store.isPersistent, modelAvailable: !store.learningReadFailed)
    }

    /// Explicit app-only inspection; never included in dashboard summaries or exports.
    func learnedWords() -> PersonalTypingModel.State? { load().0 }

    enum LearnedEntry {
        case kept(String), count(String), rejected(RejectedCorrection), pairWord(String)
    }

    /// Edit the authoritative snapshot under the reset lock, then advance its epoch.
    /// A dirty keyboard must reload, not merge its stale protections back into this file.
    @discardableResult
    func deleteLearnedEntry(_ entry: LearnedEntry) -> Bool {
        guard let defaults, directory != nil else { return false }
        do {
            try withLock { root in
                let epochs = currentEpochs
                var corrupt = 0
                guard let saved: PersonalTypingModel.State = read(root.appendingPathComponent(Self.learningName),
                    limit: Self.maximumLearningBytes, epoch: epochs.learning, corrupt: &corrupt),
                    var state = saved.validated() else { throw CocoaError(.fileReadCorruptFile) }
                switch entry {
                case .kept(let word):
                    state.kept.removeValue(forKey: word)
                    state.bigrams?.purge(word)
                case .count(let word):
                    state.counts.removeValue(forKey: word)
                    state.bigrams?.purge(word)
                case .pairWord(let word): state.bigrams?.purge(word)
                case .rejected(let pair): state.rejected.removeAll { $0 == pair }
                }
                switch entry {
                case .kept(let word), .count(let word), .pairWord(let word):
                    state.rejected.removeAll { pair in
                        pair.typed == word || pair.replacement == word
                            || pair.context?.split(separator: " ").contains(Substring(word)) == true
                    }
                case .rejected: break
                }
                let next = epochs.learning == Int.max ? 0 : epochs.learning + 1
                let data = try JSONEncoder().encode(Saved(epoch: next, value: state))
                guard data.count <= Self.maximumLearningBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try write(data, to: root.appendingPathComponent(Self.learningName))
                defaults.set(next, forKey: Self.learningResetKey)
                defaults.synchronize()
            }
            Self.postChanged()
            return true
        } catch { return false }
    }

    @discardableResult
    func requestLearningReset() -> Bool { requestReset(learning: true) }

    @discardableResult
    func requestDiagnosticsReset() -> Bool { requestReset(learning: false) }

    private func requestReset(learning: Bool) -> Bool {
        guard let defaults else { return false }
        let reset = {
            let epochs = self.currentEpochs
            let value = learning ? epochs.learning : epochs.diagnostics
            // Wrap only after Int.max; never overflow on a corrupt defaults value.
            defaults.set(value == Int.max ? 0 : value + 1,
                         forKey: learning ? Self.learningResetKey : Self.diagnosticsResetKey)
            defaults.synchronize()
        }
        do {
            if directory != nil {
                try withLock { root in
                    reset()
                    let file = root.appendingPathComponent(learning ? Self.learningName : Self.diagnosticsName)
                    // The epoch is authoritative even if removing an old file fails.
                    try? FileManager.default.removeItem(at: file)
                }
            } else { reset() }
            Self.postChanged()
            return true
        } catch { return false }
    }

    nonisolated static func postChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotification as CFString), nil, nil, true)
    }

    private func fileInfo(_ name: String) -> KeyboardLearningSnapshot.FileInfo {
        guard let file = directory?.appendingPathComponent(name),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return .init(bytes: nil, modifiedAt: nil)
        }
        return .init(bytes: (attributes[.size] as? NSNumber)?.intValue,
                     modifiedAt: attributes[.modificationDate] as? Date)
    }

    private func read<Value: Codable>(_ url: URL, limit: Int, epoch: Int, corrupt: inout Int) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= limit else { throw CocoaError(.fileReadCorruptFile) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.epoch >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            guard header.epoch == epoch else { return nil }
            return try JSONDecoder().decode(Saved<Value>.self, from: data).value
        } catch { corrupt += 1; return nil }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Self.protect(url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Owner-only, readable after first unlock (the keyboard writes while the device is locked), not backed up.
    nonisolated static func protect(_ url: URL, directory: Bool = false) throws {
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                              .posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    private func withLock<T>(_ work: (URL) throws -> T) throws -> T {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try Self.protect(directory, directory: true)
        let file = directory.appendingPathComponent("learning.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var locked = false
        for attempt in 0..<3 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard locked else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(fd, LOCK_UN) }
        try Self.protect(file)
        return try work(directory)
    }
}

typealias KeyboardLearningObserver = StoreChangeObserver

/// Snapshot refresh lifecycle adapted from AVGVSTVS96/iikb
/// Packages/KeyboardModules/Sources/KeyboardStore/MemoryStore.swift (MIT).
@MainActor
final class StoreChangeObserver {
    private let registration: Registration

    init(notificationName: String = KeyboardLearningStore.changedNotification,
         _ changed: @escaping @MainActor @Sendable () -> Void) {
        registration = Registration(notificationName: notificationName, changed)
    }

    func invalidate() { registration.invalidate() }
    deinit { registration.invalidate() }

    /// Darwin callbacks may arrive off-main. Only immutable callback data and a locked flag cross threads.
    nonisolated private final class Registration: @unchecked Sendable {
        let changed: @MainActor @Sendable () -> Void
        private let lock = NSLock()
        private var active = true

        init(notificationName: String, _ changed: @escaping @MainActor @Sendable () -> Void) {
            self.changed = changed
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                    guard let observer else { return }
                    let registration = Unmanaged<Registration>.fromOpaque(observer).takeUnretainedValue()
                    Task { @MainActor [weak registration] in
                        guard let registration, registration.isActive else { return }
                        registration.changed()
                    }
                }, notificationName as CFString, nil, .deliverImmediately)
        }

        private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

        func invalidate() {
            lock.lock()
            let wasActive = active
            active = false
            lock.unlock()
            if wasActive {
                CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                    Unmanaged.passUnretained(self).toOpaque(), nil, nil)
            }
        }
    }
}
