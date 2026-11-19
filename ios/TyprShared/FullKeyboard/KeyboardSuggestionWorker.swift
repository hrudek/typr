import Foundation

/// A chip belongs to one engine, field/text revision and frozen correction configuration.
/// Context is a RAM-only suffix, never serialized. Revision also distinguishes identical text
/// in different fields or after typing away and back. UIKit field traits are represented as values.
nonisolated struct KeyboardSuggestionOwnership: Equatable, Sendable {
    let engine: UUID
    let revision: UInt64
    let context: String?
    let token: String?
    let field: KeyboardFieldKind
    let permitsCorrection: Bool
    let configuration: Int
    let learning: Int
    let feedbackEpoch: Int
    let resources: Int
    let layout: KeyboardLayout

    /// Same text, field, configuration, learning, resources and layout; revision aside.
    /// A published strip whose content no longer matches is stale and must be republished.
    func hasSameContent(as other: Self) -> Bool {
        engine == other.engine && context == other.context && token == other.token
            && field == other.field && permitsCorrection == other.permitsCorrection
            && configuration == other.configuration && learning == other.learning
            && feedbackEpoch == other.feedbackEpoch && resources == other.resources && layout == other.layout
    }
}

/// Retain what the user actually touched, not whichever ranking occupies that slot at key-up.
/// At most three pressed chips; cancellation has no fallback to a newer field's suggestion.
nonisolated struct KeyboardSuggestionSelection {
    private var pressed: [Int: KeyboardSuggestion] = [:]
    var count: Int { pressed.count }

    mutating func begin(slot: Int, suggestions: [KeyboardSuggestion]) {
        pressed.removeValue(forKey: slot)
        guard (0..<3).contains(slot), suggestions.indices.contains(slot) else { return }
        pressed[slot] = suggestions[slot]
    }

    mutating func finish(slot: Int) -> KeyboardSuggestion? { pressed.removeValue(forKey: slot) }
    mutating func cancel(slot: Int) { pressed.removeValue(forKey: slot) }
}

/// iikb's snapshot → job → revision-checked finish, translated into Typr's bounded pipeline.
/// Source: TypingEngine+Words.swift and FullKeyboardViewController.swift at
/// 09a2e9cdfbe851adff6c4646333c0a3f74ba8765 (MIT, © 2026 Bassim Shahidy).
@MainActor
final class KeyboardSuggestionWorker {
    nonisolated struct Request: Sendable {
        let ownership: KeyboardSuggestionOwnership
        let evidence: KeyboardTouchWord?
        let languages: Set<SpatialWordDecoder.Language>
        let calibration: SpatialTouchCalibration?
        let personal: PersonalLexiconSnapshot
        let lexicons: [SpatialWordDecoder.Language: SpatialWordLexicon]
        var context: KeyboardContextModel.WordContext? = nil
        var variants: [String] = []
        /// A compatible decode the main actor already holds; the identical search is not re-run.
        var ready: SpatialWordDecoder.Outcome?
        /// Display-only corpus/personal prefix retrieval for the current token, if eligible.
        var completion: KeyboardCompletionJob?
        /// The main actor already holds this job's retrieval; it is not re-run.
        var completionReady: KeyboardCompletionRetrieval?
        /// Exact split/join work is display-only and independent of touch evidence.
        var boundary: KeyboardBoundaryDecoder.Job?
        var boundaryReady: KeyboardBoundaryDecoder.Retrieval?
        /// Shared immutable corpus maps (COW); no per-request copy of their byte payload.
        var boundaryModel: KeyboardContextModel?

        /// Nothing left for the ranker: the held decode and completion retrieval are reused.
        var isSatisfied: Bool { ready != nil && (completion == nil || completionReady != nil) && (boundary == nil || boundaryReady != nil) }
    }

    nonisolated struct Result: Sendable {
        let request: Request
        let outcome: SpatialWordDecoder.Outcome?
        let seconds: Double
        /// `nil` (injected rankers, no eligible token) makes the finish step retrieve synchronously.
        var completion: KeyboardCompletionRetrieval? = nil
        var boundary: KeyboardBoundaryDecoder.Retrieval? = nil
    }

    /// One actor owns all suggestion-only mutable search memos. The boundary has its own core.
    private actor Ranker {
        private var resources: Int?
        private var ranking: SpatialWordRanking?

        func rank(_ request: Request) -> Result {
            let start = ContinuousClock.now
            if resources != request.ownership.resources {
                resources = request.ownership.resources
                ranking = SpatialWordRanking(lexicons: request.lexicons)
            }
            let outcome = request.ready ?? request.evidence.map {
                ranking!.decodeDetailed($0, languages: request.languages,
                                        calibration: request.calibration, personal: request.personal,
                                        context: request.context, variants: request.variants)
            }
            // Bounded (512 pops, eight results; ≤17 personal range queries), off the main actor.
            let completion = request.completionReady
                ?? request.completion.map { KeyboardCompletionRetrieval($0, lexicons: request.lexicons) }
            let boundary = request.boundaryReady ?? request.boundary.map {
                KeyboardBoundaryDecoder.retrieve($0, lexicons: request.lexicons, whole: outcome,
                                                 model: request.boundaryModel)
            }
            let elapsed = start.duration(to: .now).components
            return Result(request: request, outcome: outcome,
                          seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                          completion: completion,
                          boundary: boundary)
        }
    }

    private struct Pending {
        let prepare: @MainActor () -> Request?
        let finish: @MainActor (Result) -> Void
    }
    private let rank: @Sendable (Request) async -> Result
    private var latest: Pending?
    private var runner: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private(set) var isRunning = false
    var queuedCount: Int { latest == nil ? 0 : 1 }

    /// Injectable ranking is used by delayed/cancellation tests; production always uses Ranker.
    init(rank: (@Sendable (Request) async -> Result)? = nil) {
        let ranker = Ranker()
        self.rank = rank ?? { await ranker.rank($0) }
    }

    /// Preparation (including lazy personal snapshots) and checker finish are NOT on the
    /// insertion call stack. At most one running job and one replaceable latest preparation.
    func submit(prepare: @escaping @MainActor () -> Request?,
                finish: @escaping @MainActor (Result) -> Void) {
        latest = Pending(prepare: prepare, finish: finish)
        guard runner == nil else { return }
        isRunning = true
        runner = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            while let pending = self.latest {
                self.latest = nil
                let epoch = self.epoch
                guard let request = pending.prepare() else { continue }
                let result: Result
                if request.isSatisfied, let ready = request.ready {
                    result = Result(request: request, outcome: ready, seconds: 0,
                                    completion: request.completionReady, boundary: request.boundaryReady)
                } else {
                    result = await self.rank(request)
                }
                if epoch == self.epoch { pending.finish(result) }
                // Let newer key events replace the next request before doing any more work.
                await Task.yield()
            }
            self.isRunning = false
            self.runner = nil
        }
    }

    /// In-flight search is bounded, not preempted. Cancellation drops its completion and releases
    /// the queued snapshot immediately; a new request still waits behind that one search.
    func cancel() {
        epoch &+= 1
        latest = nil
    }

    func waitUntilIdle() async { await runner?.value }
}
