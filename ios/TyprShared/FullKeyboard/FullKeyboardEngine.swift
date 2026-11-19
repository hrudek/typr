import QuartzCore
import UIKit

/// The text field the keys type into. `UITextDocumentProxy` in the keyboard; a fake in tests.
@MainActor
protocol KeyboardTextTarget: AnyObject {
    var documentContextBeforeInput: String? { get }
    var hasText: Bool { get }
    var autocapitalizationType: UITextAutocapitalizationType? { get }
    var autocorrectionType: UITextAutocorrectionType? { get }
    var isSecureTextEntry: Bool? { get }
    var keyboardType: UIKeyboardType? { get }
    var inlinePredictionType: UITextInlinePredictionType? { get }
    var returnKeyType: UIReturnKeyType? { get }
    var enablesReturnKeyAutomatically: Bool? { get }
    var keyboardAppearance: UIKeyboardAppearance? { get }
    func insertText(_ text: String)
    func deleteBackward()
    func adjustTextPosition(byCharacterOffset offset: Int)
}

extension KeyboardTextTarget {
    var autocorrectionType: UITextAutocorrectionType? { .default }
    var isSecureTextEntry: Bool? { false }
    var inlinePredictionType: UITextInlinePredictionType? { .default }
    var enablesReturnKeyAutomatically: Bool? { false }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
}

@MainActor
final class DocumentProxyTextTarget: KeyboardTextTarget {
    private let proxy: () -> UITextDocumentProxy

    init(_ proxy: @escaping () -> UITextDocumentProxy) {
        self.proxy = proxy
    }

    var documentContextBeforeInput: String? { proxy().documentContextBeforeInput }
    var hasText: Bool { proxy().hasText }
    var autocapitalizationType: UITextAutocapitalizationType? { proxy().autocapitalizationType }
    var autocorrectionType: UITextAutocorrectionType? { proxy().autocorrectionType }
    var isSecureTextEntry: Bool? { proxy().isSecureTextEntry }
    var keyboardType: UIKeyboardType? { proxy().keyboardType }
    var inlinePredictionType: UITextInlinePredictionType? { proxy().inlinePredictionType }
    var returnKeyType: UIReturnKeyType? { proxy().returnKeyType }
    var enablesReturnKeyAutomatically: Bool? { proxy().enablesReturnKeyAutomatically }
    var keyboardAppearance: UIKeyboardAppearance? { proxy().keyboardAppearance }
    func insertText(_ text: String) { proxy().insertText(text) }
    func deleteBackward() { proxy().deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { proxy().adjustTextPosition(byCharacterOffset: offset) }
}

/// Everything the keys do, apart from drawing: multitouch with rollover, shift, pages,
/// long-press accents, spacebar cursor trackpad, cautious autocorrect, double-space period,
/// auto-capitalization and accelerating delete. Touches are identified by any stable integer
/// so tests can drive it without `UITouch`.
@MainActor
final class FullKeyboardEngine {
    struct ActiveTouch: Equatable {
        var key: KeyboardKey
        var startPoint: CGPoint
        var point: CGPoint
        /// Captured geometry; layout changes and key-to-key slides make evidence ambiguous.
        var evidenceLayout: KeyboardLayout
        var hasUnambiguousPoint = true
        /// A character that already went in because another key went down after it.
        var committed: Bool
        /// The page a 123/ABC press came from; releasing over a character returns there.
        var returnLayer: KeyboardLayer?
        /// True once a spacebar press crosses `trackpadActivationDistance`.
        var isTrackpad = false
        var trackpadAnchorX: CGFloat = 0
        /// Samples of a letter press that may still become a swipe; nil once it cannot.
        var swipePath: [SwipePoint]?
        /// Crossed `swipeActivation`: no key, preview or accent menu any more; a word on release.
        var isSwipe = false
    }

    /// The word a swipe inserted, its cased alternatives and the context right after it. While the
    /// context is unchanged, the strip offers the alternatives, Delete removes the whole word and
    /// Space/punctuation leave it alone (never autocorrected, never learned).
    struct SwipeWord: Equatable {
        var inserted: String
        let words: [String]
        var context: String?
    }

    static let accentHoldDelay: TimeInterval = 0.40
    static let accentSlop: CGFloat = 10
    static let nextKeyboardHoldDelay: TimeInterval = 0.5
    static let trackpadActivationDistance: CGFloat = 10
    static let trackpadPointsPerCharacter: CGFloat = 7.5
    /// A letter press becomes a swipe after travelling this many letter widths (iikb: 0.8):
    /// beyond a slipped tap, short of a deliberate slide.
    static let swipeActivation: CGFloat = 0.8
    /// Coalesced samples of one swipe; older halves are thinned beyond this.
    static let swipePathLimit = 1_024

    private(set) var shift = ShiftStateMachine()
    private(set) var layerState = KeyboardLayerState()
    private(set) var field: KeyboardFieldKind = .text
    private(set) var touches: [Int: ActiveTouch] = [:]
    /// Touch ids in the order they went down.
    private var touchOrder: [Int] = []
    private var lastSpaceAt: TimeInterval?

    private(set) var activeAccentMenu: AccentMenu?
    private var activeAccentTouchID: Int?
    /// The active swipe's points for the trail; empty when none. RAM-only, cleared on release.
    private(set) var swipeTrail: [CGPoint] = []
    private(set) var swipeWord: SwipeWord?
    /// Bumped by anything that makes a decoding swipe stale (new touch, text/field/layout change).
    private var swipeGeneration: UInt64 = 0
    private var swipeTask: Task<Void, Never>?
    private let swipeDecoder: SwipeDecoding
    private(set) var suggestions: [KeyboardSuggestion] = []
    private let suggestionWorker: KeyboardSuggestionWorker
    /// Optional model next words, merged into the count-based predictions for the same context.
    var modelPredictions: ModelPredictionSession?
    private let suggestionEngineID = UUID()
    private var textRevision: UInt64 = 0
    private(set) var suggestionsAreActive = true
    /// What the strip currently shows: its ownership, the taps it was ranked from and whether
    /// it is a finished ranking (not the interim literal chips).
    private struct PublishedStrip {
        let ownership: KeyboardSuggestionOwnership
        let evidence: KeyboardTouchWord?
        let final: Bool
    }
    private var published: PublishedStrip?
    private var attribution: (ownership: KeyboardSuggestionOwnership, map: KeyboardKeyMap)?
    static let suggestionContextLimit = 256
    static let suggestionContextUTF8Limit = 2_048
    private static let suggestionTokenLimit = 64

    /// Bounded RAM-only ownership, also checked at chip acceptance before any edit/learning.
    var suggestionOwnership: KeyboardSuggestionOwnership {
        let context = target.documentContextBeforeInput.flatMap(Self.boundedSuggestionContext)
        let token = AutocorrectEngine.currentToken(in: context)
        let route = KeyboardFieldRouting.route(for: target.keyboardType)
        let prose: Bool
        if case .keys(.text, _) = route { prose = true } else { prose = false }
        return .init(engine: suggestionEngineID, revision: textRevision, context: context,
                     token: token, field: field,
                     permitsCorrection: prose && target.autocorrectionType != .no && target.isSecureTextEntry != true,
                     configuration: autocorrect.suggestionConfiguration,
                     learning: autocorrect.learning.generation, feedbackEpoch: autocorrect.learning.feedbackEpoch,
                     resources: autocorrect.spatialDecoder?.resourceRevision ?? -1, layout: layout)
    }

