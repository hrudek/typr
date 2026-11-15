import UIKit

/// One slot in the 3-column suggestion strip above the keys.
nonisolated struct KeyboardSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Left slot (`"typed"`): keeps the exact characters and teaches Typr not to rewrite them.
        case keepLiteral
        /// Center slot: best replacement or completion (`autoReplace` highlights when Space will apply it).
        case primary(autoReplace: Bool)
        /// Right slot: runner-up completion or spelling guess.
        case secondary
    }

    let displayText: String
    let replacement: String
    let kind: Kind
    var isCompletion = false
    var ownership: KeyboardSuggestionOwnership?
    /// Placed by personal completion ranking (#101); counted separately when picked, text-free.
    var isPersonal = false
    /// Manual-only exact suffix replacement; never trains tap labels or phrase counts.
    var boundary: KeyboardBoundaryDecoder.Candidate?
    /// An alternative for the word just swiped: swaps it in place, never learned.
    var isSwipe = false

    var willAutoReplace: Bool {
        if case .primary(let auto) = kind { return auto }
        return false
    }
}

/// Narrow seam over `UITextChecker` so unit tests can run deterministically or against UIKit's dictionary.
@MainActor
protocol TextChecking: AnyObject {
    func isWordValid(_ word: String) -> Bool
    func guesses(for word: String) -> [String]
    func completions(for prefix: String) -> [String]
}

@MainActor
final class SystemTextChecker: TextChecking {
    private var checker: UITextChecker?
    private let language: String

    init(language: String = "en_US") {
        self.language = language
    }

    /// Warms `UITextChecker` after the keyboard's first frame commits so cold open stays < 12 ms.
    func warmUp() {
        guard checker == nil else { return }
        let instance = UITextChecker()
        _ = instance.rangeOfMisspelledWord(
            in: "hello",
            range: NSRange(location: 0, length: 5),
            startingAt: 0,
            wrap: false,
            language: language
        )
        checker = instance
    }

    private var activeChecker: UITextChecker {
        if let checker { return checker }
        let instance = UITextChecker()
        checker = instance
        return instance
    }

    func isWordValid(_ word: String) -> Bool {
        let ns = word as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard range.length > 0 else { return true }
        let misspelled = activeChecker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: language
        )
        return misspelled.location == NSNotFound
    }

    func guesses(for word: String) -> [String] {
        let ns = word as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard range.length > 0 else { return [] }
        return activeChecker.guesses(forWordRange: range, in: word, language: language) ?? []
    }

    func completions(for prefix: String) -> [String] {
        let ns = prefix as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard range.length > 0 else { return [] }
        return activeChecker.completions(forPartialWordRange: range, in: prefix, language: language) ?? []
    }
}

/// Cautious on-device suggestions and replace-on-space engine combining `UILexicon`, deterministic
/// rules, bounded spatial decoding, system spelling and the session's personal protections.
@MainActor
final class AutocorrectEngine {
    /// The path that produced a word boundary's final text.
    enum CorrectionKind: Equatable { case unchanged, autoSpatial, autoSpelling, autoRule }

    struct AppliedCorrection: Equatable {
        let original: String
        let insertedText: String
        var kind: CorrectionKind = .autoRule
        var context: String? = nil
        var keptWordWasNew: Bool? = nil
        var boundary: KeyboardBoundaryDecoder.Candidate? = nil
    }

    /// One completed word awaiting trust: RAM only, never persisted, logged or exported.
    // Delayed word feedback adapted from AVGVSTVS96/iikb
    // Packages/KeyboardModules/Sources/KeyboardCore/Typing/TypingEngine+Words.swift (MIT).
    struct PendingFeedback: Equatable {
        let evidence: KeyboardTouchWord?
        let literal: String
        let finalText: String
        let kind: CorrectionKind
        /// Decoder alignment of an automatic spatial replacement (diagnostic context only).
        let alignment: [Int?]?
        /// Unchanged, valid or kept literal with complete evidence while learning was on.
        let learnable: Bool
        let epoch: Int
        var suffix: String { finalText + " " }
    }

    private var rejectionContext: String? = nil

    /// One automatic-correction decision; a boundary records it exactly once.
    private struct Decision {
        var text: String?
        var kind = CorrectionKind.unchanged
        var counter = KeyboardDiagnostics.Counter.unchanged
        var refusal: KeyboardDiagnostics.Counter?
        var alignment: [Int?]?
    }

    private struct DecodeCache {
        let evidence: KeyboardTouchWord
        let languages: Set<SpatialWordDecoder.Language>
        let generation: Int
        let resources: Int
        let outcome: SpatialWordDecoder.Outcome
    }

    /// Per-token system lookups, computed only for candidates actually used (#96 review note 3).
    private struct SpellingCache {
        let token: String
        var germanGuesses: [String]?
        var systemCompletions: [String]?
        var spatial: [String: (text: String, validated: Bool)] = [:]
    }

    /// Fully aligned, RAM-only evidence for the spatial decoder.
    let touchInput = KeyboardTouchInput()
    let spatialDecoder: SpatialWordDecoder?
    let contextResources: KeyboardContextResources
    private var languagePriorCache: (generation: Int, value: Double)?
    let checker: TextChecking
    let learning: KeyboardLearningSession
    var isEnabled = true { didSet { invalidateDecode() } }
    var englishEnabled = true { didSet {
        if oldValue != englishEnabled { discardFeedback() }
        invalidateDecode()
    } }
    /// Typr: German layer; `nil` keeps today's behaviour exactly.
    var german: GermanAutocorrect? { didSet {
        if (oldValue == nil) != (german == nil) { discardFeedback() }
        invalidateDecode()
    } }
    private(set) var lexiconShortcuts: [String: String] = [:]
    private(set) var protectedLexicon: ProtectedPersonalLexicon = .empty

    func loadProtectedLexicon(_ lexicon: ProtectedPersonalLexicon) {
        guard protectedLexicon != lexicon else { return }
        protectedLexicon = lexicon
        invalidateDecode()
    }

    /// Protect the actual geometric continuation, not every branch of an imported prefix.
    /// A completed imported literal still protects its next tap. No checker work on insertion.
    func protectsAttribution(prefix: String, letter: String) -> Bool {
        protectedLexicon.contains(prefix) || protectedLexicon.protectsPrefix(prefix + letter)
    }

    private var lexiconTerms: [String] = []
    private var lexiconTermKeys: Set<String> = []
    private var suppressedInSession: Set<String> = []
    private var reversibleRejection: RejectedCorrection?
    /// Phrase pairs never enter the letter/apostrophe-only persistent rejection schema.
    private var boundaryRejections: [RejectedCorrection] = []
    private var reversibleBoundary: KeyboardBoundaryDecoder.Candidate?
    static let boundaryRejectionLimit = 64
    var boundaryRejectionCount: Int { boundaryRejections.count }
    private(set) var lastCorrection: AppliedCorrection?
    private(set) var pendingFeedback: PendingFeedback?
    /// Manual choices also wait until the next unambiguous letter before pair training.
    private var pendingPairChoice: (word: String, epoch: Int)?
    private var observedResets: Int
    private var observedFeedbackEpoch: Int
    private var decodeCache: DecodeCache?
    private var spellingCache: SpellingCache?
    /// The latest bounded prefix retrieval (worker or synchronous), reused only for an equal job.
    private var completionCache: KeyboardCompletionRetrieval?
    private struct BoundaryCache {
        let retrieval: KeyboardBoundaryDecoder.Retrieval
        let evidence: KeyboardTouchWord?
        let generation: Int
        let resources: Int
    }
    private var boundaryCache: BoundaryCache?
    private(set) var suggestionConfiguration = 0

    var suggestionLanguages: Set<SpatialWordDecoder.Language> {
        var languages: Set<SpatialWordDecoder.Language> = []
        if englishEnabled { languages.insert(.english) }
        if german != nil { languages.insert(.german) }
        return languages
    }

    /// Synchronous, checker-free attribution preparation, before any deferred ranking.
    /// No adaptation without a trained model, enabled learning/autocorrect or all selected packs.
    func keyMap(layout: KeyboardLayout, context: String?, permitsCorrection: Bool) -> KeyboardKeyMap? {
        guard isEnabled, learning.isLearningEnabled, permitsCorrection,
              layout.layer == .letters, layout.field == .text,
              let token = Self.currentToken(in: context), token.utf8.count <= 256,
              !protectedLexicon.contains(token),
              (KeyboardKeyMap.Policy.conservative.minimumPrefix...31).contains(token.count),
              token.dropFirst().allSatisfy({ $0.isLowercase }),
              let calibration = learning.calibration(for: layout), !calibration.keys.isEmpty else { return nil }
        let prefix = PersonalLexiconSnapshot.normalize(token)
        let lexicons = spatialDecoder?.resourceSnapshot ?? [:]
        let personal = learning.personalPriors.scan.completions
        guard let priors = KeyboardKeyMap.priors(prefix: prefix, languages: suggestionLanguages,
                                                lexicons: lexicons, personal: personal) else { return nil }
        return KeyboardKeyMap(layout: layout, prefix: prefix, calibration: calibration, priors: priors)
    }

