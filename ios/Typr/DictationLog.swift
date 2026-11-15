import AVFAudio
import Foundation
import Observation
import UIKit

struct DictationLogText: Codable, Equatable, Sendable {
    static let maximumBytes = 4_000
    let text: String
    let truncated: Bool
    let originalUTF8Bytes: Int
    let wordCount: Int

    init(_ source: String) {
        originalUTF8Bytes = source.utf8.count
        wordCount = CleanupGuard.wordCount(source)
        truncated = originalUTF8Bytes > Self.maximumBytes
        text = Self.capped(source)
    }

    /// A Character (including combining marks / joined emoji) is never split. The ellipsis
    /// is inside the budget; an individual Character larger than the budget is omitted.
    private static func capped(_ source: String) -> String {
        guard source.utf8.count > maximumBytes else { return source }
        var result = "", bytes = 0
        for character in source {
            let count = String(character).utf8.count
            guard bytes + count <= maximumBytes - "…".utf8.count else { break }
            result.append(character)
            bytes += count
        }
        return result + "…"
    }

    func recapped() -> Self {
        // Preserve pre-truncation counts when reading our own file, but never trust its text cap.
        Self(text: Self.capped(text), truncated: truncated || text.utf8.count > Self.maximumBytes,
             originalUTF8Bytes: max(originalUTF8Bytes, text.utf8.count), wordCount: max(0, wordCount))
    }

    private init(text: String, truncated: Bool, originalUTF8Bytes: Int, wordCount: Int) {
        self.text = text
        self.truncated = truncated
        self.originalUTF8Bytes = originalUTF8Bytes
        self.wordCount = wordCount
    }
}

enum DictationLogStatus: String, Codable, Sendable {
    case transcribing, finished, asrFailed, cancelled, interrupted

    var label: String {
        switch self {
        case .transcribing: "Transcribing…"
        case .finished: "Finished"
        case .asrFailed: "Speech recognition failed"
        case .cancelled: "Cancelled"
        case .interrupted: "The app ended before this dictation finished"
        }
    }
}

// `upstream` remains decodeable for durable logs from before the experiment was removed.
// New dictations use only `typr` or `none`.
enum DictationLogCleanupPath: String, Codable, Sendable { case typr, upstream, none }

enum DictationLogASRFailure: String, Codable, Sendable {
    case modelNotReady, cancelled, noSpeech, other

    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? ParakeetTranscriber.TranscriberError {
            switch error {
            case .notPrepared: return .modelNotReady
            case .emptyTranscript: return .noSpeech
            }
        }
        if let error = error as? WhisperTranscriber.TranscriberError {
            switch error {
            case .notInstalled, .notPrepared, .insufficientStorage, .preparationFailed: return .modelNotReady
            case .silentAudio: return .noSpeech
            case .emptyTranscript, .corruptModel: return .other
            }
        }
        if let error = error as? SpeechEngineError {
            switch error {
            case .notReady, .notInstalled: return .modelNotReady
            case .requiresNewerOS, .unsupportedDevice, .languageUnsupported: return .other
            }
        }
        if #available(iOS 26.0, *), let error = error as? AppleSpeechTranscriber.TranscriberError {
            switch error {
            case .unavailable, .languageUnsupported: return .modelNotReady
            case .emptyTranscript: return .noSpeech
            case .authorizationDenied: return .other
            }
        }
        return .other
    }
}