    /// The longest whole-character suffix within 256 characters and 2,048 UTF-8 bytes, so
    /// emoji/ZWJ-heavy text still yields the current word. Nil only if the last character alone
    /// exceeds the byte cap (then it is no word token anyway).
    static func boundedSuggestionContext(_ before: String) -> String? {
        var start = before.endIndex
        var characters = 0
        var bytes = 0
        while start > before.startIndex, characters < suggestionContextLimit {
            let previous = before.index(before: start)
            let size = before[previous..<start].utf8.count
            guard bytes + size <= suggestionContextUTF8Limit else { break }
            bytes += size
            characters += 1
            start = previous
        }
        guard start < before.endIndex || before.isEmpty else { return nil }
        return String(before[start...])
    }

    let target: KeyboardTextTarget
    let autocorrect: AutocorrectEngine
    let statistics: UsageStatisticsSession?
    let typingLog: TypingLogRecorder?
    // Bounded RAM-only ownership, discarded with the engine; never sent to the store.
    private var statisticsContext: String?
    private var statisticsSessionRevision: UInt64?
    private func prepareStatisticsEdit() {
        guard statistics != nil else { return }
        let context = target.documentContextBeforeInput.flatMap(Self.boundedSuggestionContext)
        if context == nil || context != statisticsContext || statisticsSessionRevision != statistics?.sessionRevision {
            endStatisticsSession()
            if let last = context?.last,
               last.isLetter || last.isNumber || ["'", "’", "-"].contains(last) {
                statistics?.ignoreOpenWord()
            }
        }
    }
    func endStatisticsSession() {
        statisticsContext = nil
        statistics?.endSession()
    }
    var width: CGFloat = 375 { didSet { if width != oldValue { rebuildLayout() } } }
    var orientation: KeyboardOrientation = .portrait { didSet { if orientation != oldValue { rebuildLayout() } } }
    var showsGlobe = false { didSet { if showsGlobe != oldValue { rebuildLayout() } } }
    var globeKey = GlobeKey.switches { didSet { if globeKey != oldValue { rebuildLayout() } } }
    var bottomRow = BottomRow() { didSet { if bottomRow != oldValue { rebuildLayout() } } }
    var numberRow = false { didSet { if numberRow != oldValue { rebuildLayout() } } }
    var horizontalInset: CGFloat = 0 { didSet { if horizontalInset != oldValue { rebuildLayout() } } }
    /// Typr: without the suggestion bar the keys move up and no suggestions are computed.
    var showsStrip = true {
        didSet {
            guard showsStrip != oldValue else { return }
            rebuildLayout()
            refreshSuggestions()
        }
    }
    private(set) var layout = KeyboardLayout(width: 375)
    /// Typr: the swipe typing switch. Off drops any pending decode; sliding keeps slide-to-key.
    var swipeTypingEnabled = true {
        didSet { if !swipeTypingEnabled { cancelPendingSwipe() } }
    }

    var clock: () -> TimeInterval = { CACurrentMediaTime() }
    /// Runs `action` once after `delay` seconds on the main actor.
    var scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
    }
    /// The next Delete restores the last automatic correction; the delete key shows undo.
    private(set) var deleteUndoes = false
    private var undoRedrawAt: TimeInterval?
    /// Called whenever something visible changed (page, shift, pressed keys, suggestions, accents).
    var onChange: (() -> Void)?
    /// Called after the keys typed or deleted anything.
    var onEdit: (() -> Void)?
    /// Called when an accent cell or spacebar trackpad step ticks, for selection haptics.
    var onSelectionStep: (() -> Void)?

    init(target: KeyboardTextTarget, autocorrect: AutocorrectEngine? = nil,
         suggestionWorker: KeyboardSuggestionWorker? = nil,
         statistics: UsageStatisticsSession? = nil,
         typingLog: TypingLogRecorder? = nil,
         swipeDecoder: SwipeDecoding? = nil) {
        self.statistics = statistics
        self.typingLog = typingLog
        self.swipeDecoder = swipeDecoder ?? { await SwipeRecognizer.shared.decode($0) }
        self.target = target
        self.autocorrect = autocorrect ?? AutocorrectEngine()
        self.suggestionWorker = suggestionWorker ?? KeyboardSuggestionWorker()
        rebuildLayout()
    }

    var isUppercase: Bool { layerState.layer == .letters && shift.isUppercase }

    var isTrackpadActive: Bool {
        touches.values.contains(where: \.isTrackpad)
    }

    /// The key whose balloon shows: the newest character still held (hidden while an accent menu is up).
    var previewKey: KeyboardKey? {
        guard activeAccentMenu == nil else { return nil }
        for id in touchOrder.reversed() {
            if let touch = touches[id], touch.key.character != nil, !touch.committed, !touch.isSwipe {
                return touch.key
            }
        }
        return nil
    }

    var pressedKinds: Set<KeyKind> {
        Set(touches.values.filter { !$0.isSwipe }.map(\.key.kind))
    }

    func displayLabel(for key: KeyboardKey) -> String {
        guard let character = key.character else { return key.label }
        return isUppercase && layerState.layer == .letters ? character.uppercased() : character
    }

    // MARK: - Field

    /// Call when the keyboard appears or the field changes.
    func configureForField() {
        endTypingLogWord("field")
        statistics?.refreshGeneration()
        endStatisticsSession()
        suggestionsAreActive = true
        autocorrect.contextResources.prepare { [weak self] in self?.refreshSuggestions() }
        switch KeyboardFieldRouting.route(for: target.keyboardType) {
        case .keys(let kind, let initialLayer):
            field = kind
            layerState.reset(to: initialLayer)
        case .handOff:
            field = .text
            layerState.reset(to: .numbers)
        }
        shift.reset()
        lastSpaceAt = nil
        autocorrect.clearPendingUndo()
        refreshDeleteUndo()
        cancelAllTouches(republishing: false)
        autocorrect.touchInput.clearAtBoundary()
        rebuildLayout()
        refreshAutoCapitalization()
        refreshSuggestions()
    }

    /// Call after the text or the cursor changed outside these keys.
    func textDidChange() {
        endTypingLogWord("external")
        endStatisticsSession()
        invalidateTouchEvidence()
        lastSpaceAt = nil
        autocorrect.clearPendingUndo()
        refreshDeleteUndo()
        refreshAutoCapitalization()
        refreshSuggestions()
    }

    /// Invalidates in-flight taps too: a late release must not recreate evidence after a cursor/field change.
    /// Chips are owned by text revision and layout, so current-word chips (now without taps) are
    /// republished rather than leaving the strip blank (layer switch, rebuild, key slide, cursor move).
    func discardTouchEvidence() {
        invalidateTouchEvidence()
        refreshSuggestions()
    }

    /// For callers that refresh right afterwards anyway. Applied manual choices clear the
    /// word without ending the trusted word sequence.
    private func invalidateTouchEvidence(endsWordSequence: Bool = true) {
        textRevision &+= 1
        suggestionWorker.cancel()
        cancelPendingSwipe()
        swipeWord = nil
        autocorrect.discardEvidence(endsWordSequence: endsWordSequence)
        for id in touchOrder {
            touches[id]?.hasUnambiguousPoint = false
        }
    }

    func refreshAutoCapitalization() {
        let before = shift
        shift.refreshAutoCapitalization(
            AutoCapitalization.shouldCapitalize(
                mode: AutoCapitalization.Mode(target.autocapitalizationType),
                before: target.documentContextBeforeInput,
                hasText: target.hasText
            )
        )
        if shift != before { onChange?() }
    }

