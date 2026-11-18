import Foundation

/// The keyboard's single owner of personal learning and diagnostics. Persistent only when the
/// keyboard passes a store (Full Access); the app, previews and tests stay RAM-only by default.
/// Callers feed only trusted feedback.
@MainActor
final class KeyboardLearningSession {
    /// Obsolete `LearnedWordsStore` key, deleted once without migration (owner-approved).
    static let legacyLearnedWordsKey = "keyboard.learnedWords"

    private(set) var model: PersonalTypingModel
    private(set) var diagnostics: KeyboardDiagnostics
    /// Changes whenever calibration or personal priors may differ (decode cache key).
    private(set) var generation = 0
    /// Pending word feedback from an older epoch (switch change or reset) is discarded.
    private(set) var feedbackEpoch = 0
    /// Counts app-requested learning resets, which also end per-engine session keeps.
    private(set) var resets = 0
    private(set) var isPersistent: Bool
    private var store: KeyboardLearningStore
    /// Retry only before the first successful load, never after a write/permission failure.
    private var pendingLoad: KeyboardLearningStore?
    private var loadWasDeferred = false
    private let defaults: UserDefaults?
    private let allowsPersistence: () -> Bool
    private let debounce: Duration
    private var epochs: KeyboardLearningStore.Epochs
    private var dirty = false
    private var lastChange = ContinuousClock.now
    private var saveTask: Task<Void, Never>?
    private var observer: KeyboardLearningObserver?
    /// Two trusted predecessors in RAM, never restored from field text.
    private(set) var previousTrustedWord: String?
    var personalBigrams: PersonalBigramModel { isLearningEnabled ? model.state.bigrams ?? .init() : .init() }

    private var earlierTrustedWord: String?

    func breakWordSequence() {
        previousTrustedWord = nil
        earlierTrustedWord = nil
    }

    /// Both words must have independently settled, with exactly one intervening space.
    func settleTrustedWord(_ word: String, beforeInput: String) {
        guard isLearningEnabled, PersonalBigramModel.validWord(PersonalLexiconSnapshot.normalize(word)) else {
            breakWordSequence(); return
        }
        if let previousTrustedWord, beforeInput.hasSuffix(previousTrustedWord + " " + word + " ") {
            var earlier: String?
            if let candidate = earlierTrustedWord {
                let suffix = candidate + " " + previousTrustedWord + " " + word + " "
                if beforeInput.hasSuffix(suffix) { earlier = candidate }
            }
            model.recordPair(word, after: previousTrustedWord, earlier: earlier)
            modelChanged()
            earlierTrustedWord = previousTrustedWord
        } else { earlierTrustedWord = nil }
        previousTrustedWord = word
    }

    /// - Parameters:
    ///   - store: A persistent store, or `nil` for a RAM-only session.
    ///   - defaults: App Group defaults for the learning switch and reset epochs.
    ///   - allowsPersistence: Checked before every write (Full Access may be revoked).
    init(store: KeyboardLearningStore? = nil, defaults: UserDefaults? = nil,
         allowsPersistence: @escaping () -> Bool = { true }, debounce: Duration = .seconds(10)) {
        self.defaults = defaults
        self.allowsPersistence = allowsPersistence
        self.debounce = debounce
        if defaults?.object(forKey: Self.legacyLearnedWordsKey) != nil {
            defaults?.removeObject(forKey: Self.legacyLearnedWordsKey)
        }
        let enabled = TyprSettings(defaults: defaults).personalLearning
        var loaded: (PersonalTypingModel.State?, KeyboardDiagnostics)?
        var active = KeyboardLearningStore(directory: nil, defaults: defaults)
        // Read epochs before loading: a reset racing the load is then seen by the next refresh.
        var initialEpochs = active.currentEpochs
        pendingLoad = store?.isPersistent == true ? store : nil
        if let store = pendingLoad, allowsPersistence() {
            initialEpochs = store.currentEpochs
            let result = store.load()
            // A locked or unreadable store stays RAM-only: never overwrite saved data with an empty model.
            if store.isPersistent {
                loaded = result
                active = store
                pendingLoad = nil
            } else { loadWasDeferred = true }
        }
        self.store = active
        isPersistent = loaded != nil
        epochs = initialEpochs
        model = PersonalTypingModel(state: loaded?.0 ?? .init(), isLearningEnabled: enabled)
        diagnostics = loaded?.1 ?? KeyboardDiagnostics()
        if loadWasDeferred { diagnostics.increment(.storeLoadDeferred) }
        if isPersistent { observer = KeyboardLearningObserver { [weak self] in self?.refresh() } }
    }