/// All cross-queue state is immutable value snapshots, never a controller, model or AVAudioSession.
struct DictationLogContext: Codable, Equatable, Sendable {
    var createdAt = Date()
    var appVersion = "unknown"
    var appBuild = "unknown"
    var systemVersion = "unknown"
    var keyboardJob = false
    var copyToPasteboard = false
    var style = "Polished"
    var speechEngine = "unknown"
    var speechLanguage = "unknown"
    var recordingDuration: TimeInterval = 0
    var inputPortTypes: [String] = []
    var bluetoothInput = false
    var loudestAverageDBFS: Float?
    var cleanupPath: DictationLogCleanupPath = .none
    var vocabularyCount = 0
    // Optional additions keep schema-1 history readable; nil means not recorded, never off.
    var vocabularyEnabled: Bool?
    var upstreamCleanupEnabled: Bool?
    var typrCleanupEnabled: Bool?
    /// Legacy (schema 2 before vocabularyTerms): active terms joined into one capped string.
    /// Kept readable for older entries; new entries do not snapshot the full dictionary.
    var vocabularySnapshot: DictationLogText?
    /// Legacy complete dictionary snapshot. New entries retain only applied replacements,
    /// never unrelated or inactive saved terms. Kept readable for existing archives.
    var vocabularyTerms: [String]?
    /// The dictation language picker's value ("automatic", "de", "en"). nil means not recorded.
    var dictationLanguage: String?
    /// Where the preceding text offered to Typr cleanup came from ("keyboard", "previous-dictations")
    /// and its length in characters. The text itself is never logged. nil means none was offered.
    var cleanupContextSource: String?
    var cleanupContextCharacters: Int?
    /// `TechGlossary.revision` used for this entry's spelling fixes. nil means not recorded.
    var glossaryRevision: String?

    static let maximumLoggedVocabularyTerms = CustomVocabularySettings.maxTermCount
    static func cappedVocabularyTerms(_ terms: [String]) -> [String] {
        terms.prefix(maximumLoggedVocabularyTerms).map { String($0.prefix(CustomVocabularySettings.maxTermLength)) }
    }

    @MainActor
    static func capture(keyboardJob: Bool, copyToPasteboard: Bool, style: DictationStyle,
                        engine: String, language: String, duration: TimeInterval,
                        loudestAverage: Float?, cleanupPath: DictationLogCleanupPath,
                        vocabularyCount: Int, vocabularyEnabled: Bool? = nil,
                        upstreamCleanupEnabled: Bool? = nil, typrCleanupEnabled: Bool? = nil,
                        cleanupContext: CleanupContext? = nil) -> Self {
        var context = Self()
        context.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        context.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        context.systemVersion = UIDevice.current.systemVersion
        context.keyboardJob = keyboardJob
        context.copyToPasteboard = copyToPasteboard
        // Historic "Casual" entries used lowercase; never reuse that evidence label.
        context.style = style == .casual ? "Casual (natural case)" : style.label
        context.speechEngine = engine
        context.speechLanguage = language
        context.recordingDuration = duration
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        context.inputPortTypes = inputs.map { $0.portType.rawValue } // Never the device name or UID.
        context.bluetoothInput = inputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .bluetoothA2DP
        }
        context.loudestAverageDBFS = loudestAverage
        context.cleanupPath = cleanupPath
        context.vocabularyCount = vocabularyCount
        context.vocabularyEnabled = vocabularyEnabled
        context.upstreamCleanupEnabled = upstreamCleanupEnabled
        context.typrCleanupEnabled = typrCleanupEnabled
        // Do not retain the user's entire dictionary (including unrelated, inactive terms).
        // Applied replacements remain recorded on the two spelling passes.
        context.dictationLanguage = cleanupContext?.language.rawValue
        context.cleanupContextSource = cleanupContext?.source?.rawValue
        context.cleanupContextCharacters = cleanupContext?.preceding?.count
        context.glossaryRevision = TechGlossary.revision
        return context
    }
}

struct DictationLogReplacement: Codable, Equatable, Sendable {
    var before: DictationLogText
    var after: DictationLogText
    var term: DictationLogText
    /// "built-in" for a tech glossary fix; nil for Custom vocabulary (and older entries).
    var source: String?

    mutating func recap() {
        before = before.recapped()
        after = after.recapped()
        term = term.recapped()
    }
}

struct DictationLogSpellingPass: Codable, Equatable, Sendable {
    static let maximumReplacements = 20
    var changes: [DictationLogReplacement] = []
    var totalChanges = 0

    mutating func record(before: String, after: String, term: String, source: String? = nil) {
        totalChanges += 1
        guard changes.count < Self.maximumReplacements else { return }
        changes.append(DictationLogReplacement(before: DictationLogText(before),
            after: DictationLogText(after), term: DictationLogText(term), source: source))
    }