    /// Cheap gate for after-separator corpus predictions: autocorrect on, prepared packs for
    /// every selected language (a missing selected pack abstains), caret after whitespace.
    func canPredictNextWord(after beforeInput: String?) -> Bool {
        guard isEnabled, beforeInput?.last?.isWhitespace == true,
              let model = contextResources.model else { return false }
        return model.supports(german: german != nil, english: englishEnabled)
    }

    /// Called only by the worker's deferred preparation, never by key insertion.
    func suggestionRequest(ownership: KeyboardSuggestionOwnership,
                           evidence: KeyboardTouchWord?) -> KeyboardSuggestionWorker.Request {
        let rawEvidence = evidence
        let token = ownership.token ?? ""
        let eligible = isEnabled && !suggestionLanguages.isEmpty && evidence?.text == token
            && (token == token.lowercased() || (token.first?.isUppercase == true
                && String(token.dropFirst()) == token.dropFirst().lowercased()))
            && !Self.shorthandAllowlist.contains(token.lowercased())
        let evidence = eligible ? evidence : nil
        let languages = suggestionLanguages
        // Warmup, remount or poll refreshes with unchanged taps reuse the held decode.
        let completion = ownership.token.flatMap { completionJob(for: $0, evidence: rawEvidence) }
        let held = completion.flatMap { job in completionCache.flatMap { $0.job == job ? $0 : nil } }
        if let evidence, let cache = decodeCache, cache.evidence == evidence,
           cache.languages == languages, cache.generation == learning.generation,
           cache.resources == (spatialDecoder?.resourceRevision ?? -1) {
            var request = KeyboardSuggestionWorker.Request(
                ownership: ownership, evidence: evidence, languages: languages, calibration: nil,
                personal: .empty, lexicons: spatialDecoder?.resourceSnapshot ?? [:])
            request.ready = cache.outcome
            request.completion = completion
            request.completionReady = held
            request.boundary = boundaryJob(beforeInput: ownership.context)
            request.boundaryModel = contextResources.model
            request.boundaryReady = heldWorkerBoundary(request.boundary, evidence: rawEvidence)
            return request
        }
        var request = KeyboardSuggestionWorker.Request(
            ownership: ownership, evidence: evidence, languages: languages,
            calibration: evidence.flatMap { learning.calibration(for: $0.layout) },
            personal: evidence == nil ? .empty : learning.personalPriors,
            lexicons: spatialDecoder?.resourceSnapshot ?? [:])
        request.completion = completion
        request.completionReady = held
        request.boundary = boundaryJob(beforeInput: ownership.context)
        request.boundaryModel = contextResources.model
        request.boundaryReady = heldWorkerBoundary(request.boundary, evidence: rawEvidence)
        return request
    }

    /// Checker-free snapshot of the current token and one adjacent prose token.
    private func heldWorkerBoundary(_ job: KeyboardBoundaryDecoder.Job?,
                                    evidence: KeyboardTouchWord?) -> KeyboardBoundaryDecoder.Retrieval? {
        guard let job, let held = heldBoundary(job, evidence: evidence), held.includesMultipart else { return nil }
        return held
    }

    private func boundaryJob(beforeInput: String?) -> KeyboardBoundaryDecoder.Job? {
        guard isEnabled, let beforeInput, let token = Self.currentToken(in: beforeInput),
              KeyboardBoundaryDecoder.isEligible(token) else { return nil }
        let head = beforeInput.dropLast(token.count)
        let previous = head.last == " " ? Self.currentToken(in: String(head.dropLast().suffix(66))) : nil
        let model = contextResources.model.flatMap {
            $0.supports(german: german != nil, english: englishEnabled) ? $0 : nil
        }
        let context = model?.context(before: beforeInput, currentToken: token)
        let touch = touchInput.boundaryEvidence(beforeInput: beforeInput)
        return .init(token: token, previous: previous, languages: suggestionLanguages,
                     personal: learning.personalPriors, kept: learning.protections.kept,
                     context: context.map { .init(previous: $0.previous, weightDE: $0.state.weightDE) },
                     touch: touch, calibration: touch.flatMap { learning.calibration(for: $0.current.layout) })
    }

    private func heldBoundary(_ job: KeyboardBoundaryDecoder.Job,
                              evidence: KeyboardTouchWord?) -> KeyboardBoundaryDecoder.Retrieval? {
        guard let cache = boundaryCache, cache.retrieval.job == job, cache.evidence == evidence,
              cache.generation == learning.generation,
              cache.resources == (spatialDecoder?.resourceRevision ?? -1) else { return nil }
        return cache.retrieval
    }

    /// Display-only prefix inputs for `token`; checker-free, so worker preparation stays so.
    /// The personal scan is supplied only while Learn from my typing is on.
    private func completionJob(for token: String, evidence: KeyboardTouchWord?) -> KeyboardCompletionJob? {
        let languages = suggestionLanguages
        guard isEnabled, !languages.isEmpty, token.utf8.count <= 256,
              (2..<SpatialPrefixSearch.maxLetters).contains(token.count) else { return nil }
        let evidence = evidence?.text == token ? evidence : nil
        return KeyboardCompletionJob(
            token: token, languages: languages, resources: spatialDecoder?.resourceRevision ?? -1,
            evidence: evidence, calibration: evidence.flatMap { learning.calibration(for: $0.layout) },
            personal: learning.isLearningEnabled ? learning.personalPriors.scan : nil)
    }

    /// Worker retrieval when it matches; otherwise the same bounded retrieval, synchronously.
    private func completionRetrieval(for job: KeyboardCompletionJob) -> KeyboardCompletionRetrieval {
        if let cache = completionCache, cache.job == job { return cache }
        let retrieval = KeyboardCompletionRetrieval(job, lexicons: spatialDecoder?.resourceSnapshot ?? [:])
        completionCache = spatialDecoder?.isResourceLoading == true ? nil : retrieval
        return retrieval
    }

    /// A compatible immutable result is adopted into the same cache the authoritative boundary
    /// reads. Checker calls remain here on MainActor, in a separate step after key handling.
    func finishSuggestions(_ result: KeyboardSuggestionWorker.Result) -> [KeyboardSuggestion] {
        if let evidence = result.request.evidence, let outcome = result.outcome {
            decodeCache = DecodeCache(evidence: evidence, languages: result.request.languages,
                                      generation: learning.generation,
                                      resources: result.request.ownership.resources, outcome: outcome)
            // A reused decode was already counted when it was searched.
            if result.request.ready == nil, case .result = outcome, spatialDecoder?.isResourceLoading == false {
                learning.increment(.suggestionDecodes)
                learning.recordLatency(result.seconds, kind: .suggestion)
            }
        }
        if let completion = result.completion, spatialDecoder?.isResourceLoading != true {
            completionCache = completion
        }
        let suggestions = suggestions(beforeInput: result.request.ownership.context,
                                      field: result.request.ownership.field,
                                      autocorrectionType: result.request.ownership.permitsCorrection ? .default : .no,
                                      boundaryRetrieval: result.boundary)
        // A loading refusal must not survive installation of resources.
        if spatialDecoder?.isResourceLoading == true { decodeCache = nil }
        return suggestions
    }

    init(
        checker: TextChecking? = nil,
        learning: KeyboardLearningSession? = nil,
        spatialDecoder: SpatialWordDecoder? = .bundled,
        contextResources: KeyboardContextResources? = nil
    ) {
        self.contextResources = contextResources ?? .bundled
        self.spatialDecoder = spatialDecoder
        self.checker = checker ?? SystemTextChecker()
        let learning = learning ?? KeyboardLearningSession()
        self.learning = learning
        observedResets = learning.resets
        observedFeedbackEpoch = learning.feedbackEpoch
    }

    func loadLexicon(_ lexicon: UILexicon) {
        loadLexiconEntries(lexicon.entries.map { ($0.userInput, $0.documentText) })
    }

    func loadLexiconEntries(_ entries: [LexiconEntry]) {
        loadLexiconEntries(entries.map { ($0.userInput, $0.documentText) })
    }

    func loadLexiconEntries(_ entries: [(userInput: String, documentText: String)]) {
        var shortcuts: [String: String] = [:]
        var terms: [String] = []
        for (input, output) in entries {
            let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInput.isEmpty, !trimmedOutput.isEmpty else { continue }
            if trimmedInput.lowercased() != trimmedOutput.lowercased() {
                shortcuts[trimmedInput.lowercased()] = trimmedOutput
            } else {
                terms.append(trimmedOutput)
            }
        }
        invalidateDecode()
        lexiconShortcuts = shortcuts
        lexiconTerms = terms
        lexiconTermKeys = Set(terms.map { $0.lowercased() })
    }