    var isLearningEnabled: Bool { model.isLearningEnabled }
    /// Keeps and rejected pairs protect regardless of the switch.
    var protections: PersonalLexiconSnapshot { model.lexicon }
    /// Personal word priors for the decoder: none while learning is off.
    var personalPriors: PersonalLexiconSnapshot { model.isLearningEnabled ? model.lexicon : .empty }
    /// Read-only frozen full-covariance/affine-aim projection; `nil` while off or below threshold.
    func calibration(for layout: KeyboardLayout) -> SpatialTouchCalibration? { model.calibration(for: layout) }

    /// Fast aim never crosses host/field/layout/lifecycle discontinuities. Slow state stays.
    func resetFastAim() {
        breakWordSequence()
        // Repeated evidence invalidation/polls with no active fast state are no-ops.
        if model.resetFastAim() { generation &+= 1 }
    }

    /// Keyboard appearance and settings sync: switch value and app reset epochs.
    func refresh() {
        let oldFeedbackEpoch = feedbackEpoch
        defer { if feedbackEpoch != oldFeedbackEpoch { onLabelsInvalidated?() } }
        if isPersistent && !allowsPersistence() { stopPersistence() }
        let enabled = TyprSettings(defaults: defaults).personalLearning
        if model.isLearningEnabled != enabled {
            breakWordSequence()
            model.isLearningEnabled = enabled
            generation &+= 1
            feedbackEpoch &+= 1
        }
        if let pendingLoad, allowsPersistence() {
            let beforeLoad = pendingLoad.currentEpochs
            let result = pendingLoad.load()
            if pendingLoad.isPersistent {
                // Disk is authoritative: never overwrite saved protection with the provisional
                // RAM-only model from a contended startup. Pending feedback cannot cross this load.
                store = pendingLoad
                self.pendingLoad = nil
                isPersistent = true
                breakWordSequence()
                model = PersonalTypingModel(state: result.0 ?? .init(), isLearningEnabled: enabled)
                diagnostics = result.1
                if loadWasDeferred { diagnostics.increment(.storeLoadDeferred) }
                epochs = beforeLoad
                generation &+= 1
                feedbackEpoch &+= 1
                markChanged()
            } else if !loadWasDeferred {
                loadWasDeferred = true
                diagnostics.increment(.storeLoadDeferred)
            }
        }
        let current = store.currentEpochs
        guard current != epochs else { return }
        breakWordSequence()
        // Neither feedback nor undo attribution may cross either reset's counting period.
        feedbackEpoch &+= 1
        var loaded: (PersonalTypingModel.State?, KeyboardDiagnostics)?
        if isPersistent {
            let result = store.load()
            if store.isPersistent { loaded = result } else { stopPersistence() }
        }
        if current.learning != epochs.learning {
            model = PersonalTypingModel(state: loaded?.0 ?? .init(), isLearningEnabled: enabled)
            generation &+= 1
            resets &+= 1
        }
        if current.diagnostics != epochs.diagnostics {
            diagnostics = loaded?.1 ?? KeyboardDiagnostics()
        }
        epochs = current
        markChanged()
    }