    mutating func recap() {
        changes = Array(changes.prefix(Self.maximumReplacements))
        for index in changes.indices { changes[index].recap() }
        totalChanges = max(totalChanges, changes.count)
    }
}

struct DictationLogEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var schemaVersion = DictationLogDocument.version
    var context: DictationLogContext
    var revision: Int? = 1
    var rating: String?
    var issues: [String]?
    var ratingOrder: DictationFeedbackOrder?
    var referenceOrder: DictationFeedbackOrder?
    var keyboardFeedbackOffer: DictationFeedbackOffer?
    var status: DictationLogStatus = .transcribing
    var asrFailure: DictationLogASRFailure?
    var asrErrorType: String?
    var recognized: DictationLogText?
    var aiInput: DictationLogText?
    var aiAnswer: DictationLogText?
    var finalText: DictationLogText?
    // Optional schema-1 additions: nil is missing evidence, never inferred unchanged.
    var cleanupOutput: DictationLogText?
    var formattedText: DictationLogText?
    var expectedText: DictationLogText?
    var feedbackNote: DictationLogText?
    var upstreamReason: String?
    var answerUse: String?
    var cleanupOutcome: String?
    var cleanupSummary: String?
    var cleanupChanged: Bool?
    var pipelineChanged: Bool?
    var upstreamOutcome: String?
    var firstSpellingChanged = false
    var secondSpellingChanged = false
    var firstSpellingPass: DictationLogSpellingPass?
    var secondSpellingPass: DictationLogSpellingPass?
    var asrMilliseconds: Int64?
    var cleanupMilliseconds: Int64?
    var modelMilliseconds: Int64?
    var stopToFinalMilliseconds: Int64?
    var promptRevision = CleanupPrompt.revision
    var guardRevision = CleanupGuard.revision

    /// A selected cleanup path is not proof of a successful AI pass.
    /// Rejected, late, skipped and failed answers must never be presented as revisions.
    var feedbackAIText: DictationLogText? {
        switch context.cleanupPath {
        case .typr:
            guard answerUse == "accepted" else { return nil }
            return cleanupOutput ?? aiAnswer
        case .upstream:
            guard upstreamOutcome == "changed" || upstreamOutcome == "unchanged" else { return nil }
            return cleanupOutput
        case .none:
            return nil
        }
    }

    var sourceLabel: String { context.keyboardJob ? "Keyboard" : "App" }
    var outputLabel: String {
        var outputs = ["shown in app"]
        if context.keyboardJob { outputs.append("provided to keyboard") }
        if context.copyToPasteboard, finalText?.originalUTF8Bytes ?? 0 > 0 { outputs.append("copied to clipboard") }
        return outputs.joined(separator: "; ")
    }
    var lateAnswerLabel: String {
        switch cleanupOutcome {
        case "failed(deadline)": "arrived after the cleanup deadline; not used"
        case "failed(expired)": "arrived after iOS ended the background time; not used"
        default: "arrived after cleanup had resolved; not used"
        }
    }
    var answerLabel: String { answerUse == "late" ? lateAnswerLabel : (answerUse ?? "No model answer") }

    mutating func recap() {
        recognized = recognized?.recapped()
        aiInput = aiInput?.recapped()
        aiAnswer = aiAnswer?.recapped()
        finalText = finalText?.recapped()
        cleanupOutput = cleanupOutput?.recapped()
        formattedText = formattedText?.recapped()
        expectedText = expectedText?.recapped()
        feedbackNote = feedbackNote?.recapped()
        context.vocabularySnapshot = context.vocabularySnapshot?.recapped()
        context.vocabularyTerms = context.vocabularyTerms.map(DictationLogContext.cappedVocabularyTerms)
        firstSpellingPass?.recap()
        secondSpellingPass?.recap()
    }
}

struct DictationLogDocument: Codable, Sendable {
    static let version = 1
    var schemaVersion = version
    var entries: [DictationLogEntry]
}

struct DictationLogToken: Equatable, Sendable {
    let enabled: Bool
    let epoch: UInt64
}