    func clearPendingUndo() {
        lastCorrection = nil
    }

    func recordAppliedKeep(_ word: String, wasNew: Bool) {
        lastCorrection = AppliedCorrection(original: word, insertedText: word + " ", keptWordWasNew: wasNew)
    }

    func recordAppliedCorrection(original: String, insertedText: String) {
        lastCorrection = AppliedCorrection(original: original, insertedText: insertedText,
                                           kind: pendingFeedback?.kind ?? .autoRule, context: rejectionContext)
    }

    func recordAppliedBoundary(_ candidate: KeyboardBoundaryDecoder.Candidate, replacement: String) {
        lastCorrection = AppliedCorrection(original: candidate.original, insertedText: replacement + " ",
                                           boundary: candidate)
    }

    func consumePendingUndo() -> AppliedCorrection? {
        defer { lastCorrection = nil }
        return lastCorrection
    }

    /// Explicit keep: protects the spelling for this engine and in the personal lexicon.
    func suppressAndKeep(_ word: String) {
        suppressedInSession.insert(word.lowercased())
        learning.keep(word)
    }

    /// Settings poll and keyboard appearance: switch value, app resets and storage access.
    func syncLearning() {
        learning.refresh()
        if observedFeedbackEpoch != learning.feedbackEpoch {
            observedFeedbackEpoch = learning.feedbackEpoch
            pendingFeedback = nil
            pendingPairChoice = nil
            learning.breakWordSequence()
            lastCorrection = nil
            reversibleRejection = nil
            reversibleBoundary = nil
        }
        guard observedResets != learning.resets else { return }
        observedResets = learning.resets
        suppressedInSession = []
        boundaryRejections = []
        reversibleBoundary = nil
        lastCorrection = nil
        pendingFeedback = nil
    }

    /// Cursor, field, layout or host text changed: no tap, decode or pending word survives.
    /// Only an applied manual word choice preserves the just-trained fast aggregate aim.
    func discardEvidence(resetFastAim: Bool = true) {
        if resetFastAim {
            learning.resetFastAim()
            pendingPairChoice = nil
        }
        touchInput.clear()
        decodeCache = nil
        completionCache = nil
        boundaryCache = nil
        pendingFeedback = nil
        reversibleRejection = nil
        reversibleBoundary = nil
    }

    func discardFeedback(preservingTrustedContext: Bool = false) {
        pendingFeedback = nil
        pendingPairChoice = nil
        reversibleRejection = nil
        reversibleBoundary = nil
        if !preservingTrustedContext { learning.breakWordSequence() }
    }

    private func invalidateDecode() {
        suggestionConfiguration &+= 1
        decodeCache = nil
        completionCache = nil
        boundaryCache = nil
        spellingCache = nil
    }

    // MARK: - Feedback transaction

    /// The next word's first letter arrives: trust the previous word only
    /// if it is still intact right before the cursor.
    func settleFeedback(beforeInput: String?, insertedLetter: String, afterInput: String?) {
        reversibleRejection = nil
        reversibleBoundary = nil
        if let choice = pendingPairChoice {
            pendingPairChoice = nil
            let suffix = choice.word + " "
            if choice.epoch == learning.feedbackEpoch, let beforeInput,
               beforeInput.hasSuffix(suffix), insertedLetter.count == 1, insertedLetter.first?.isLetter == true,
               afterInput == beforeInput + insertedLetter {
                learning.settleTrustedWord(choice.word, beforeInput: beforeInput)
            } else { learning.breakWordSequence() }
        }
        guard let pending = pendingFeedback else { return }
        pendingFeedback = nil
        guard pending.learnable, pending.epoch == learning.feedbackEpoch,
              insertedLetter.count == 1, insertedLetter.first?.isLetter == true,
              afterInput?.hasSuffix(pending.suffix + insertedLetter) == true,
              let evidence = pending.evidence, let beforeInput, beforeInput.hasSuffix(pending.suffix),
              beforeInput.dropLast(pending.suffix.count).last?.isLetter != true else {
            learning.breakWordSequence(); return
        }
        learning.settleTrustedWord(pending.literal, beforeInput: beforeInput)
        learnIdentity(evidence, literal: pending.literal, source: .literalValid)
        learning.confirmLiteral(pending.literal)
        learning.recordWord(pending.literal)
    }

    /// Backspace restored the typed word right after an automatic replacement.
    func recordUndo(_ undo: AppliedCorrection) {
        pendingPairChoice = nil
        learning.breakWordSequence()
        if let boundary = undo.boundary {
            pendingFeedback = nil
            reversibleBoundary = nil
            let pair = RejectedCorrection(typed: boundary.original, replacement: boundary.replacement)
            if !boundaryRejections.contains(pair) {
                boundaryRejections.append(pair)
                if boundaryRejections.count > Self.boundaryRejectionLimit { boundaryRejections.removeFirst() }
                reversibleBoundary = boundary
            }
            return // Manual boundary undo is not an automatic-correction counter or a tap label.
        }
        if let wasNew = undo.keptWordWasNew {
            pendingFeedback = nil
            if wasNew {
                learning.forgetKeep(undo.original)
                suppressedInSession.remove(undo.original.lowercased())
            }
            return
        }
        let pending = pendingFeedback
        pendingFeedback = nil
        switch undo.kind {
        case .autoSpatial: learning.increment(.undoSpatial)
        case .autoSpelling: learning.increment(.undoSpelling)
        case .autoRule, .unchanged: learning.increment(.undoRule)
        }
        if let pending, pending.literal == undo.original, pending.suffix == undo.insertedText,
           pending.epoch == learning.feedbackEpoch, let evidence = pending.evidence {
            learnIdentity(evidence, literal: undo.original, source: .undo)
        }
        // Current boundary corrections append one separator; keep other callers safe.
        let hasSeparator = undo.insertedText.last.map { " .,?!".contains($0) } ?? false
        let replacement = hasSeparator ? String(undo.insertedText.dropLast()) : undo.insertedText
        let pair = RejectedCorrection(typed: undo.original, replacement: replacement)
        let wasRejected = learning.model.state.rejected.contains(pair)
        if !PersonalTypingModel.State.validRejectedWord(pair.typed)
            || !PersonalTypingModel.State.validRejectedWord(pair.replacement) {
            suppressedInSession.insert(undo.original.lowercased())
        }
        learning.rejectCorrection(typed: undo.original, replacement: replacement, context: undo.context)
        reversibleRejection = wasRejected ? nil : pair
    }

    /// An explicit strip choice. `evidence` must be captured before the word is invalidated.
    func recordSuggestionFeedback(_ suggestion: KeyboardSuggestion, literal: String,
                                  evidence: KeyboardTouchWord?) {
        pendingFeedback = nil
        if let boundary = suggestion.boundary {
            boundaryRejections.removeAll {
                $0 == RejectedCorrection(typed: boundary.original, replacement: boundary.replacement)
            }
            reversibleBoundary = nil
            reversibleRejection = nil
            // Neither part was independently typed and settled: no word-pair endpoint either.
            pendingPairChoice = nil
            learning.breakWordSequence()
            learning.increment(.manualAlternativePick)
            return // No inferred boundary labels, phrase counts, constituent-word or pair training.
        }
        if let pair = reversibleRejection,
           pair.typed == PersonalLexiconSnapshot.normalize(literal),
           pair.replacement == PersonalLexiconSnapshot.normalize(suggestion.replacement),
           suggestion.kind != .keepLiteral {
            learning.forgetRejection(pair)
            suppressedInSession.remove(literal.lowercased())
        }
        reversibleRejection = nil
        let evidence = evidence?.text == literal ? evidence : nil
        let mayLearn = touchInput.isLearningIntact && evidence?.learningIntact != false
        pendingPairChoice = nil
        if mayLearn, learning.isLearningEnabled,
           PersonalBigramModel.validWord(PersonalLexiconSnapshot.normalize(suggestion.replacement)) {
            pendingPairChoice = (suggestion.replacement, learning.feedbackEpoch)
        } else { learning.breakWordSequence() }
        // The center slot repeats the typed word when nothing else applies: not an alternative.
        guard suggestion.kind == .keepLiteral || suggestion.replacement != literal else { return }
        if suggestion.kind == .keepLiteral {
            learning.increment(.keepChip)
            if let evidence { learnIdentity(evidence, literal: literal, source: .keep) }
            suppressAndKeep(literal)
            if mayLearn { learning.recordWord(literal) }
        } else if suggestion.isCompletion || Self.isPrefixExtension(suggestion.replacement, of: literal) {
            learning.increment(.manualCompletionPick)
            // Text-free: which chip a personal reorder placed, never which word.
            if suggestion.isPersonal { learning.increment(.personalCompletionPick) }
            if mayLearn { learning.recordWord(suggestion.replacement) }
        } else {
            learning.increment(.manualAlternativePick)
            if let evidence, evidence.learningIntact { learnAligned(evidence, word: suggestion.replacement) }
            if mayLearn { learning.recordWord(suggestion.replacement) }
        }
    }