    /// Writes now (keyboard disappearing, memory warning) after checking reset epochs again.
    func flush() {
        refresh()
        saveTask?.cancel()
        saveTask = nil
        guard dirty, isPersistent else { return }
        guard allowsPersistence() else {
            stopPersistence()
            return
        }
        if model.prepareForSave() {
            diagnostics.increment(.storeWriteFailed)
            generation &+= 1
        }
        // The store posts the change notification after a successful write.
        if store.save(model: model.state, diagnostics: &diagnostics) {
            dirty = false
        } else if !store.isPersistent {
            // Write failed (counted by the store): keep this session in RAM rather than retrying.
            stopPersistence()
        }
        // A reset raced the save: the next refresh reloads, and the next flush saves again.
    }

    /// Full Access went away or the store failed to load: keep learning in RAM only.
    func stopPersistence() {
        breakWordSequence()
        feedbackEpoch &+= 1
        saveTask?.cancel()
        saveTask = nil
        pendingLoad = nil
        guard isPersistent else { return }
        isPersistent = false
        store = KeyboardLearningStore(directory: nil, defaults: defaults)
    }

    // MARK: - Trusted events

    func increment(_ counter: KeyboardDiagnostics.Counter, by amount: Int = 1) {
        diagnostics.increment(counter, by: amount)
        markChanged()
    }

    func recordLatency(_ seconds: Double, kind: KeyboardDiagnostics.LatencyKind) {
        diagnostics.recordLatency(seconds, kind: kind)
        markChanged()
    }

    func keep(_ word: String) {
        guard model.keep(word) else { return }
        diagnostics.increment(.wordsKept)
        modelChanged()
    }

    func forgetKeep(_ word: String) {
        model.forgetKeep(word)
        modelChanged()
    }

    func forgetRejection(_ pair: RejectedCorrection) {
        model.forgetRejection(pair)
        modelChanged()
    }

    func recordWord(_ word: String) {
        guard model.recordWord(word) else { return }
        diagnostics.increment(.wordsCounted)
        modelChanged()
    }

    func confirmLiteral(_ word: String) {
        guard model.confirmLiteral(word) else { return }
        modelChanged()
    }

    func rejectCorrection(typed: String, replacement: String, context: String? = nil) {
        guard model.rejectCorrection(typed: typed, replacement: replacement, context: context) else { return }
        diagnostics.increment(.correctionsRejected)
        modelChanged()
    }

    var onValidatedLabel: ((TouchLabel, KeyboardLayout) -> Void)?
    var onLabelsInvalidated: (() -> Void)?

    func learn(_ labels: [TouchLabel], layout: KeyboardLayout, source: TouchLabelSource) {
        guard !labels.isEmpty else { return }
        let outcome = model.learn(labels, layout: layout, source: source, accepted: { [weak self] label in
            self?.onValidatedLabel?(label, layout)
        })
        diagnostics.recordLabels(outcome, source: source)
        if outcome.accepted > 0 { modelChanged() } else { markChanged() }
    }

    func learnSpace(_ point: CGPoint, layout: KeyboardLayout) {
        let outcome = model.learnSpace(point, layout: layout)
        diagnostics.recordLabels(outcome, source: .space)
        if outcome.accepted > 0 { modelChanged() } else { markChanged() }
    }

    func recordRejection(_ reason: TouchLabelRejection, count: Int) {
        guard count > 0 else { return }
        diagnostics.recordRejection(reason, count: count)
        markChanged()
    }

    // MARK: - Debounced save

    private func modelChanged() {
        generation &+= 1
        markChanged()
    }

    private func markChanged() {
        dirty = true
        guard isPersistent else { return }
        lastChange = .now
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in await self?.saveWhenIdle() }
    }

    /// Saves at least `debounce` after the last change, never per keystroke.
    private func saveWhenIdle() async {
        while true {
            let due = lastChange.advanced(by: debounce)
            guard ContinuousClock.now < due else { break }
            do { try await Task.sleep(until: due, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
        }
        saveTask = nil
        flush()
    }
}