@MainActor
@Observable
final class DictationLogStore {
    static let shared = DictationLogStore(storage: DictationLogStorage(url: URL.applicationSupportDirectory
        .appendingPathComponent("Typr", isDirectory: true).appendingPathComponent("dictation-log.json")), feedbackBridge: .shared)
    static let maximumEntries = 50 // full-entry cache, NOT archive retention
    private(set) var entries: [DictationLogEntry] = []
    private(set) var metadata: [DictationLogMetadata] = []
    private(set) var epoch: UInt64 = 0
    private var storageGeneration: UInt64 = 0
    private(set) var archiveID = UUID()
    private(set) var isEnabled: Bool
    @ObservationIgnored private var feedbackLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isLoading = true {
        didSet {
            if !isLoading {
                let waiters = feedbackLoadWaiters
                feedbackLoadWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// Resolve lineage before creating an offer. Capture itself never waits for archive I/O.
    func waitForFeedbackReadiness() async {
        guard isLoading else { return }
        await withCheckedContinuation { feedbackLoadWaiters.append($0) }
    }
    private(set) var isClearing = false
    private var feedbackPermission: DictationFeedbackPermission?
    private let feedbackBridge: DictationFeedbackBridge?
    private var feedbackInFlight = Set<UUID>()
    private var feedbackPolling = false
    private var lastFeedbackPoll = Date.distantPast
    private(set) var storageProblem: String?
    private(set) var keyboardFeedbackNotice: String?
    func retryKeyboardFeedback() { keyboardFeedbackNotice = nil; drainKeyboardFeedback(force: true) }
    private(set) var exporting = false
    private(set) var exportURL: URL?
    private var exportIDs: [UUID]?
    private(set) var exportProblem: String?
    private var lastLoadProblem = false
    private var active = Set<UUID>()
    private var pinned: UUID?
    private var deleted = Set<UUID>()
    private var failedDeletes = Set<UUID>()
    private var dirty: [UUID: DictationLogEntry] = [:]
    private let settings: TyprSettings
    let storage: DictationLogStorage
    private func clearResolvedProblem() {
        if !lastLoadProblem && dirty.isEmpty && failedDeletes.isEmpty { storageProblem = nil }
    }
    private static let problem = "Some dictation log files could not be read, saved or deleted. Originals are preserved when possible. Retry; dictation still works."

    init(storage: DictationLogStorage, settings: TyprSettings = TyprSettings(),
         feedbackBridge: DictationFeedbackBridge? = nil) {
        self.storage = storage; self.settings = settings; self.feedbackBridge = feedbackBridge
        isEnabled = settings.dictationLog
        reload()
    }
    func reload() {
        let generation = storageGeneration
        isLoading = true
        storage.load { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else { return }
                self.archiveID = result.archiveID
                let local = Set(self.metadata.map(\.id)).union(self.deleted)
                self.metadata += result.metadata.filter { !local.contains($0.id) }
                self.metadata.sort { $0.date > $1.date }
                self.isLoading = false
                self.lastLoadProblem = result.problem
                if result.problem { self.storageProblem = Self.problem }
                else { self.clearResolvedProblem() }
                self.loadRecent()
                self.syncFeedbackPermission()
                self.drainKeyboardFeedback(force: true)
            }
        }
    }
    func feedbackSettingsChanged() {
        syncFeedbackPermission(revoke: true)
        feedbackBridge?.discardRevoked()
    }
    private func syncFeedbackPermission(revoke: Bool = false) {
        guard let feedbackBridge else { return }
        guard !isLoading || revoke else { return } // Loading is not consent revocation.
        let previousPermission = feedbackPermission ?? feedbackBridge.permission
        if !revoke, lastLoadProblem, let previousPermission, previousPermission.archiveID != archiveID {
            feedbackPermission = previousPermission; return // Unknown lineage: retain queued evidence for Retry.
        }
        let identity = isLoading ? previousPermission?.archiveID ?? archiveID : archiveID
        let enabled = isEnabled && settings.dictationFeedbackStrip && !isClearing
        if !revoke, let previous = feedbackPermission ?? feedbackBridge.permission,
           previous.archiveID == identity, previous.enabled == enabled {
            feedbackPermission = previous; return
        }
        let permission = DictationFeedbackPermission(archiveID: identity, generation: UUID(), enabled: enabled)
        feedbackPermission = permission; feedbackBridge.publish(permission)
    }
    func makeKeyboardFeedbackOffer(recording: DictationLogRecording, jobID: String, resultID: String,
                                   expiresAt: Date) -> DictationFeedbackOffer? {
        guard !isLoading, !isClearing else { return nil }
        syncFeedbackPermission()
        guard recording.epoch == epoch,
              let permission = feedbackPermission, permission.enabled, permission.archiveID == archiveID,
              var entry = entry(recording.entryID), entry.status == .finished, entry.context.keyboardJob else { return nil }
        let offer = DictationFeedbackOffer(resultID: resultID, jobID: jobID, entryID: entry.id,
            archiveID: archiveID, generation: permission.generation, expiresAt: expiresAt)
        entry.keyboardFeedbackOffer = offer; entry.revision = (entry.revision ?? 1) + 1
        put(entry) // Queue before publishing the result; never await I/O on the output path.
        return offer
    }
    func drainKeyboardFeedback(force: Bool = false) {
        guard let bridge = feedbackBridge, !isLoading, !isClearing else { return }
        syncFeedbackPermission()
        guard feedbackPermission?.enabled == true, !feedbackPolling,
              force || Date().timeIntervalSince(lastFeedbackPoll) >= 1 else { return }
        feedbackPolling = true; lastFeedbackPoll = Date()
        let generation = storageGeneration
        bridge.pending { [weak self] events, problem in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.feedbackPolling = false
                guard generation == self.storageGeneration else { return }
                if problem { self.keyboardFeedbackNotice = "Some queued keyboard feedback expired or could not be read. It was not reported as saved." }
                for event in events where self.feedbackInFlight.insert(event.eventID).inserted {
                    self.consumeKeyboardFeedback(event, bridge: bridge, generation: generation)
                }
            }
        }
    }
    private func consumeKeyboardFeedback(_ event: DictationFeedbackEvent, bridge: DictationFeedbackBridge,
                                         generation: UInt64) {
        guard event.isValid(at: Date()), let permission = feedbackPermission, permission.enabled,
              permission.archiveID == event.offer.archiveID, permission.generation == event.offer.generation,
              !deleted.contains(event.offer.entryID) else {
            bridge.remove(event.eventID); feedbackInFlight.remove(event.eventID); return
        }
        storage.read(event.offer.entryID) { [weak self] persisted in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else { return }
                defer { self.feedbackInFlight.remove(event.eventID) }
                guard self.feedbackPermission == permission, self.isEnabled,
                      self.settings.dictationFeedbackStrip, !self.deleted.contains(event.offer.entryID) else { return }
                guard var entry = self.entry(event.offer.entryID) ?? persisted else {
                    // Startup finished before this read. A corrupt/unreadable archive keeps events
                    // pending for Retry; a definitively absent entry is rejected, never recreated.
                    if !self.lastLoadProblem { bridge.remove(event.eventID) }
                    return
                }
                guard entry.keyboardFeedbackOffer == event.offer else { bridge.remove(event.eventID); return }
                if let order = entry.ratingOrder, order >= event.order {
                    // Crash between source commit and event removal is idempotent. The cache alone
                    // is not an ACK: only the already durable order permits removing this event.
                    if let durable = persisted?.ratingOrder, durable >= event.order { bridge.remove(event.eventID) }
                    return
                }
                entry.rating = event.rating
                if let issues = event.issues { entry.issues = issues }
                entry.ratingOrder = event.order; entry.revision = (entry.revision ?? 1) + 1
                self.put(entry) { success in if success { bridge.remove(event.eventID) } }
            }
        }
    }