    func refreshSuggestions() {
        guard suggestionsAreActive else { return }
        textRevision &+= 1
        // No ranking/decoder/checker or vocabulary scan. Attribution may lazily prepare
        // the bounded personal snapshot after trusted-word changes.
        let evidence = autocorrect.touchInput.evidence(beforeInput: target.documentContextBeforeInput)
        let ownership = suggestionOwnership
        modelPredictions?.keep(only: ModelPredictionRequest(before: ownership.context))
        // Current before returning to the event loop, independent of strip/worker readiness.
        attribution = autocorrect.keyMap(layout: layout, context: ownership.context,
                                        permitsCorrection: ownership.permitsCorrection).map { (ownership, $0) }
        if swipeWord?.context != ownership.context { swipeWord = nil }
        if let swipeWord, showsStrip {
            suggestionWorker.cancel()
            publishSuggestions(swipeChips(swipeWord, ownership: ownership), ownership: ownership,
                               evidence: nil, final: true)
            return
        }
        // No current word: only corpus next-word predictions after a separator (no tap evidence).
        guard showsStrip, field == .text, ownership.permitsCorrection,
              ownership.token.map({ $0.count <= Self.suggestionTokenLimit && $0.utf8.count <= 256 })
                ?? autocorrect.canPredictNextWord(after: ownership.context) else {
            suggestionWorker.cancel()
            publishSuggestions([], ownership: ownership, evidence: evidence, final: true)
            return
        }
        if let published, published.final, published.evidence == evidence,
           published.ownership.hasSameContent(as: ownership), !suggestions.contains(where: \.isSwipe) {
            // Same word, taps and configuration (warmup, poll, remount): keep the finished
            // ranking without flicker, re-owned by this revision while the checker step reruns.
            publishSuggestions(suggestions.map { var owned = $0; owned.ownership = ownership; return owned },
                               ownership: ownership, evidence: evidence, final: true)
        } else if let token = ownership.token {
            // Clear old alternatives immediately. The current literal is safe and remains pickable
            // while ranking is delayed, including during rapid rollover or after undo.
            publishSuggestions([
                .init(displayText: "“\(token)”", replacement: token, kind: .keepLiteral, ownership: ownership),
                .init(displayText: token, replacement: token, kind: .primary(autoReplace: false), ownership: ownership)
            ], ownership: ownership, evidence: evidence, final: false)
        } else {
            // Never leave the previous word's chips pickable while predictions are prepared.
            publishSuggestions([], ownership: ownership, evidence: evidence, final: false)
        }
        suggestionWorker.submit(prepare: { [weak self] in
            guard let self, self.textRevision == ownership.revision,
                  self.suggestionsAreActive, self.suggestionOwnership == ownership else { return nil }
            return self.autocorrect.suggestionRequest(ownership: ownership, evidence: evidence)
        }, finish: { [weak self] result in
            // Revision first: do not even read a torn-down document proxy after dismissal.
            guard let self, self.textRevision == ownership.revision,
                  result.request.ownership == ownership,
                  self.suggestionOwnership == ownership, self.showsStrip else { return }
            let next = self.ownedSuggestions(self.autocorrect.finishSuggestions(result), ownership: ownership)
            self.publishSuggestions(next, ownership: ownership, evidence: evidence, final: true)
            if ownership.token == nil { self.addModelPredictions(to: next, ownership: ownership, evidence: evidence) }
        })
    }

    private func ownedSuggestions(_ suggestions: [KeyboardSuggestion],
                                  ownership: KeyboardSuggestionOwnership) -> [KeyboardSuggestion] {
        suggestions.map { suggestion in
            // After-space predictions show (and insert) the host's auto-capitalization.
            var owned = ownership.token == nil ? casedPrediction(suggestion, before: ownership.context) : suggestion
            owned.ownership = ownership
            return owned
        }
    }

    private func addModelPredictions(to counted: [KeyboardSuggestion], ownership: KeyboardSuggestionOwnership,
                                     evidence: KeyboardTouchWord?) {
        guard let modelPredictions, target.inlinePredictionType != .no,
              target.keyboardType != .numbersAndPunctuation,
              let request = ModelPredictionRequest(before: ownership.context) else { return }
        if let words = modelPredictions.words(for: request) {
            publishModelPredictions(words, counted: counted, ownership: ownership, evidence: evidence)
            return
        }
        modelPredictions.request(request) { [weak self] words in
            guard let self, self.textRevision == ownership.revision, self.suggestionsAreActive,
                  self.showsStrip, self.suggestionOwnership == ownership else { return }
            self.publishModelPredictions(words, counted: counted, ownership: ownership, evidence: evidence)
        }
    }

    private func publishModelPredictions(_ words: [String], counted: [KeyboardSuggestion],
                                         ownership: KeyboardSuggestionOwnership, evidence: KeyboardTouchWord?) {
        publishSuggestions(ownedSuggestions(ModelPredictionSession.merge(words, into: counted), ownership: ownership),
                           ownership: ownership, evidence: evidence, final: true)
    }

    private func publishSuggestions(_ next: [KeyboardSuggestion], ownership: KeyboardSuggestionOwnership?,
                                    evidence: KeyboardTouchWord?, final: Bool) {
        published = ownership.map { PublishedStrip(ownership: $0, evidence: evidence, final: final) }
        guard next != suggestions else { return }
        suggestions = next
        onChange?()
    }

    /// Settings poll: learning loads/resets/switch, resource installation or a host context
    /// change without callback can make the shown chips unacceptable. Republish only then.
    func refreshSuggestionsIfStale() {
        guard suggestionsAreActive, let published,
              !published.ownership.hasSameContent(as: suggestionOwnership) else { return }
        refreshSuggestions()
    }

    func cancelSuggestions() {
        textRevision &+= 1
        suggestionWorker.cancel()
        modelPredictions?.cancel()
        publishSuggestions([], ownership: nil, evidence: nil, final: false)
    }

    func suspendSuggestions() {
        suggestionsAreActive = false
        cancelSuggestions()
    }

    /// Host activation or a keyboard touch: re-enable and refresh without touching layer, shift,
    /// undo, touches or menus (unlike `configureForField`).
    func resumeSuggestions() {
        suggestionsAreActive = true
        refreshSuggestions()
    }

    func waitForSuggestions() async { await suggestionWorker.waitUntilIdle() }