    /// Ownership-validated next-word pick. Settle the preceding endpoint against the
    /// actual insertion, then defer this endpoint until a following letter/pick confirms it.
    /// Predictions never fabricate tap labels or teach a word from an arbitrary host suffix.
    func recordPredictionFeedback(_ word: String, beforeInput: String?) {
        guard let beforeInput, let first = word.first, first.isLetter,
              PersonalBigramModel.validWord(PersonalLexiconSnapshot.normalize(word)) else {
            discardFeedback(); return
        }
        settleFeedback(beforeInput: beforeInput, insertedLetter: String(first), afterInput: beforeInput + String(first))
        pendingPairChoice = learning.isLearningEnabled ? (word, learning.feedbackEpoch) : nil
        learning.recordWord(word)
    }

    private func learnIdentity(_ evidence: KeyboardTouchWord, literal: String, source: TouchLabelSource) {
        guard evidence.learningIntact, evidence.text == literal, evidence.samples.count == literal.count else { return }
        let labels = evidence.samples.compactMap { sample in
            sample.text.lowercased().first.map { TouchLabel(point: sample.point, letter: $0) }
        }
        learning.learn(labels, layout: evidence.layout, source: source)
    }

    /// Only uniquely aligned tap/letter pairs; the model also rejects taps > 1 pitch from the key.
    private func learnAligned(_ evidence: KeyboardTouchWord, word: String) {
        let taps = evidence.samples.compactMap { $0.text.lowercased().first }
        guard taps.count == evidence.samples.count,
              let alignment = SpatialWordDecoder.align(word: word, taps: taps) else {
            learning.recordRejection(.ambiguousAlignment, count: evidence.samples.count)
            return
        }
        let letters = Array(word.lowercased())
        var labels: [TouchLabel] = []
        for (index, tap) in alignment.enumerated() {
            guard let tap, letters.indices.contains(index), evidence.samples.indices.contains(tap) else { continue }
            labels.append(TouchLabel(point: evidence.samples[tap].point, letter: letters[index]))
        }
        learning.recordRejection(.ambiguousAlignment, count: evidence.samples.count - labels.count)
        learning.learn(labels, layout: evidence.layout, source: .manualPick)
    }

    // MARK: - Token inspection

    /// Extracts the active word right before the caret, returning `nil` inside URLs, handles, paths, or numbers.
    static func currentToken(in beforeInput: String?) -> String? {
        guard let beforeInput, !beforeInput.isEmpty else { return nil }
        let end = beforeInput.endIndex
        var start = end
        while start > beforeInput.startIndex {
            let prev = beforeInput.index(before: start)
            let ch = beforeInput[prev]
            let apostrophe = ch == "'" || ch == "’"
            let internalApostrophe = apostrophe && start < end && prev > beforeInput.startIndex
                && beforeInput[beforeInput.index(before: prev)].isLetter
            if ch.isLetter || internalApostrophe {
                start = prev
            } else {
                break
            }
        }
        guard start < end else { return nil }
        // Guard against tokens attached to `@`, `/`, `.`, `#`, `_`, `-`, or digits.
        if start > beforeInput.startIndex {
            let boundary = beforeInput[beforeInput.index(before: start)]
            if boundary == "@" || boundary == "/" || boundary == "." || boundary == "#"
                || boundary == "_" || boundary == "-" || boundary == ":" || boundary.isNumber {
                return nil
            }
        }
        let token = String(beforeInput[start..<end])
        guard token.first?.isLetter == true else { return nil }
        return token
    }

    private static func isPrefixExtension(_ word: String, of literal: String) -> Bool {
        let word = word.lowercased(), literal = literal.lowercased()
        return word.count > literal.count && word.hasPrefix(literal)
    }

    // MARK: - Suggestions & Replace-on-Space

    func suggestions(
        beforeInput: String?,
        field: KeyboardFieldKind,
        autocorrectionType: UITextAutocorrectionType?,
        boundaryRetrieval: KeyboardBoundaryDecoder.Retrieval? = nil
    ) -> [KeyboardSuggestion] {
        let evidence = touchInput.evidence(beforeInput: beforeInput)
        guard field == .text, autocorrectionType != .no else { return [] }
        let activeToken = Self.currentToken(in: beforeInput)
        let contextModel = isEnabled ? contextResources.model.flatMap {
            $0.supports(german: german != nil, english: englishEnabled) ? $0 : nil
        } : nil
        var languagePrior = 0.0
        if let model = contextModel, learning.isLearningEnabled {
            if languagePriorCache?.generation != learning.generation {
                languagePriorCache = (learning.generation, model.personalLanguagePrior(learning.model.state.counts))
            }
            languagePrior = languagePriorCache?.value ?? 0
        }
        let context = contextModel?.context(before: beforeInput, currentToken: activeToken, prior: languagePrior)
        guard let token = activeToken else {
            guard canPredictNextWord(after: beforeInput), let context, context.canPredict,
                  let model = contextModel else { return [] }
            let words = model.suggestions(after: context.previous, weightDE: context.state.weightDE,
                                          german: german != nil, english: englishEnabled,
                                          personal: learning.personalBigrams, earlier: context.earlier)
            // Most likely word in the centre slot, like the current-word strip; never automatic.
            return KeyboardContextModel.stripOrder(words).map { word in
                let selected = learning.personalBigrams.select(after: context.previous, earlier: context.earlier).context
                let display = learning.personalBigrams.followers(after: selected)[word.key] != nil
                    ? personalSpelling(word.display, token: word.display) : word.display
                return KeyboardSuggestion(displayText: display, replacement: display,
                                          kind: word == words.first ? .primary(autoReplace: false) : .secondary,
                                          isCompletion: true)
            }
        }

        rejectionContext = RejectedCorrection.context(before: beforeInput, token: token)
        let lower = token.lowercased()
        let decision = isEnabled ? decide(token, evidence: evidence, forSuggestions: true) : nil
        let autoFix = decision?.text
        let spatial = spatialResult(for: token, evidence: evidence, forSuggestions: true)
        var pool: [String] = []
        var completions: Set<String> = []
        var spatialScores: [String: Double] = [:]
        var personalPicks: Set<String> = []
        var boundaries: [String: KeyboardBoundaryDecoder.Candidate] = [:]
        var contactPicks: Set<String> = []
        // Widen retrieval only when corpus context can contribute, independently of
        // Learn from my typing. No-context/off/missing-pack paths keep #115's budget.
        let usesContext = context?.canPredict == true
        let poolLimit = usesContext ? SpatialPrefixSearch.maxResults : 2

        if let pair = reversibleRejection, pair.typed == PersonalLexiconSnapshot.normalize(token) {
            // Rejected protections suppress automatic decisions, not the immediate explicit revert.
            pool.append(Self.matchCase(of: token, onto: pair.replacement))
        }
        if let autoFix {
            if !pool.contains(autoFix) { pool.append(autoFix) }
        } else if isEnabled, let suggested = orthographySuggestion(token, context: context) {
            pool.append(suggested)
        }
        // Explicit revert, automatic choice and manual orthography keep their slots.
        let pinnedCount = pool.count

        // Imported completions precede speculative alternatives, but never an explicit/automatic pick.
        // Binary lower bound: no full personal-list scan on a keypress.
        for term in protectedLexicon.completions(for: token) where pool.count < poolLimit {
            let candidate = Self.matchCase(of: token, onto: term)
            if !pool.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                pool.append(candidate)
                completions.insert(candidate)
                contactPicks.insert(candidate)
            }
        }