    func token() -> DictationLogToken { DictationLogToken(enabled: isEnabled, epoch: epoch) }
    func begin(token: DictationLogToken, context: DictationLogContext,
               stoppedAt: ContinuousClock.Instant? = nil,
               clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) -> DictationLogRecording? {
        guard token.enabled, isEnabled, token.epoch == epoch else { return nil }
        let entry = DictationLogEntry(context: context)
        active.insert(entry.id); put(entry)
        return DictationLogRecording(entryID: entry.id, epoch: epoch, store: self, stoppedAt: stoppedAt, clock: clock)
    }
    func setEnabled(_ enabled: Bool) {
        settings.dictationLog = enabled
        guard isEnabled != enabled else { return }
        // Deliberate retention exception: OFF stops collection, it does not delete history.
        // Finalize before fencing callbacks so a persisted capture never stays transcribing.
        for var entry in entries where entry.status == .transcribing {
            entry.status = .interrupted; entry.revision = (entry.revision ?? 1) + 1; put(entry)
        }
        isEnabled = enabled; epoch &+= 1; active = []
        syncFeedbackPermission(revoke: true); feedbackBridge?.discardRevoked()
    }
    func clear() {
        epoch &+= 1; storageGeneration &+= 1
        let generation = storageGeneration; let identity = UUID()
        exportURL = nil; exporting = false; active = []; pinned = nil
        isClearing = true; feedbackInFlight = []
        syncFeedbackPermission(revoke: true); feedbackBridge?.discardRevoked()
        // Keep visible evidence on failure. Fresh post-clear captures are separate and survive.
        let oldIDs = Set(metadata.map(\.id))
        deleted.formUnion(oldIDs)
        storage.clear(archiveID: identity) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else { return }
                self.isClearing = false
                if success {
                    self.archiveID = identity
                    self.entries.removeAll { oldIDs.contains($0.id) }
                    self.metadata.removeAll { oldIDs.contains($0.id) }
                    for id in oldIDs { self.dirty[id] = nil }
                    self.isLoading = false; self.storageProblem = nil
                } else {
                    self.deleted.subtract(oldIDs)
                    self.storageProblem = Self.problem
                    self.reload()
                }
                self.syncFeedbackPermission(revoke: true)
            }
        }
    }
    func delete(_ id: UUID) {
        deleted.insert(id); exportURL = nil
        dirty[id] = nil; active.remove(id)
        let generation = storageGeneration
        storage.delete(id) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else { return }
                if success {
                    self.entries.removeAll { $0.id == id }; self.metadata.removeAll { $0.id == id }
                    self.dirty[id] = nil; self.active.remove(id)
                    self.failedDeletes.remove(id)
                    self.clearResolvedProblem()
                } else {
                    self.failedDeletes.insert(id); self.storageProblem = Self.problem
                }
            }
        }
    }
    func entry(_ id: UUID) -> DictationLogEntry? { entries.first { $0.id == id } }
    func loadEntry(_ id: UUID, pin: Bool = false, then: (@MainActor (DictationLogEntry) -> Void)? = nil) {
        if pin { pinned = id }
        guard !deleted.contains(id) else { return }
        if let entry = entry(id) { then?(entry); return }
        let generation = storageGeneration
        storage.read(id) { [weak self] loaded in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation, !self.deleted.contains(id), let loaded else { return }
                // New mutations always win over old asynchronous reads.
                let value = self.entry(id) ?? loaded
                if self.entry(id) == nil { self.entries.append(value); self.trimCache() }
                then?(value)
            }
        }
    }
    func loadRecent() { for row in metadata.prefix(Self.maximumEntries) { loadEntry(row.id) } }
    /// nil preserves a field; an empty string explicitly clears it.
    /// The everyday note editor never creates or overwrites a human reference.
    func saveFeedback(for id: UUID, expectedText: String?, note: String?) {
        guard (expectedText?.utf8.count ?? 0) <= 4_000, (note?.utf8.count ?? 0) <= 4_000 else { return }
        let order = DictationFeedbackOrder.app()
        loadEntry(id) { [weak self] source in
            guard let self else { return }; var entry = source
            if let previous = entry.referenceOrder, order <= previous { return }
            if let expectedText { entry.expectedText = expectedText.isEmpty ? nil : DictationLogText(expectedText) }
            if let note { entry.feedbackNote = note.isEmpty ? nil : DictationLogText(note) }
            entry.referenceOrder = order; entry.revision = (entry.revision ?? 1) + 1; self.put(entry)
        }
    }
    func rate(_ id: UUID, rating: String, issues: [String]? = nil,
              order: DictationFeedbackOrder = .app()) {
        loadEntry(id) { [weak self] source in
            guard let self else { return }; var entry = source
            if let previous = entry.ratingOrder, order <= previous { return }
            entry.rating = rating
            // Rating changes never silently erase categories, notes or reference.
            if let issues { entry.issues = issues }
            entry.ratingOrder = order; entry.revision = (entry.revision ?? 1) + 1; self.put(entry)
        }
    }
    fileprivate func update(_ id: UUID, epoch: UInt64, _ mutate: (inout DictationLogEntry) -> Void) {
        guard isEnabled, self.epoch == epoch, !deleted.contains(id), var entry = entry(id) else { return }
        mutate(&entry); entry.revision = (entry.revision ?? 1) + 1
        put(entry)
    }
    fileprivate func releaseRecording(_ id: UUID) { active.remove(id); trimCache() }
    private func trimCache() {
        let protected = active.union(dirty.keys).union(pinned.map { [$0] } ?? [])
        var count = 0
        entries = entries.sorted { $0.context.createdAt > $1.context.createdAt }.filter {
            if protected.contains($0.id) { return true }
            count += 1; return count <= Self.maximumEntries
        }
    }
    private func put(_ entry: DictationLogEntry, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !deleted.contains(entry.id) else { completion?(false); return }
        entries.removeAll { $0.id == entry.id }; entries.insert(entry, at: 0)
        let fields = [entry.recognized, entry.aiInput, entry.aiAnswer, entry.cleanupOutput,
                      entry.formattedText, entry.finalText, entry.expectedText, entry.feedbackNote,
                      entry.context.vocabularySnapshot]
        let textBytes = fields.reduce(2_048) { $0 + ($1?.text.utf8.count ?? 0) }
        let terms: [String] = entry.context.vocabularyTerms ?? []
        let termBytes = terms.reduce(0) { (sum: Int, term: String) in sum + term.utf8.count + 4 }
        let estimate = textBytes + termBytes
        if let index = metadata.firstIndex(where: { $0.id == entry.id }) {
            metadata[index] = DictationLogMetadata(entry, bytes: max(metadata[index].bytes, estimate))
        } else {
            let index = metadata.firstIndex { $0.date < entry.context.createdAt } ?? metadata.endIndex
            metadata.insert(DictationLogMetadata(entry, bytes: estimate), at: index)
        }
        dirty[entry.id] = entry; trimCache()
        let generation = storageGeneration
        storage.save(entry) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else { return }
                if success, self.dirty[entry.id]?.revision == entry.revision { self.dirty[entry.id] = nil }
                if !success { self.storageProblem = Self.problem }
                else { self.clearResolvedProblem() }
                self.trimCache()
                completion?(success)
            }
        }
    }
    func retry() {
        for id in failedDeletes { delete(id) }
        for entry in dirty.values where !deleted.contains(entry.id) { put(entry) }
        reload()
    }
    func preparedJSON(for ids: [UUID]?) -> URL? { exportIDs == ids ? exportURL : nil }
    func releaseJSON(_ url: URL) {
        storage.removeExport(url)
        if exportURL == url { exportURL = nil }
    }
    func prepareJSON(ids: [UUID]? = nil) {
        guard !exporting else { return }
        if let exportURL { storage.removeExport(exportURL) }
        exporting = true; exportURL = nil; exportProblem = nil; let generation = storageGeneration
        storage.export(ids: ids, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else {
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    return
                }
                self.exporting = false
                switch result {
                case .success(let url): self.exportIDs = ids; self.exportURL = url
                case .failure: self.exportProblem = "JSON could not be prepared. Prepare again to retry. No file was shared."
                }
            }
        }
    }
}