    func acceptSuggestion(_ suggestion: KeyboardSuggestion) {
        autocorrect.forgetSpaceTaps()
        if suggestion.isSwipe {
            replaceSwipeWord(with: suggestion)
            return
        }
        autocorrect.syncLearning()
        guard let ownership = suggestion.ownership,
              ownership.revision == textRevision, ownership == suggestionOwnership,
              showsStrip, field == .text, ownership.permitsCorrection else {
            // Refused (e.g. the sync above consumed a learning load/reset): replace the dead chips
            // so the next tap works. Bounded: one refresh, no re-entry into acceptance.
            refreshSuggestions()
            return
        }
        // Capture the word's taps before invalidating them: an explicit choice may teach Typr.
        let before = target.documentContextBeforeInput
        let evidence = autocorrect.touchInput.evidence(beforeInput: before)
        let token = AutocorrectEngine.currentToken(in: before)
        // Boundary chips own an exact bounded suffix, not just the current token. Ownership
        // above includes the entire captured context/revision; recheck the actual proxy suffix too.
        let original = suggestion.boundary?.original ?? token
        if suggestion.boundary != nil {
            guard let original, before?.hasSuffix(original) == true else { return }
        }
        let keepWasNew = token.map { !autocorrect.learning.protections.kept.contains(PersonalLexiconSnapshot.normalize($0)) } ?? false
        if let token {
            autocorrect.recordSuggestionFeedback(suggestion, literal: token, evidence: evidence)
        } else {
            // Explicit picks are word evidence, never touch-label evidence.
            let word = casedPrediction(suggestion, before: before).replacement
            autocorrect.recordPredictionFeedback(word, beforeInput: before)
        }
        // Idempotent with the published chip: a prediction at a sentence start is capitalized.
        let replacement = token == nil && suggestion.boundary == nil
            ? casedPrediction(suggestion, before: before).replacement : suggestion.replacement
        prepareStatisticsEdit()
        statistics?.suggestion(replacement, boundaryOriginal: suggestion.boundary?.original)
        invalidateTouchEvidence(endsWordSequence: false)
        if let original {
            for _ in 0..<original.count {
                target.deleteBackward()
            }
        }
        autocorrect.clearPendingUndo()
        insert(replacement + " ", keepsFeedback: suggestion.boundary == nil)
        logTyping { log in
            if let original {
                log.picked(from: original, to: replacement, chip: Self.chipName(suggestion.kind),
                           boundary: suggestion.boundary != nil)
            } else { log.end("prediction") }
        }
        if let boundary = suggestion.boundary {
            autocorrect.recordAppliedBoundary(boundary, replacement: suggestion.replacement, at: clock())
        } else if suggestion.kind == .keepLiteral, let token {
            autocorrect.recordAppliedKeep(token, wasNew: keepWasNew, at: clock())
        }
        refreshDeleteUndo()
        // The suggestion's separator counts as the first space of double-space period.
        lastSpaceAt = clock()
    }

    /// Host auto-capitalization for a next-word prediction: first letter after `. ! ?`, a line
    /// break or at the field start (sentences/words modes), every letter for all-characters.
    /// Never lowercases, so dictionary-cased German nouns and names keep their capitals.
    static func casedPrediction(_ word: String, mode: AutoCapitalization.Mode, before: String?, hasText: Bool) -> String {
        guard AutoCapitalization.shouldCapitalize(mode: mode, before: before, hasText: hasText) else { return word }
        return mode == .allCharacters ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
    }

    private func casedPrediction(_ suggestion: KeyboardSuggestion, before: String?) -> KeyboardSuggestion {
        guard suggestion.boundary == nil else { return suggestion } // Owns an exact original suffix.
        let mode = AutoCapitalization.Mode(target.autocapitalizationType)
        let replacement = Self.casedPrediction(suggestion.replacement, mode: mode, before: before, hasText: target.hasText)
        guard replacement != suggestion.replacement else { return suggestion }
        var cased = KeyboardSuggestion(
            displayText: Self.casedPrediction(suggestion.displayText, mode: mode, before: before, hasText: target.hasText),
            replacement: replacement, kind: suggestion.kind, isCompletion: suggestion.isCompletion)
        cased.ownership = suggestion.ownership
        cased.isPersonal = suggestion.isPersonal
        return cased
    }

    // MARK: - Touches