        // Worker boundaries precede speculative within-word alternatives, not an automatic fix.
        // UIKit dictionary validity remains on MainActor, after retrieval.
        if let job = boundaryJob(beforeInput: beforeInput) {
            let retrieval = boundaryRetrieval.flatMap { $0.job == job ? $0 : nil }
                ?? heldBoundary(job, evidence: evidence)
                ?? KeyboardBoundaryDecoder.retrieve(job, lexicons: spatialDecoder?.resourceSnapshot ?? [:],
                                                     whole: spatialOutcome(for: token, evidence: evidence,
                                                                           forSuggestions: true),
                                                     model: contextResources.model, includeMultipart: false)
            if spatialDecoder?.isResourceLoading != true {
                boundaryCache = BoundaryCache(retrieval: retrieval, evidence: evidence,
                                              generation: learning.generation,
                                              resources: spatialDecoder?.resourceRevision ?? -1)
            }
            var candidates = retrieval.candidates
            if let reversibleBoundary, beforeInput?.hasSuffix(reversibleBoundary.original) == true {
                candidates.insert(reversibleBoundary, at: 0)
            }
            for candidate in candidates where pool.count < 2 {
                let pair = RejectedCorrection(typed: candidate.original, replacement: candidate.replacement)
                if boundaryRejections.contains(pair) && candidate != reversibleBoundary { continue }
                let parts = candidate.original.split(separator: " ").map(String.init)
                let protected = parts.contains {
                    suppressedInSession.contains($0.lowercased()) || lexiconTermKeys.contains($0.lowercased())
                        || protectedLexicon.contains($0)
                        || lexiconShortcuts[$0.lowercased()] != nil || learning.protections.isKept($0)
                        || Self.shorthandAllowlist.contains($0.lowercased())
                }
                if protected { continue }
                // Dictionary validity stays authoritative even when the worker treated a
                // FrequencyWords entry (e.g. "inthe") as merge noise: Apple's checker, not the
                // ranking corpus, decides whether "comeback" or "beider" is a real word.
                if candidate.kind == .split && literalIsValid(token) { continue }
                if candidate.kind == .join && parts.allSatisfy({ literalIsValid($0) })
                    && (!candidate.spatial || !candidate.betterThanSeparateTap) { continue }
                let replacement: String
                if candidate.kind == .split {
                    let words = candidate.replacement.split(separator: " ").map(String.init)
                    replacement = words.enumerated().map { index, word in
                        let cased = word == "i" && englishEnabled ? "I" : personalSpelling(word, token: word)
                        return index == 0 ? Self.matchCase(of: token, onto: cased) : cased
                    }.joined(separator: " ")
                } else {
                    replacement = personalSpelling(candidate.replacement, token: parts[0])
                }
                guard !pool.contains(replacement) else { continue }
                pool.append(replacement)
                boundaries[replacement] = candidate
            }
        }