/// One capture, one immutable entry ID and permission epoch; never a global current draft.
@MainActor
final class DictationLogRecording: CleanupTextDiagnostics {
    let entryID: UUID
    fileprivate let epoch: UInt64
    private weak var store: DictationLogStore?
    private let clock: @MainActor () -> ContinuousClock.Instant
    private let stopped: ContinuousClock.Instant
    private var terminal: DictationLogStatus?
    private var raw: String?

    fileprivate init(entryID: UUID, epoch: UInt64, store: DictationLogStore,
                     stoppedAt: ContinuousClock.Instant?, clock: @escaping @MainActor () -> ContinuousClock.Instant) {
        self.entryID = entryID
        self.epoch = epoch
        self.store = store
        self.clock = clock
        stopped = stoppedAt ?? clock()
    }

    deinit {
        let id = entryID
        let owner = store
        Task { @MainActor [weak owner] in owner?.releaseRecording(id) }
    }

    private func update(_ mutate: (inout DictationLogEntry) -> Void) {
        store?.update(entryID, epoch: epoch, mutate)
    }

    func recognized(_ text: String, spelled: String, asrMilliseconds: Int64,
                    spellingPass: DictationLogSpellingPass? = nil) {
        guard terminal == nil else { return }
        raw = text
        update {
            $0.recognized = DictationLogText(text)
            $0.aiInput = text == spelled ? nil : DictationLogText(spelled)
            $0.firstSpellingChanged = text != spelled
            $0.firstSpellingPass = spellingPass
            $0.asrMilliseconds = asrMilliseconds
        }
    }