    /// `time`: the touch's own timestamp (same clock as `clock`), for swipe sampling.
    func touchBegan(id: Int, at point: CGPoint, time: TimeInterval? = nil) {
        guard let key = layout.hitTest(point) else { return }
        // A touch proves the keyboard is visible, even if a host activation notice was missed.
        if !suggestionsAreActive { resumeSuggestions() }
        // A swipe still decoding would land after this key's text: drop it instead.
        cancelPendingSwipe()
        // Rollover: commit a held character or real Space before the next key. Space
        // keeps its last observed point, never a fabricated key centre.
        for other in touchOrder {
            guard var touch = touches[other], !touch.committed else { continue }
            if touch.isSwipe {
                // A second finger ends a swipe without a word; it is not a held letter.
                touch.isSwipe = false
                touch.swipePath = nil
                swipeTrail = []
            } else if touch.key.kind == .space, !touch.isTrackpad {
                let sample: KeyboardTouchWord.Sample? = touch.hasUnambiguousPoint && touch.evidenceLayout == layout
                    ? .init(text: " ", point: touch.point, key: touch.key) : nil
                typeSpace(sample: sample)
            } else if touch.key.character == nil {
                continue
            } else if activeAccentTouchID == other, let menu = activeAccentMenu {
                commitAccentSelection(menu.selectedOption)
                activeAccentMenu = nil
                activeAccentTouchID = nil
            } else {
                commitCharacter(touch, recordsHeat: false)
            }
            touch.committed = true
            touch.swipePath = nil
            touches[other] = touch
        }

        var touch = ActiveTouch(
            key: key,
            startPoint: point,
            point: point,
            evidenceLayout: layout,
            committed: false,
            returnLayer: nil
        )
        if swipeIsAvailable, let letter = key.character, letter.count == 1,
           letter.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) {
            touch.swipePath = [SwipePoint(x: point.x, y: point.y, time: time ?? clock())]
        }
        switch key.kind {
        case .shift:
            shift.shiftDown(now: clock())
        case .delete:
            deleteBackward(allowAutocorrectUndo: true)
        case .layerSwitch(let next):
            touch.returnLayer = layerState.layer
            layerState.switchTo(next)
            if next == .letters { shift.reset() }
            rebuildLayout()
            if next == .letters { refreshAutoCapitalization() }
        case .character, .space, .returnKey, .typr, .globe, .globeSpacer:
            break
        }
        touches[id] = touch
        touchOrder.append(id)
        onChange?()
    }

    @discardableResult
    func openAccentMenuIfEligible(forTouch id: Int) -> Bool {
        guard activeAccentMenu == nil,
              let touch = touches[id],
              !touch.committed, !touch.isSwipe,
              let base = touch.key.character else { return false }
        let dx = touch.point.x - touch.startPoint.x
        let dy = touch.point.y - touch.startPoint.y
        guard (dx * dx + dy * dy).squareRoot() <= Self.accentSlop else { return false }
        let options: [String]? = layout.isPeriodKey(touch.key)
            ? AccentCatalog.periodKey
            : AccentCatalog.options(for: base, uppercase: isUppercase)
        guard let options, options.count > 1 else { return false }
        activeAccentMenu = AccentMenu.build(
            for: touch.key.frame,
            rawOptions: options,
            in: layout.width,
            horizontalInset: layout.horizontalInset
        )
        activeAccentTouchID = id
        onChange?()
        return true
    }

    /// `samples`: the coalesced points since the last call (ending at `point`) with their timestamps.
    func touchMoved(id: Int, to point: CGPoint, samples: [(point: CGPoint, time: TimeInterval)] = []) {
        guard var touch = touches[id] else { return }
        touch.point = point
        let wasSwipe = touch.isSwipe
        if activeAccentTouchID != id, !touch.committed, touch.swipePath != nil,
           trackSwipe(&touch, samples: samples.isEmpty ? [(point, clock())] : samples) {
            touches[id] = touch
            // Only activation changes keys and preview; the trail itself is read by the plane view.
            if !wasSwipe { onChange?() }
            return
        }

        // 1. Active long-press accent picker: horizontal drag selects the alternate character.
        if activeAccentTouchID == id, var menu = activeAccentMenu {
            let nextIndex = menu.index(for: point.x)
            touches[id] = touch
            if nextIndex != menu.selectedIndex {
                menu.selectedIndex = nextIndex
                activeAccentMenu = menu
                onSelectionStep?()
                onChange?()
            }
            return
        }

        // 2. Spacebar cursor trackpad: horizontal drag >= 10 pt slides the text caret.
        if touch.key.kind == .space, !touch.committed {
            if !touch.isTrackpad, abs(point.x - touch.startPoint.x) >= Self.trackpadActivationDistance {
                discardTouchEvidence()
                endTypingLogWord("cursor")
                touch.isTrackpad = true
                touch.trackpadAnchorX = point.x
                endStatisticsSession()
                lastSpaceAt = nil
                autocorrect.clearPendingUndo()
                touches[id] = touch
                refreshDeleteUndo()
                onSelectionStep?()
                onChange?()
                return
            }
            if touch.isTrackpad {
                let delta = point.x - touch.trackpadAnchorX
                let rawSteps = Int((delta / Self.trackpadPointsPerCharacter).rounded(.towardZero))
                if rawSteps != 0 {
                    touch.trackpadAnchorX += CGFloat(rawSteps) * Self.trackpadPointsPerCharacter
                    touches[id] = touch
                    target.adjustTextPosition(byCharacterOffset: rawSteps)
                    onSelectionStep?()
                    refreshAutoCapitalization()
                    refreshSuggestions()
                    return
                }
                touches[id] = touch
                return
            }
        }

        // 3. Sliding across character keys updates the active key and re-anchors the hold timer.
        if touch.key.character != nil, !touch.committed,
           let under = layout.hitTest(point), under.character != nil, under.kind != touch.key.kind {
            touch.hasUnambiguousPoint = false
            discardTouchEvidence()
            touch.key = under
            touch.startPoint = point
            touches[id] = touch
            onChange?()
            return
        }
        touches[id] = touch
    }

    func touchEnded(id: Int, at point: CGPoint) {
        guard var touch = touches.removeValue(forKey: id) else { return }
        touchOrder.removeAll { $0 == id }
        touch.point = point
        if touch.isSwipe {
            let last = touch.swipePath?.last?.time ?? 0
            touch.swipePath?.append(SwipePoint(x: point.x, y: point.y, time: max(clock(), last)))
            finishSwipe(touch)
            onChange?()
            return
        }

        if activeAccentTouchID == id, let menu = activeAccentMenu {
            let index = menu.index(for: point.x)
            let chosen = menu.options[index]
            activeAccentMenu = nil
            activeAccentTouchID = nil
            if !touch.committed {
                commitAccentSelection(chosen)
            }
            onChange?()
            return
        }

        switch touch.key.kind {
        case .character:
            if !touch.committed {
                commitCharacter(touch)
            }
        case .shift:
            shift.shiftUp()
        case .space:
            if !touch.isTrackpad, !touch.committed {
                let sample: KeyboardTouchWord.Sample? = touch.hasUnambiguousPoint && touch.evidenceLayout == layout
                    ? .init(text: " ", point: touch.point, key: touch.key) : nil
                typeSpace(sample: sample)
            }
        case .returnKey:
            if target.enablesReturnKeyAutomatically == true && !target.hasText {
                break
            }
            autocorrect.clearPendingUndo()
            // Return never autocorrects or settles learning.
            autocorrect.discardFeedback()
            prepareStatisticsEdit()
            statistics?.direct("\n")
            insert("\n")
            logTyping { $0.boundary("\n") }
        case .layerSwitch:
            // Hold 123, slide to a key, let go: type it and go back.
            if let returnLayer = touch.returnLayer,
               let under = layout.hitTest(point),
               let character = under.character,
               under.kind != touch.key.kind {
                autocorrect.clearPendingUndo()
                typeCharacter(character)
                layerState.switchTo(returnLayer)
                rebuildLayout()
                refreshAutoCapitalization()
            }
        case .delete, .typr, .globe, .globeSpacer:
            break
        }
        onChange?()
    }

    /// A still hold on the bottom row's 123/ABC when `layout.layerKeyHoldSwitchesKeyboard`: goes back
    /// to the page the press left and drops the touch. True when the keyboard should switch.
    func takeNextKeyboardHold(forTouch id: Int) -> Bool {
        guard layout.layerKeyHoldSwitchesKeyboard,
              let touch = touches[id], !touch.committed,
              case .layerSwitch = touch.key.kind, touch.key.row == touch.evidenceLayout.bottomRowIndex else { return false }
        let dx = touch.point.x - touch.startPoint.x
        let dy = touch.point.y - touch.startPoint.y
        guard (dx * dx + dy * dy).squareRoot() <= Self.accentSlop else { return false }
        if let returnLayer = touch.returnLayer {
            layerState.switchTo(returnLayer)
            rebuildLayout()
        }
        touchCancelled(id: id)
        return true
    }

    func touchCancelled(id: Int) {
        if touches[id]?.isSwipe == true { swipeTrail = [] }
        discardTouchEvidence()
        if activeAccentTouchID == id {
            activeAccentMenu = nil
            activeAccentTouchID = nil
        }
        guard touches.removeValue(forKey: id) != nil else { return }
        touchOrder.removeAll { $0 == id }
        onChange?()
    }

    func cancelAllTouches() {
        cancelAllTouches(republishing: true)
    }

    private func cancelAllTouches(republishing: Bool) {
        if republishing { discardTouchEvidence() } else { invalidateTouchEvidence() }
        let hadTouches = !touches.isEmpty || activeAccentMenu != nil
        touches.removeAll()
        touchOrder.removeAll()
        swipeTrail = []
        activeAccentMenu = nil
        activeAccentTouchID = nil
        if shift.isHeld { shift.shiftUp() }
        if hadTouches { onChange?() }
    }

    // MARK: - Delete

    /// The delete key repeats after 360 ms, accelerates at 850 ms, and removes whole words after 1.4 s.
    static let repeatDelay: TimeInterval = 0.36
    static let repeatInterval: TimeInterval = 0.075
    static let fastRepeatAfter: TimeInterval = 0.85
    static let wordDeleteAfter: TimeInterval = 1.4

    func repeatDelete(heldFor: TimeInterval) {
        prepareStatisticsEdit()
        autocorrect.clearPendingUndo()
        if heldFor >= Self.wordDeleteAfter {
            deleteWordBackward()
        } else if heldFor >= Self.fastRepeatAfter {
            statistics?.deletion(removedGraphemes: 2)
            deleteBackward(allowAutocorrectUndo: false, recordsStatistics: false)
            deleteBackward(allowAutocorrectUndo: false, recordsStatistics: false)
        } else {
            deleteBackward(allowAutocorrectUndo: false)
        }
    }

    func deleteBackward(allowAutocorrectUndo: Bool = true, recordsStatistics: Bool = true) {
        prepareStatisticsEdit()
        autocorrect.forgetSpaceTaps()
        autocorrect.syncLearning()
        let beforeDeletion = target.documentContextBeforeInput
        if allowAutocorrectUndo, let swipe = ownedSwipeWord(before: beforeDeletion) {
            // Like other swipe keyboards: the first Delete after a swipe takes the whole word.
            if recordsStatistics { statistics?.deletion(wholeWord: true) }
            autocorrect.clearPendingUndo()
            autocorrect.discardFeedback()
            for _ in 0..<swipe.inserted.count { target.deleteBackward() }
            swipeWord = nil
            logTyping { $0.dropOpenWord() }
            autocorrect.touchInput.deletedBackward(before: nil, after: target.documentContextBeforeInput)
            lastSpaceAt = nil
            didEdit()
            return
        }
        if allowAutocorrectUndo,
           let undo = autocorrect.consumePendingUndo(at: clock()),
           let before = target.documentContextBeforeInput,
           before.hasSuffix(undo.insertedText) {
            if recordsStatistics { statistics?.deletion(undo: true) }
            for _ in 0..<undo.insertedText.count {
                target.deleteBackward()
            }
            target.insertText(undo.original)
            logTyping { $0.undone(original: undo.original, field: target.documentContextBeforeInput) }
            autocorrect.touchInput.clear()
            autocorrect.recordUndo(undo)
            autocorrect.touchInput.deletedBackward(before: nil, after: target.documentContextBeforeInput)
            lastSpaceAt = nil
            didEdit()
            return
        }
        autocorrect.clearPendingUndo()
        autocorrect.discardFeedback()
        if recordsStatistics { statistics?.deletion() }
        target.deleteBackward()
        logTyping { $0.deleted(field: target.documentContextBeforeInput) }
        autocorrect.touchInput.deletedBackward(before: beforeDeletion, after: target.documentContextBeforeInput)
        lastSpaceAt = nil
        didEdit()
    }

    func deleteWordBackward() {
        prepareStatisticsEdit()
        autocorrect.forgetSpaceTaps()
        autocorrect.discardFeedback()
        autocorrect.touchInput.clear()
        autocorrect.clearPendingUndo()
        guard let before = target.documentContextBeforeInput, !before.isEmpty else {
            deleteBackward(allowAutocorrectUndo: false)
            return
        }
        statistics?.deletion(wholeWord: true)
        typingLog?.discard()
        var count = 0
        var index = before.endIndex
        while index > before.startIndex, before[before.index(before: index)].isWhitespace {
            index = before.index(before: index)
            count += 1
        }
        while index > before.startIndex, !before[before.index(before: index)].isWhitespace {
            index = before.index(before: index)
            count += 1
        }
        for _ in 0..<max(1, count) {
            target.deleteBackward()
        }
        autocorrect.touchInput.deletedBackward(before: nil, after: target.documentContextBeforeInput)
        lastSpaceAt = nil
        didEdit()
    }

    // MARK: - Typing

    private func commitCharacter(_ touch: ActiveTouch, recordsHeat: Bool = true) {
        let key = touch.key
        guard let character = key.character else { return }
        var attributed = key
        // Rollover commits previous letters first; their didEdit already prepared this map.
        // Unreported context/model/config changes or invalidated held geometry stay literal.
        let current = suggestionOwnership
        let shiftedStart = shift.state != .locked && current.token == nil
        if touch.hasUnambiguousPoint, touch.evidenceLayout == layout, !shift.isUppercase || shiftedStart,
           !autocorrect.touchInput.attributionSuppressed,
           !autocorrect.protectsAttribution(prefix: current.token ?? "", letter: character),
           autocorrect.isEnabled, let attribution {
            if attribution.ownership == current {
                let prefix = PersonalLexiconSnapshot.normalize(current.token ?? "")
                attributed = attribution.map.attributedKey(at: touch.point, geometric: key, layout: layout,
                                                           prefix: prefix)
            }
        }
        let inserted = attributed.character ?? character
        let text = layerState.layer == .letters && shift.isUppercase ? inserted.uppercased() : inserted
        if recordsHeat, attributed == key, touch.hasUnambiguousPoint, touch.evidenceLayout == layout {
            statistics?.recordHeat(point: touch.point, layout: layout)
        }
        if attributed != key { autocorrect.learning.increment(.reattributedTaps) }
        if layerState.layer == .letters {
            shift.didType()
        }
        autocorrect.clearPendingUndo()
        if touch.hasUnambiguousPoint, touch.evidenceLayout == layout {
            typeCharacter(text, sample: .init(text: text, point: touch.point, key: key,
                                              attributedKey: attributed == key ? nil : attributed))
        } else {
            typeCharacter(text)
        }
    }

    /// Sentence punctuation is a word boundary too, including hold-123/slide input.
    private func typeCharacter(_ text: String, sample: KeyboardTouchWord.Sample? = nil) {
        prepareStatisticsEdit()
        guard [".", ",", "?", "!"].contains(text), field == .text else {
            statistics?.direct(text)
            let tapLayout = layout
            insert(text, sample: sample)
            logTyping { log in
                log.typed(text, point: sample?.point, key: sample?.key.character, layout: tapLayout,
                          time: clock(), field: target.documentContextBeforeInput)
            }
            return
        }
        autocorrect.forgetSpaceTaps()
        let before = target.documentContextBeforeInput
        // Remove one word separator, never indentation, a newline or multiple spaces.
        if let before, before.hasSuffix(" "),
           let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            target.deleteBackward()
            // This word was already committed; do not reconsider an explicit choice.
            statistics?.direct(text)
            insert(text)
            logTyping { $0.boundary(text) }
            return
        }
        // A swiped word is already a lexicon word chosen by its whole path: never autocorrected or learned.
        if ownedSwipeWord(before: before) != nil {
            autocorrect.discardFeedback()
            statistics?.direct(text)
            insert(text)
            logTyping { $0.boundary(text) }
            return
        }
        if let (original, replacement) = autocorrect.replacementOnSpace(
            beforeInput: target.documentContextBeforeInput,
            field: field,
            autocorrectionType: target.autocorrectionType
        ) {
            statistics?.direct(text, boundaryReplacement: replacement)
            for _ in 0..<original.count { target.deleteBackward() }
            target.insertText(replacement + text)
            logTyping { $0.boundary(text, replacement: replacement, correction: typingLogCorrection) }
            autocorrect.recordAppliedCorrection(original: original, insertedText: replacement + text, at: clock())
            autocorrect.discardFeedback()
            autocorrect.touchInput.clearAtBoundary()
            lastSpaceAt = nil
            layerState.didInsert(text)
            rebuildLayoutIfNeeded()
            didEdit()
        } else {
            statistics?.direct(text)
            insert(text)
            logTyping { $0.boundary(text) }
        }
    }

    private func commitAccentSelection(_ chosen: String) {
        if layerState.layer == .letters {
            shift.didType()
        }
        autocorrect.clearPendingUndo()
        typeCharacter(chosen)
    }

    /// Typr: a tap on the Typr key types a space, exactly like the space bar
    /// (autocorrect, double-space period).
    func typeSpaceFromTyprKey() {
        typeSpace()
        onChange?()
    }

    private func typeSpace(sample: KeyboardTouchWord.Sample? = nil) {
        prepareStatisticsEdit()
        if sample == nil { autocorrect.forgetSpaceTaps() }
        // Only an actual, unambiguous Space release can retain boundary geometry.
        // Typr/programmatic spaces deliberately call with nil.
        _ = autocorrect.touchInput.evidence(beforeInput: target.documentContextBeforeInput)
        // Reset only the attribution veto, not #123's retained real-Space window.
        defer { autocorrect.touchInput.resetAttributionSuppression() }
        // Preserve the predecessor only for a new word's boundary, never a second separator.
        // The unchanged real Space below retains geometry; corrected/second/Typr spaces clear it.
        let hasCurrentWord = AutocorrectEngine.currentToken(in: target.documentContextBeforeInput) != nil
        autocorrect.discardFeedback(preservingTrustedContext: hasCurrentWord)
        let now = clock()
        if DoubleSpacePeriod.shouldReplace(before: target.documentContextBeforeInput, lastSpaceAt: lastSpaceAt, now: now) {
            statistics?.direct(" ")
            autocorrect.touchInput.clear()
            autocorrect.forgetSpaceTaps()
            autocorrect.clearPendingUndo()
            target.deleteBackward()
            target.insertText(". ")
            logTyping { $0.boundary(" ") }
            lastSpaceAt = nil
            layerState.didInsert(" ")
            rebuildLayoutIfNeeded()
            didEdit()
            return
        }
        if ownedSwipeWord(before: target.documentContextBeforeInput) != nil {
            autocorrect.discardFeedback()
        } else if let (original, replacement) = autocorrect.replacementOnSpace(
            beforeInput: target.documentContextBeforeInput,
            field: field,
            autocorrectionType: target.autocorrectionType
        ) {
            statistics?.direct(" ", boundaryReplacement: replacement)
            for _ in 0..<original.count {
                target.deleteBackward()
            }
            let inserted = replacement + " "
            autocorrect.touchInput.clear()
            target.insertText(inserted)
            logTyping { $0.boundary(" ", replacement: replacement, correction: typingLogCorrection) }
            autocorrect.recordAppliedCorrection(original: original, insertedText: inserted, at: clock())
            if let sample {
                autocorrect.spaceTyped(at: sample.point, layout: layout, afterInput: target.documentContextBeforeInput)
            }
            lastSpaceAt = now
            layerState.didInsert(" ")
            rebuildLayoutIfNeeded()
            didEdit()
            return
        }
        autocorrect.clearPendingUndo()
        let calibration = sample == nil ? nil : autocorrect.learning.calibration(for: layout)
        if let sample, let asSpace = KeyboardBoundaryTouch.spaceDensity(sample.point, layout: layout,
                                                                        calibration: calibration) {
            let ambiguous = KeyboardBoundaryTouch.adjacentLetters(in: layout).contains { key in
                guard let density = KeyboardBoundaryTouch.letterDensity(sample.point, key: key, layout: layout,
                                                                         calibration: calibration) else { return false }
                return density > asSpace
            }
            // Do not teach the first fragment as an independently intended word while this
            // actual boundary tap is more consistent with a bottom-row letter.
            if ambiguous { autocorrect.discardFeedback() }
        }
        statistics?.direct(" ")
        let tapLayout = layout
        insert(" ", sample: sample, keepsFeedback: true)
        logTyping { $0.boundary(" ") }
        if let sample {
            autocorrect.spaceTyped(at: sample.point, layout: tapLayout, afterInput: target.documentContextBeforeInput)
        }
        lastSpaceAt = now
    }

    /// `keepsFeedback`: the boundary's own separator, which opened the pending word feedback.
    private func insert(_ text: String, sample: KeyboardTouchWord.Sample? = nil, keepsFeedback: Bool = false) {
        let before = target.documentContextBeforeInput
        target.insertText(text)
        if sample != nil, text.count == 1, text.first?.isLetter == true {
            autocorrect.settleFeedback(beforeInput: before, insertedLetter: text,
                                      afterInput: target.documentContextBeforeInput)
        } else if !keepsFeedback {
            autocorrect.discardFeedback()
            autocorrect.forgetSpaceTaps()
        }
        if let sample {
            autocorrect.touchInput.append(text: text, point: sample.point, key: sample.key,
                                         layout: layout, before: before, after: target.documentContextBeforeInput,
                                         attributedKey: sample.attributedKey)
        } else {
            autocorrect.touchInput.clear()
            if text.last?.isLetter != true { autocorrect.touchInput.clearAtBoundary() }
        }
        lastSpaceAt = nil
        layerState.didInsert(text)
        rebuildLayoutIfNeeded()
        didEdit()
    }

    private func didEdit() {
        statisticsContext = statistics == nil ? nil : target.documentContextBeforeInput.flatMap(Self.boundedSuggestionContext)
        statisticsSessionRevision = statistics?.sessionRevision
        refreshAutoCapitalization()
        // Keyboard-originated edits (including the Typr key) also lift a stale suspension.
        suggestionsAreActive = true
        refreshSuggestions()
        refreshDeleteUndo()
        onEdit?()
    }

    /// Redraws the delete key when undo starts or ends, including once when its window closes.
    func refreshDeleteUndo() {
        let undo = autocorrect.pendingUndo(at: clock()).flatMap { undo in
            target.documentContextBeforeInput?.hasSuffix(undo.correction.insertedText) == true ? undo : nil
        }
        if let closesAt = undo?.window.closesAt, undoRedrawAt != closesAt {
            undoRedrawAt = closesAt
            scheduleAfter(closesAt - clock()) { [weak self] in
                guard let self else { return }
                if undoRedrawAt == closesAt { undoRedrawAt = nil }
                refreshDeleteUndo()
            }
        }
        guard (undo != nil) != deleteUndoes else { return }
        deleteUndoes = undo != nil
        onChange?()
    }

    // MARK: - Swipe typing

    /// Records samples and activates the swipe once far enough. True while the touch is a swipe.
    private func trackSwipe(_ touch: inout ActiveTouch, samples: [(point: CGPoint, time: TimeInterval)]) -> Bool {
        guard var path = touch.swipePath, let origin = path.first else { return false }
        for sample in samples {
            path.append(SwipePoint(x: sample.point.x, y: sample.point.y, time: max(sample.time, path.last?.time ?? 0)))
        }
        if path.count > Self.swipePathLimit {
            // Thin the older half; the encoder resamples to 64 points anyway.
            let half = path.count / 2
            path = path[..<half].enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) + path[half...]
        }
        touch.swipePath = path
        if !touch.isSwipe {
            let dx = touch.point.x - origin.x, dy = touch.point.y - origin.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.swipeActivation * layout.letterWidth,
                  touch.evidenceLayout == layout, swipeIsAvailable else { return false }
            touch.isSwipe = true
            swipeTrail = path.map { CGPoint(x: $0.x, y: $0.y) }
            // Earlier taps of this word no longer describe what is typed next.
            autocorrect.touchInput.clear()
            return true
        }
        swipeTrail.append(contentsOf: samples.map(\.point))
        if swipeTrail.count > Self.swipePathLimit { swipeTrail.removeFirst(swipeTrail.count - Self.swipePathLimit) }
        return true
    }

    /// Prose fields with an enabled word language and loaded word lists. Elsewhere (URL, email,
    /// passwords, no languages) sliding over letters keeps its old meaning.
    private var swipeIsAvailable: Bool {
        // FUTO's encoder reads swipes on one joined QWERTY board; the split halves' gap would bend every path.
        guard swipeTypingEnabled, field == .text, layerState.layer == .letters, activeAccentMenu == nil,
              layout.orientation != .splitLandscape,
              !autocorrect.suggestionLanguages.isEmpty,
              autocorrect.spatialDecoder?.isResourceLoading == false,
              autocorrect.spatialDecoder?.resourceSnapshot.isEmpty == false else { return false }
        return suggestionOwnership.permitsCorrection
    }

    /// The task stays referenced so `waitForSwipe` also covers a cancelled, still-finishing decode.
    private func cancelPendingSwipe() {
        swipeGeneration &+= 1
        swipeTask?.cancel()
    }

    /// Decodes off the main actor; the word goes in only if nothing changed in the meantime.
    private func finishSwipe(_ touch: ActiveTouch) {
        swipeTrail = []
        cancelPendingSwipe()
        guard let path = touch.swipePath, path.count >= 2, touch.evidenceLayout == layout,
              let swipeLayout = SwipeLayout(layout: layout), swipeIsAvailable,
              let decoder = autocorrect.spatialDecoder else { return }
        let request = SwipeRequest(path: path, layout: swipeLayout, languages: autocorrect.suggestionLanguages,
                                   lexicons: decoder.resourceSnapshot, resources: decoder.resourceRevision)
        let generation = swipeGeneration
        let context = target.documentContextBeforeInput
        // Shift as it was while swiping: a held shift may be up by the time the word arrives.
        let shiftState: ShiftState = shift.state == .locked ? .locked : shift.isUppercase ? .on : .off
        let layout = layout
        let decode = swipeDecoder
        swipeTask = Task { [weak self] in
            let candidates = await decode(request)
            guard let self, !Task.isCancelled, self.swipeGeneration == generation, self.layout == layout,
                  self.target.documentContextBeforeInput == context, self.swipeIsAvailable else { return }
            self.commitSwipe(candidates, shift: shiftState)
        }
    }

    /// Tests: wait for the last released swipe to be decoded and applied (or dropped).
    func waitForSwipe() async {
        await swipeTask?.value
    }

    private func commitSwipe(_ candidates: [SwipeSearch.Candidate], shift shiftState: ShiftState) {
        var words: [String] = []
        for candidate in candidates.prefix(3) {
            let word = Self.swipeCased(autocorrect.swipeSpelling(candidate.word, language: candidate.language), shift: shiftState)
            if !words.contains(word) { words.append(word) }
        }
        guard let word = words.first else { return }
        autocorrect.forgetSpaceTaps()
        let before = target.documentContextBeforeInput
        let text = (Self.swipeNeedsSpace(before: before) ? " " : "") + word
        prepareStatisticsEdit()
        statistics?.direct(text)
        autocorrect.clearPendingUndo()
        // Never pending word feedback or tap evidence: a swipe is neither a confirmed word nor taps.
        autocorrect.discardFeedback()
        target.insertText(text)
        logTyping { $0.swiped(word, time: clock()) }
        autocorrect.touchInput.clear()
        shift.didType()
        lastSpaceAt = nil
        layerState.didInsert(text)
        swipeWord = SwipeWord(inserted: word, words: words,
                              context: target.documentContextBeforeInput.flatMap(Self.boundedSuggestionContext))
        rebuildLayoutIfNeeded()
        didEdit()
    }

    /// Shift applies to the whole word: locked uppercases it, one-shot or auto-cap capitalizes it.
    static func swipeCased(_ word: String, shift: ShiftState) -> String {
        if shift == .locked { return word.uppercased() }
        guard shift == .on, let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// A swiped word starts its own word: a space after letters, digits and closing punctuation,
    /// none at the start, after whitespace or after opening brackets and quotes.
    static func swipeNeedsSpace(before: String?) -> Bool {
        guard let last = before?.last else { return false }
        return last.isLetter || last.isNumber || ".,;:!?)]}”’\"'%".contains(last)
    }

    private func ownedSwipeWord(before: String?) -> SwipeWord? {
        guard let swipeWord, let before, swipeWord.context == Self.boundedSuggestionContext(before),
              before.hasSuffix(swipeWord.inserted) else { return nil }
        return swipeWord
    }

    /// [runner-up, inserted word, third]: the strip's center slot is the current choice.
    private func swipeChips(_ swipe: SwipeWord, ownership: KeyboardSuggestionOwnership) -> [KeyboardSuggestion] {
        let others = swipe.words.filter { $0 != swipe.inserted }
        // Slots are positional: without an alternative there is nothing to offer.
        guard !others.isEmpty else { return [] }
        let ordered: [(String, KeyboardSuggestion.Kind)] = [
            others.first.map { ($0, .secondary) },
            (swipe.inserted, .primary(autoReplace: false)),
            others.dropFirst().first.map { ($0, .secondary) },
        ].compactMap { $0 }
        return ordered.map { word, kind in
            var chip = KeyboardSuggestion(displayText: word, replacement: word, kind: kind)
            chip.ownership = ownership
            chip.isSwipe = true
            return chip
        }
    }

    /// Swaps the swiped word for an alternative in place, without a space and without learning.
    private func replaceSwipeWord(with suggestion: KeyboardSuggestion) {
        autocorrect.forgetSpaceTaps()
        let before = target.documentContextBeforeInput
        guard let ownership = suggestion.ownership, ownership.revision == textRevision,
              ownership == suggestionOwnership, var swipe = ownedSwipeWord(before: before) else {
            refreshSuggestions()
            return
        }
        if suggestion.replacement != swipe.inserted {
            prepareStatisticsEdit()
            statistics?.suggestion(suggestion.replacement, boundaryOriginal: nil)
            autocorrect.clearPendingUndo()
            autocorrect.discardFeedback()
            for _ in 0..<swipe.inserted.count { target.deleteBackward() }
            target.insertText(suggestion.replacement)
            logTyping { $0.swipeReplaced(with: suggestion.replacement) }
            autocorrect.touchInput.clear()
            swipe.inserted = suggestion.replacement
            swipe.context = target.documentContextBeforeInput.flatMap(Self.boundedSuggestionContext)
            swipeWord = swipe
            lastSpaceAt = nil
            didEdit()
        }
    }

    /// Records only where personal learning could: prose fields that allow autocorrection, never
    /// secure, URL or email fields, and only while learning is on. Anywhere else drops open words.
    private var typingLogAllowed: Bool {
        guard field == .text, target.isSecureTextEntry != true, target.autocorrectionType != .no,
              autocorrect.learning.isLearningEnabled,
              case .keys(.text, _) = KeyboardFieldRouting.route(for: target.keyboardType) else { return false }
        return true
    }

    private var typingLogCorrection: TypingLogWord.Commit.CorrectionKind {
        switch autocorrect.pendingFeedback?.kind {
        case .autoSpatial: .spatial
        case .autoSpelling: .spelling
        case .autoRule, .unchanged, nil: .rule
        }
    }

    private func logTyping(_ event: (TypingLogRecorder) -> Void) {
        guard let typingLog else { return }
        guard typingLogAllowed else { typingLog.discard(); return }
        typingLog.languages = autocorrect.suggestionLanguages.map(\.rawValue).sorted()
        event(typingLog)
    }

    /// The user left the word without a separator (field change, host edit, cursor, dismissal).
    func endTypingLogWord(_ reason: String) {
        guard let typingLog else { return }
        if autocorrect.learning.isLearningEnabled { typingLog.end(reason) } else { typingLog.discard() }
    }

    private static func chipName(_ kind: KeyboardSuggestion.Kind) -> String {
        switch kind {
        case .keepLiteral: "keep"
        case .primary: "primary"
        case .secondary: "secondary"
        }
    }

    // MARK: - Layout

    private func rebuildLayoutIfNeeded() {
        if layout.layer != layerState.layer {
            rebuildLayout()
        }
    }

    private func rebuildLayout() {
        let previous = layout
        layout = KeyboardLayout(
            width: width,
            orientation: orientation,
            layer: layerState.layer,
            field: field,
            showsGlobe: showsGlobe,
            globeKey: globeKey,
            bottomRow: bottomRow,
            numberRow: numberRow,
            horizontalInset: horizontalInset,
            showsStrip: showsStrip
        )
        if layout != previous {
            endStatisticsSession()
            // Switching to numbers for punctuation keeps the swiped word protected; its context still decides.
            let swiped = swipeWord
            invalidateTouchEvidence()
            swipeWord = swiped
            refreshSuggestions()
        }
    }
}