        // Spatial words (including above-literal one-edit candidates) use the same slots, never changing
        // typed characters. Display-only, below-literal structural edit suggestions follow, only for a
        // literal nothing else trusts; automatic decisions read `candidates` alone.
        let protectsLiteral = spatial?.suggestions.contains(where: { $0.edit != .none }) == true
            && protectsFromEditSuggestions(token)
        for candidate in spatial?.suggestions ?? [] {
            if pool.count >= poolLimit { break }
            if candidate.edit != .none && protectsLiteral { continue }
            let text = spatialSpelling(candidate, token: token).text
            if candidate.edit != .none && learning.protections.isRejected(typed: token, replacement: text, context: rejectionContext) { continue }
            if !pool.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                pool.append(text)
                spatialScores[text] = candidate.score
            }
            if candidate.isCompletion { completions.insert(text) }
        }

        // Prefix matches from Contacts / lexicon terms.
        if lower.count >= 2 && pool.count < poolLimit {
            for term in lexiconTerms where term.lowercased().hasPrefix(lower) && term.lowercased() != lower {
                let candidate = Self.matchCase(of: token, onto: term)
                if !pool.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    pool.append(candidate)
                    completions.insert(candidate)
                    contactPicks.insert(candidate)
                }
                if pool.count >= 3 { break }
            }
        }

        // Corpus prefixes and held-letter alternatives are display-only, independent of the
        // correction result/cache. The worker retrieves them; this only assembles and cases.
        if pool.count < poolLimit, let job = completionJob(for: token, evidence: evidence) {
            let retrieval = completionRetrieval(for: job)
            // With context, form a union BEFORE display truncation: ≤8 personal
            // promotions, ≤8 trie results and ≤8 system results. Alongside the
            // preceding <8 alternatives this fits the pure reranker's 32-item cap.
            // Without context, preserve #115's exact personal/trie/system ordering.
            let completionLimit = usesContext ? pool.count + 3 * SpatialPrefixSearch.maxResults : 2
            // Trusted literals may extend exactly (or via a holder), but must not be
            // displaced by a spatially reinterpreted prefix masquerading as a completion.
            let trusted = protectsFromEditSuggestions(token)
            var corpus: [(text: String, isCompletion: Bool)] = []
            for item in trusted ? retrieval.exact : retrieval.corpus {
                var spelling = item.word
                if item.language == .german, let german {
                    // Lowercase corpus data cannot establish noun casing. Use the selected
                    // system dictionary; never infer canonical capitalization from frequency.
                    let title = spelling.prefix(1).uppercased() + spelling.dropFirst()
                    if !german.isValid(spelling), german.isValid(title) { spelling = title }
                }
                corpus.append((Self.matchCase(of: token, onto: spelling), item.isCompletion))
            }
            func offer(_ cased: String, isCompletion: Bool, personal: Bool = false) {
                guard pool.count < completionLimit, !learning.protections.isRejected(typed: token, replacement: cased, context: rejectionContext),
                      !pool.contains(where: { $0.caseInsensitiveCompare(cased) == .orderedSame }) else { return }
                pool.append(cased)
                if isCompletion { completions.insert(cased) }
                if personal { personalPicks.insert(cased) }
            }
            // Learn from my typing: completions the user types often (or kept) move up, and
            // missing personal words with this prefix may join. Off: no personal influence.
            if job.personal?.completions.entries.isEmpty == false {
                let system = englishEnabled && token.count >= 2 ? systemCompletions(for: token) : []
                let baseline = corpus.filter(\.isCompletion).map(\.text) + system
                for promotion in KeyboardCompletionRanking.promotions(
                    token: token, baseline: baseline, additions: retrieval.personal,
                    personal: learning.personalPriors) where pool.count < completionLimit {
                    let cased = promotion.isAddition ? personalSpelling(promotion.word, token: token) : promotion.word
                    offer(cased, isCompletion: true, personal: true)
                }
            }
            for item in corpus where pool.count < completionLimit { offer(item.text, isCompletion: item.isCompletion) }
            if usesContext, englishEnabled {
                for item in systemCompletions(for: token).prefix(SpatialPrefixSearch.maxResults) {
                    offer(item, isCompletion: true)
                }
            }
        }

        // Spelling guesses or prefix completions from `UITextChecker`.
        if pool.count < poolLimit && token.count >= 2 {
            // Typr: German-valid words count as valid; German guesses come first.
            let valid = Self.shorthandAllowlist.contains(lower) || literalIsValid(token)
            if !valid {
                for guess in germanGuesses(for: token) + (englishEnabled ? rankedGuesses(for: token) : []) {
                    let cased = Self.matchCase(of: token, onto: guess)
                    if cased.caseInsensitiveCompare(token) != .orderedSame,
                       !pool.contains(where: { $0.caseInsensitiveCompare(cased) == .orderedSame }) {
                        pool.append(cased)
                    }
                    if pool.count >= poolLimit { break }
                }
            }
            if englishEnabled && pool.count < poolLimit {
                for cased in systemCompletions(for: token) {
                    if !pool.contains(where: { $0.caseInsensitiveCompare(cased) == .orderedSame }) {
                        pool.append(cased)
                        completions.insert(cased)
                    }
                    if pool.count >= poolLimit { break }
                }
            }
        }

        // Context only reorders display alternatives. The automatic choice or explicit revert
        // stays first (Space and its highlight must still describe the unchanged decision).
        if let context, let model = contextModel {
            // Contacts retain #115's precedence too, even with a stronger corpus follower.
            // Phrases already carry P(left|context)·P(right|left); do not rerank them
            // as nonexistent unigram words or lose them behind completion candidates.
            let slots = pool.indices.filter {
                $0 >= pinnedCount && !contactPicks.contains(pool[$0]) && boundaries[pool[$0]] == nil
            }
            let ranked = model.rerank(slots.map { pool[$0] }, spatialScores: spatialScores, context: context,
                                      german: german != nil, english: englishEnabled,
                                      personal: learning.personalBigrams)
            for (slot, word) in zip(slots, ranked) { pool[slot] = word }
        }

        let literal = KeyboardSuggestion(displayText: "“\(token)”", replacement: token, kind: .keepLiteral)
        let primary: KeyboardSuggestion = if let first = pool.first {
            KeyboardSuggestion(
                displayText: first,
                replacement: first,
                // Explicit rules retain #117's highlight exception; inferred boundaries do not.
                kind: .primary(autoReplace: boundaries[first] == nil && first == autoFix
                               && (decision?.kind == .autoRule
                                   || (!completions.contains(first) && !Self.isPrefixExtension(first, of: token)))),
                isCompletion: boundaries[first] == nil && (completions.contains(first) || Self.isPrefixExtension(first, of: token)),
                isPersonal: personalPicks.contains(first),
                boundary: boundaries[first]
            )
        } else {
            KeyboardSuggestion(displayText: token, replacement: token, kind: .primary(autoReplace: false))
        }
        let secondary: KeyboardSuggestion? = if pool.count >= 2 {
            KeyboardSuggestion(displayText: pool[1], replacement: pool[1], kind: .secondary,
                               isCompletion: boundaries[pool[1]] == nil && (completions.contains(pool[1]) || Self.isPrefixExtension(pool[1], of: token)),
                               isPersonal: personalPicks.contains(pool[1]), boundary: boundaries[pool[1]])
        } else {
            nil
        }
        return [literal, primary] + (secondary.map { [$0] } ?? [])
    }

    /// One word-boundary transaction (space, Typr key or sentence punctuation): decides once, records diagnostics once and
    /// opens the pending feedback. Returns `(tokenToDelete, replacement)` only for a cautious fix.
    func replacementOnSpace(
        beforeInput: String?,
        field: KeyboardFieldKind,
        autocorrectionType: UITextAutocorrectionType?
    ) -> (original: String, replacement: String)? {
        let evidence = touchInput.evidence(beforeInput: beforeInput)
        pendingFeedback = nil
        guard isEnabled, field == .text, autocorrectionType != .no else { return nil }
        guard let token = Self.currentToken(in: beforeInput) else { return nil }
        rejectionContext = RejectedCorrection.context(before: beforeInput, token: token)
        let started = DispatchTime.now().uptimeNanoseconds
        let decision = decide(token, evidence: evidence, forSuggestions: false)
        let learnable = decision.text == nil && evidence?.learningIntact == true && learning.isLearningEnabled
            && (literalIsValid(token) || learning.model.state.rejected.contains(where: {
                $0.typed == PersonalLexiconSnapshot.normalize(token)
            }))
        pendingFeedback = PendingFeedback(evidence: evidence, literal: token, finalText: decision.text ?? token,
                                          kind: decision.kind, alignment: decision.alignment,
                                          learnable: learnable, epoch: learning.feedbackEpoch)
        learning.increment(.boundaries)
        // Complete means usable by the decoder, not merely observed by the tracker.
        if !(3...SpatialWordDecoder.maxLetters).contains(token.count) {
            learning.increment(.evidenceLengthOutOfRange)
        } else if !token.lowercased().allSatisfy({ ("a"..."z").contains($0) }) {
            learning.increment(.evidenceUnsupported)
        } else {
            learning.increment(evidence != nil ? .evidenceComplete : .evidenceMissing)
        }
        learning.increment(decision.counter)
        if let refusal = decision.refusal { learning.increment(refusal) }
        learning.recordLatency(Self.seconds(since: started), kind: .boundary)
        return decision.text.map { (token, $0) }
    }

    /// Suggestion-only edit words would displace the normal completions of a spelling Typr trusts:
    /// valid in an enabled language (including a lowercase-typed German noun), kept or a contact.
    private func protectsFromEditSuggestions(_ token: String) -> Bool {
        let lower = token.lowercased()
        return suppressedInSession.contains(lower) || lexiconTermKeys.contains(lower) || protectedLexicon.contains(token)
            || literalIsValid(token)
    }

    /// Valid in an enabled dictionary or explicitly kept (the only literals trusted by learning).
    func literalIsValid(_ token: String) -> Bool {
        protectedLexicon.contains(token) || learning.protections.isKept(token) || dictionaryAcceptsLiteral(token)
    }

    private func dictionaryAcceptsLiteral(_ token: String) -> Bool {
        let lower = token.lowercased()
        let title = lower.prefix(1).uppercased() + lower.dropFirst()
        return (englishEnabled && (checker.isWordValid(token) || checker.isWordValid(lower)))
            || (german.map { $0.isValid(token) || $0.isValid(lower) || $0.isValid(title) } ?? false)
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    // MARK: - Spatial decoding

    private func spatialResult(for token: String, evidence: KeyboardTouchWord?,
                               forSuggestions: Bool) -> SpatialWordDecoder.Result? {
        if case .result(let result)? = spatialOutcome(for: token, evidence: evidence, forSuggestions: forSuggestions) {
            return result
        }
        return nil
    }

    /// One decode per (evidence, languages, learning generation, resources), shared by strip and boundary.
    private func spatialOutcome(for token: String, evidence: KeyboardTouchWord?,
                                forSuggestions: Bool) -> SpatialWordDecoder.Outcome? {
        guard isEnabled, let evidence, evidence.text == token,
              token == token.lowercased() || (token.first?.isUppercase == true && String(token.dropFirst()) == token.dropFirst().lowercased()),
              !Self.shorthandAllowlist.contains(token.lowercased()) else {
            decodeCache = nil
            return nil
        }
        var languages: Set<SpatialWordDecoder.Language> = []
        if englishEnabled { languages.insert(.english) }
        if german != nil { languages.insert(.german) }
        guard !languages.isEmpty else { return nil }
        let generation = learning.generation
        if let cache = decodeCache, cache.generation == generation, cache.languages == languages,
           cache.resources == (spatialDecoder?.resourceRevision ?? -1), cache.evidence == evidence {
            return cache.outcome
        }
        let outcome: SpatialWordDecoder.Outcome
        if let spatialDecoder {
            let started = DispatchTime.now().uptimeNanoseconds
            // Calibration and personal words are supplied only while learning is on.
            outcome = spatialDecoder.decodeDetailed(evidence, languages: languages,
                                                    calibration: learning.calibration(for: evidence.layout),
                                                    personal: learning.personalPriors)
            if forSuggestions, case .result = outcome, !spatialDecoder.isResourceLoading {
                learning.increment(.suggestionDecodes)
                learning.recordLatency(Self.seconds(since: started), kind: .suggestion)
            }
        } else {
            outcome = .unavailable(.resource)
        }
        decodeCache = spatialDecoder?.isResourceLoading == true ? nil
            : DecodeCache(evidence: evidence, languages: languages, generation: generation,
                          resources: spatialDecoder?.resourceRevision ?? -1, outcome: outcome)
        return outcome
    }

    /// A swiped lexicon word as written: FrequencyWords is lowercase, so German noun casing comes
    /// only from the dictionary (title case valid, lowercase not), like `GermanAutocorrect.nounSuggestion`.
    func swipeSpelling(_ word: String, language: SpatialWordDecoder.Language?) -> String {
        if language == .english || german == nil { return word == "i" ? "I" : word }
        guard let german, !german.isValid(word) else { return word }
        let title = word.prefix(1).uppercased() + word.dropFirst()
        return german.isValid(title) ? title : word
    }

    private func spatialSpelling(_ candidate: SpatialWordDecoder.Candidate, token: String) -> (text: String, validated: Bool) {
        let plain = Self.matchCase(of: token, onto: candidate.word)
        if candidate.language == .english { return (plain, checker.isWordValid(plain)) }
        let guesses = germanGuesses(for: token)
        if let cached = spellingCache?.spatial[candidate.word] { return cached }
        // FrequencyWords is lowercase: German casing comes only from an exact system guess.
        let spelling: (text: String, validated: Bool)
        if let guess = guesses.first(where: { $0.lowercased() == candidate.word }), german?.isValid(guess) == true {
            spelling = (Self.matchCase(of: token, onto: guess), true)
        } else if candidate.language == nil, englishEnabled, checker.isWordValid(plain) {
            spelling = (plain, true)
        } else {
            spelling = (plain, false)
        }
        spellingCache?.spatial[candidate.word] = spelling
        return spelling
    }

    /// `UITextChecker` completions in today's displayed order (length, then alphabetical),
    /// cased like the token. Computed once per token for both ranking and fallback.
    private func systemCompletions(for token: String) -> [String] {
        if spellingCache?.token != token { spellingCache = SpellingCache(token: token) }
        if let cached = spellingCache?.systemCompletions { return cached }
        let checked = checker.completions(for: token)
            .filter { $0.count > token.count && $0.count <= token.count + 8 }
            .sorted { a, b in
                if a.count != b.count { return a.count < b.count }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { Self.matchCase(of: token, onto: $0) }
        spellingCache?.systemCompletions = checked
        return checked
    }

    /// The personal store is case-folded: restore a noun/proper-noun capital only when an
    /// enabled dictionary confirms it, otherwise follow the typed prefix's case.
    private func personalSpelling(_ word: String, token: String) -> String {
        let title = word.prefix(1).uppercased() + word.dropFirst()
        var spelling = word
        if let german, !german.isValid(word), german.isValid(title) {
            spelling = title
        } else if englishEnabled, !checker.isWordValid(word), checker.isWordValid(title) {
            spelling = title
        }
        return Self.matchCase(of: token, onto: spelling)
    }

    private func germanGuesses(for token: String) -> [String] {
        if spellingCache?.token != token { spellingCache = SpellingCache(token: token) }
        if let guesses = spellingCache?.germanGuesses { return guesses }
        let guesses = german?.guesses(for: token) ?? []
        spellingCache?.germanGuesses = guesses
        return guesses
    }

    // MARK: - Correction policy

    /// Manual alternatives only. Never changes Space authority or infers a touch label.
    private func orthographySuggestion(_ token: String, context: KeyboardContextModel.Context?) -> String? {
        let lower = token.lowercased()
        guard token.count <= 32, !token.dropFirst().contains(where: \.isUppercase),
              !protectedLexicon.contains(token), !lexiconTermKeys.contains(lower),
              !suppressedInSession.contains(lower), !learning.protections.isKept(token),
              !Self.shorthandAllowlist.contains(lower), lexiconShortcuts[lower] == nil else { return nil }
        var candidate: String?
        if let german, let context, context.canPredict, context.state.weightDE >= 0.70,
           !(englishEnabled && checker.isWordValid(token)) {
            candidate = german.nounSuggestion(token, after: context.previous)
        }
        if candidate == nil, englishEnabled, german?.blocksEnglishFix(lower) != true {
            candidate = Self.suggestOnlyContractions[lower]
            // Translate iikb Corrector.contraction's apostrophe-at-an-internal-boundary
            // candidate recognition, not its posterior-based automatic authority.
            // Valid literals (including plurals with valid possessives) need no search;
            // valid contraction homographs are handled by the manual table above.
            if candidate == nil, (3...32).contains(token.count), lower.utf8.allSatisfy({ (97...122).contains($0) }),
               !checker.isWordValid(token), !checker.isWordValid(lower) {
                let letters = Array(lower)
                for index in 1..<letters.count {
                    let spelling = String(letters[..<index]) + "'" + String(letters[index...])
                    if checker.isWordValid(spelling) { candidate = spelling; break }
                }
            }
        }
        guard let candidate else { return nil }
        let cased = Self.matchCase(of: token, onto: candidate)
        guard !learning.protections.isRejected(typed: token, replacement: cased, context: rejectionContext) else { return nil }
        return cased
    }

    private func automatic(_ text: String, token: String, kind: CorrectionKind,
                           counter: KeyboardDiagnostics.Counter, alignment: [Int?]? = nil) -> Decision {
        guard text != token else { return Decision() }
        // An inferred suffix is a manual completion, never an automatic boundary edit.
        // Explicit text replacements and deterministic rules keep their existing authority.
        if (kind == .autoSpatial || kind == .autoSpelling), Self.isPrefixExtension(text, of: token) {
            return Decision(refusal: .refusedBelowMargin)
        }
        guard !learning.protections.isRejected(typed: token, replacement: text, context: rejectionContext) else {
            return Decision(refusal: .refusedProtected)
        }
        return Decision(text: text, kind: kind, counter: counter, alignment: alignment)
    }

    /// One correction path, in order: explicit text replacement, deterministic DE/EN rules,
    /// context guards, protections, spatial decoder on complete evidence, spelling-only fallback.
    /// Explicit keeps and shorthand veto everything, as the learned-word protection did.
    private func decide(_ token: String, evidence: KeyboardTouchWord?, forSuggestions: Bool) -> Decision {
        let lower = token.lowercased()
        guard !protectedLexicon.contains(token),
              !suppressedInSession.contains(lower), !learning.protections.isKept(token),
              !Self.shorthandAllowlist.contains(lower) else { return Decision(refusal: .refusedProtected) }
        // 1. Explicit iOS Text Replacement (`omw` -> `On my way!`).
        if let shortcut = lexiconShortcuts[lower] {
            return automatic(shortcut, token: token, kind: .autoRule, counter: .autoRule)
        }
        // Leave ALL-CAPS acronyms (`API`, `PR`, `NYC`) alone unless matched in `UILexicon` above,
        // except unambiguous all-caps contractions/typos of 3+ letters (`DONT` -> `DON'T`, `TEH` -> `THE`).
        let isAllCaps = token.count >= 2 && token == token.uppercased() && token != lower
        // Leave camelCase / PascalCase identifiers (`TyprKey`, `iOS`) alone.
        let hasInternalCaps = token.dropFirst().contains(where: \.isUppercase) && !isAllCaps
        guard !hasInternalCaps else { return Decision(refusal: .refusedProtected) }

        // 2. Deterministic rules. Typr: German umlaut digraphs first, so `FUER` -> `FÜR`.
        if let german,
           let umlaut = german.umlautReplacement(
               for: token,
               englishValid: englishEnabled && (checker.isWordValid(token) || checker.isWordValid(lower))
           ) {
            return automatic(umlaut, token: token, kind: .autoRule, counter: .autoRule)
        }
        if englishEnabled, let fixed = Self.unambiguousFixes[lower], german?.blocksEnglishFix(lower) != true {
            if isAllCaps && token.count < 3 { return Decision(refusal: .refusedProtected) }
            return automatic(Self.matchCase(of: token, onto: fixed), token: token, kind: .autoRule, counter: .autoRule)
        }

        // A valid contraction homograph is manual-only even if a device dictionary
        // omits it or spelling/spatial guesses prefer the apostrophe form.
        if englishEnabled, Self.suggestOnlyContractions[lower] != nil {
            return Decision(refusal: .refusedLiteralValid)
        }

        // 3. Context guards: inferred corrections only for plain words of 3+ letters.
        guard !isAllCaps else { return Decision(refusal: .refusedProtected) }
        guard token.count >= 3, !token.contains("'"), !token.contains("’") else { return Decision() }

        // 4. Protections: Contacts/lexicon terms and words valid in an enabled dictionary.
        guard !lexiconTermKeys.contains(lower) else { return Decision(refusal: .refusedProtected) }
        guard !dictionaryAcceptsLiteral(token) else { return Decision(refusal: .refusedLiteralValid) }

        // 5. Spatial decoder. Only a complete search may replace; a lowercase-typed German noun
        //    (`haus`, valid as `Haus`) is protected from becoming a different word.
        var refusal: KeyboardDiagnostics.Counter?
        switch spatialOutcome(for: token, evidence: evidence, forSuggestions: forSuggestions) {
        case nil, .unavailable(.evidence)?:
            break
        case .unavailable(.resource)?:
            refusal = spatialDecoder?.isResourceLoading == true ? .resourceLoading : .refusedMissingResource
        case .result(let result)?:
            switch result.automaticDecision(literalIsValid: false) {
            case .replace(let best):
                let spelling = spatialSpelling(best, token: token)
                if spelling.validated {
                    let decision = automatic(spelling.text, token: token, kind: .autoSpatial,
                                             counter: best.edit == .none ? .autoSpatialSameLength : .autoSpatialEdit,
                                             alignment: best.alignment)
                    if decision.text != nil { return decision }
                    refusal = decision.refusal
                } else {
                    refusal = .refusedValidation
                }
            case .refuse(let reason):
                refusal = switch reason {
                case .incompleteSearch: .refusedIncompleteSearch
                case .ambiguous: .refusedAmbiguous
                case .editNeedsInvalidLiteral: .refusedLiteralValid // Defensive: valid literals are guarded above.
                case .noCandidate, .belowMargin: .refusedBelowMargin
                }
            }
            // #96: only geometry that genuinely points elsewhere vetoes the spelling fallback;
            // prior-promoted, geometrically worse neighbours do not. An incomplete search never
            // authorizes any inferred replacement.
            if !result.complete || result.geometryPrefersAlternative { return Decision(refusal: refusal) }
        }

        // 6. Spelling-only fallback. Typr: German guesses win over English ones.
        if let german {
            var germanBest: String?
            var germanScore = Double.greatestFiniteMagnitude
            for (rank, rawGuess) in germanGuesses(for: token).enumerated() {
                guard !rawGuess.contains(" ") else { continue }
                let normalized = rawGuess.replacingOccurrences(of: "'", with: "").lowercased()
                guard let cost = german.costAdjustedForUmlauts(from: lower, to: normalized) else { continue }
                let total = cost + Double(rank) * 0.08
                if total < germanScore {
                    germanScore = total
                    germanBest = rawGuess
                }
            }
            if let germanBest, germanScore <= 1.6 {
                var decision = automatic(Self.matchCase(of: token, onto: germanBest), token: token,
                                         kind: .autoSpelling, counter: .autoSpellingFallback)
                decision.refusal = decision.refusal ?? refusal
                return decision
            }
        }

        guard englishEnabled else { return Decision(refusal: refusal) }
        var bestGuess: String?
        var bestScore = Double.greatestFiniteMagnitude
        for (rank, rawGuess) in checker.guesses(for: token).prefix(8).enumerated() {
            // Skip multi-word splits (`alot` -> `a lot` is fine only if single space, keep v1 single-token + apostrophe).
            guard !rawGuess.contains(" ") else { continue }
            let normalizedGuess = rawGuess.replacingOccurrences(of: "'", with: "").lowercased()
            guard let editCost = Self.singleEditKeyboardCost(from: lower, to: normalizedGuess) else { continue }
            let totalScore = editCost + Double(rank) * 0.08
            if totalScore < bestScore {
                bestScore = totalScore
                bestGuess = rawGuess
            }
        }
        guard let bestGuess, bestScore <= 1.35 else { return Decision(refusal: refusal) }
        var decision = automatic(Self.matchCase(of: token, onto: bestGuess), token: token,
                                 kind: .autoSpelling, counter: .autoSpellingFallback)
        decision.refusal = decision.refusal ?? refusal
        return decision
    }

    private func rankedGuesses(for token: String) -> [String] {
        let lower: String = token.lowercased()
        let tokenCount: Int = token.count
        // Explicit types keep this sort comparator cheap to type-check.
        let rankedCost: (Int, String) -> Double = { (offset: Int, guess: String) -> Double in
            let normalized: String = guess.replacingOccurrences(of: "'", with: "").lowercased()
            let lengthGap: Double = Double(abs(guess.count - tokenCount))
            let fallback: Double = 2.0 + lengthGap * 0.3
            let cost: Double = Self.singleEditKeyboardCost(from: lower, to: normalized) ?? fallback
            return cost + Double(offset) * 0.08
        }
        let candidates: [(offset: Int, element: String)] = Array(checker.guesses(for: token).prefix(8).enumerated())
        let sorted: [(offset: Int, element: String)] = candidates.sorted { (a: (offset: Int, element: String), b: (offset: Int, element: String)) -> Bool in
            rankedCost(a.offset, a.element) < rankedCost(b.offset, b.element)
        }
        return sorted.map { (pair: (offset: Int, element: String)) -> String in pair.element }
    }

    // MARK: - Case matching & QWERTY distance

    static func matchCase(of typed: String, onto target: String) -> String {
        guard !typed.isEmpty, !target.isEmpty else { return target }
        if typed.count >= 2 && typed == typed.uppercased() && typed != typed.lowercased() {
            return target.uppercased()
        }
        // Preserve intentional casing in `I`, `I'm`, `iPhone`, etc. unless `typed` started capitalized.
        if target != target.lowercased() {
            if typed.first?.isUppercase == true, let first = target.first, first.isLowercase {
                return first.uppercased() + target.dropFirst()
            }
            return target
        }
        if typed.first?.isUppercase == true, let first = target.first {
            return first.uppercased() + target.dropFirst()
        }
        return target
    }

    /// Returns a weighted cost if `source` and `target` are within 1 Damerau-Levenshtein edit; `nil` otherwise.
    static func singleEditKeyboardCost(from source: String, to target: String) -> Double? {
        if source == target { return 0 }
        let s = Array(source)
        let t = Array(target)
        let ds = s.count - t.count
        guard abs(ds) <= 1 else { return nil }

        if ds == 0 {
            var diffs: [Int] = []
            for i in 0..<s.count where s[i] != t[i] {
                diffs.append(i)
                if diffs.count > 2 { return nil }
            }
            if diffs.count == 1 {
                let i = diffs[0]
                return areAdjacentKeys(s[i], t[i]) ? 0.65 : 1.15
            }
            if diffs.count == 2, diffs[1] == diffs[0] + 1,
               s[diffs[0]] == t[diffs[1]], s[diffs[1]] == t[diffs[0]] {
                return 0.60
            }
            return nil
        }

        // Single insertion or deletion.
        let (shorter, longer) = s.count < t.count ? (s, t) : (t, s)
        var i = 0
        var j = 0
        var skippedIndex: Int?
        while i < shorter.count && j < longer.count {
            if shorter[i] == longer[j] {
                i += 1
                j += 1
            } else if skippedIndex == nil {
                skippedIndex = j
                j += 1
            } else {
                return nil
            }
        }
        let extraIdx = skippedIndex ?? (longer.count - 1)
        let extraChar = longer[extraIdx]
        let leftAdj = extraIdx > 0 && areAdjacentKeys(extraChar, longer[extraIdx - 1])
        let rightAdj = extraIdx + 1 < longer.count && areAdjacentKeys(extraChar, longer[extraIdx + 1])
        return (leftAdj || rightAdj) ? 0.70 : 0.90
    }

    private static let keyCoordinates: [Character: (Double, Double)] = {
        var map: [Character: (Double, Double)] = [:]
        for (col, ch) in "qwertyuiop".enumerated() { map[ch] = (0, Double(col)) }
        for (col, ch) in "asdfghjkl".enumerated() { map[ch] = (1, Double(col) + 0.5) }
        for (col, ch) in "zxcvbnm".enumerated() { map[ch] = (2, Double(col) + 1.5) }
        return map
    }()

    static func areAdjacentKeys(_ a: Character, _ b: Character) -> Bool {
        guard let pa = keyCoordinates[a], let pb = keyCoordinates[b] else { return false }
        let dx = pa.1 - pb.1
        let dy = pa.0 - pb.0
        return (dx * dx + dy * dy).squareRoot() <= 1.6
    }

    // MARK: - Built-in dictionaries

    /// Valid words where an apostrophe form exists, offered as a suggestion without clobbering the word.
    static let suggestOnlyContractions: [String: String] = [
        "ill": "I'll",
        "wont": "won't",
        "cant": "can't",
        "id": "I'd",
        "were": "we're",
        "wed": "we'd",
        "well": "we'll",
        "its": "it's",
        "lets": "let's",
        "hell": "he'll",
        "shell": "she'll",
    ]

    /// Common chat & engineering shorthand that cautious autocorrect never rewrites.
    static let shorthandAllowlist: Set<String> = [
        "ok", "okay", "ty", "thx", "pls", "plz", "tmrw", "tbh", "idk", "imo", "imho",
        "lol", "lmao", "omg", "brb", "btw", "afaik", "fyi", "nvm", "rn", "irl", "jk",
        "np", "yw", "smh", "ikr", "ngl", "fr", "gg", "dm", "pr", "prs", "ci", "ui",
        "ux", "ios", "macos", "api", "apis", "url", "urls", "json", "sql", "ssh", "cli",
        "gpu", "cpu", "ram", "sdk", "typr", "hex", "wisp", "seer", "rune", "kit", "gonna",
        "wanna", "gotta", "kinda", "sorta", "yeah", "yep", "nope", "nah", "hey", "yo",
    ]

    /// ~125 unambiguous missing-apostrophe contractions and high-frequency QWERTY transpositions.
    static let unambiguousFixes: [String: String] = [
        // Pronoun & missing-apostrophe contractions
        "i": "I",
        "im": "I'm",
        "ive": "I've",
        "dont": "don't",
        "didnt": "didn't",
        "doesnt": "doesn't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "hadnt": "hadn't",
        "wouldnt": "wouldn't",
        "couldnt": "couldn't",
        "shouldnt": "shouldn't",
        "mustnt": "mustn't",
        "neednt": "needn't",
        "youre": "you're",
        "youve": "you've",
        "youd": "you'd",
        "youll": "you'll",
        "theyre": "they're",
        "theyve": "they've",
        "theyd": "they'd",
        "theyll": "they'll",
        "weve": "we've",
        "shes": "she's",
        "hes": "he's",
        "itll": "it'll",
        "thats": "that's",
        "theres": "there's",
        "heres": "here's",
        "wheres": "where's",
        "whos": "who's",
        "whats": "what's",
        "hows": "how's",
        "whens": "when's",
        "whys": "why's",
        "aint": "ain't",
        "yall": "y'all",
        "oclock": "o'clock",
        "maam": "ma'am",
        "cmon": "c'mon",
        "wouldve": "would've",
        "couldve": "could've",
        "shouldve": "should've",
        "mightve": "might've",
        "mustve": "must've",
        // High-frequency QWERTY transpositions & fat-finger typos
        "teh": "the",
        "hte": "the",
        "taht": "that",
        "thta": "that",
        "adn": "and",
        "nad": "and",
        "wiht": "with",
        "iwth": "with",
        "waht": "what",
        "hwat": "what",
        "wich": "which",
        "whcih": "which",
        "thier": "their",
        "theri": "their",
        "recieve": "receive",
        "definately": "definitely",
        "seperate": "separate",
        "occured": "occurred",
        "untill": "until",
        "abotu": "about",
        "baout": "about",
        "becuase": "because",
        "beacuse": "because",
        "jsut": "just",
        "jstu": "just",
        "knwo": "know",
        "konw": "know",
        "tiem": "time",
        "tmie": "time",
        "shoudl": "should",
        "hsould": "should",
        "woudl": "would",
        "owuld": "would",
        "coudl": "could",
        "oculd": "could",
        "ahve": "have",
        "hvae": "have",
        "maek": "make",
        "mkae": "make",
        "thign": "thing",
        "hting": "thing",
        "peopel": "people",
        "poeple": "people",
        "workign": "working",
        "goign": "going",
        "doign": "doing",
        "runnign": "running",
        "comign": "coming",
        "thnaks": "thanks",
        "htanks": "thanks",
        "plase": "please",
        "pleaes": "please",
        "yuor": "your",
        "yoru": "your",
        "yuo": "you",
        "oyu": "you",
        "fomr": "from",
        "verry": "very",
        "evrey": "every",
        "realyl": "really",
        "realy": "really",
        "actualyl": "actually",
        "probalby": "probably",
        "tomorow": "tomorrow",
        "tommorow": "tomorrow",
        "tonihgt": "tonight",
        "tongiht": "tonight",
        "mesasge": "message",
        "messgae": "message",
        "keybaord": "keyboard",
        "keboard": "keyboard",
        "iphnoe": "iPhone",
        "ipohne": "iPhone",
    ]
}