    func processingStages(cleanupOutput: String, formattedText: String) {
        guard terminal == nil else { return }
        update {
            $0.cleanupOutput = DictationLogText(cleanupOutput)
            $0.formattedText = DictationLogText(formattedText)
        }
    }

    func cleanupResolved(_ observation: CleanupObservation, changed: Bool?) {
        guard terminal == nil else { return }
        update {
            $0.cleanupOutcome = observation.outcome.dictationLogLabel
            $0.cleanupSummary = CleanupDiagnostics.summary(observation.outcome,
                latencyMilliseconds: observation.latencyMilliseconds, changed: changed)
            $0.cleanupChanged = changed
            $0.cleanupMilliseconds = observation.latencyMilliseconds
        }
    }

    func modelFailed(modelMilliseconds: Int64) {
        guard terminal == nil else { return }
        update { $0.modelMilliseconds = modelMilliseconds }
    }

    func modelAnswer(_ text: String, use: CleanupAnswerUse, modelMilliseconds: Int64) {
        if let terminal {
            guard (terminal == .finished || terminal == .asrFailed), use == .late else { return }
        }
        update {
            $0.aiAnswer = DictationLogText(text)
            switch use {
            case .accepted: $0.answerUse = "accepted"
            case .rejected(let reason): $0.answerUse = "rejected(\(reason.label)); not used"
            case .late: $0.answerUse = "late"
            }
            $0.modelMilliseconds = modelMilliseconds
        }
    }

    func finish(text: String, beforeSpelling: String, spellingPass: DictationLogSpellingPass? = nil) {
        guard terminal == nil else { return }
        let elapsed = dictationLogMilliseconds(from: stopped, to: clock())
        update {
            $0.finalText = DictationLogText(text)
            $0.secondSpellingChanged = beforeSpelling != text
            $0.secondSpellingPass = spellingPass
            $0.pipelineChanged = raw.map { $0 != text }
            $0.stopToFinalMilliseconds = elapsed
        }
        finishIfOpen(.finished)
    }

    func failASR(_ error: any Error, milliseconds: Int64) {
        guard terminal == nil else { return }
        update {
            $0.asrFailure = DictationLogASRFailure.classify(error)
            // Type name only, not CustomStringConvertible / localizedDescription / associated values.
            if $0.asrFailure == .other { $0.asrErrorType = String(String(reflecting: type(of: error)).prefix(200)) }
            $0.asrMilliseconds = milliseconds
        }
        finishIfOpen(.asrFailed)
    }

    func finishIfOpen(_ status: DictationLogStatus) {
        guard terminal == nil, status != .transcribing else { return }
        terminal = status
        raw = nil
        update { $0.status = status }
    }
}
