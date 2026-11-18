import Foundation

/// One model session for one dictation: Hex's `generate(prompt)`.
@MainActor
protocol CleanupSession: AnyObject {
    func prewarm() async
    /// The model's answer to the whole prompt (`CleanupPrompt.make`).
    func generate(_ prompt: String) async throws -> String
}

@MainActor
protocol TyprTranscriptCleaning {
    /// Fresh availability, never the UI's cached value.
    var unavailableReason: String? { get }
    func makeSession() -> any CleanupSession
}

@MainActor
protocol BackgroundTaskStarting {
    /// nil represents UIKit's invalid token; it must never be ended.
    func begin(expiration: @escaping @MainActor () -> Void) -> Int?
    func end(_ token: Int)
}

@MainActor
struct TranscriptCleanupDependencies {
    let cleaner: any TyprTranscriptCleaning
    let background: any BackgroundTaskStarting
    let isEnabled: @MainActor () -> Bool
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var observer: any CleanupObserving = CleanupLogger()
    var clock: @MainActor () -> ContinuousClock.Instant = { .now }
}

/// Owns a capture's background lease independently of the model operation's lifetime.
@MainActor
final class CleanupJob {
    let id = UUID()
    let session: any CleanupSession
    private let background: any BackgroundTaskStarting
    private var token: Int?
    private(set) var expired = false
    private(set) var permitted = false
    private var ended = false
    var onExpiry: (@MainActor () -> Void)?

    init(session: any CleanupSession, background: any BackgroundTaskStarting) {
        self.session = session
        self.background = background
    }

    func begin() {
        let acquired = background.begin { [weak self] in
            guard let self else { return }
            self.expired = true
            self.permitted = false
            self.onExpiry?()
            self.finish()
        }
        // Expiration is allowed to run synchronously, before begin returns its token.
        if ended {
            if let acquired { background.end(acquired) }
        } else {
            token = acquired
            permitted = acquired != nil && !expired
        }
    }

    func finish() {
        guard !ended else { return }
        ended = true
        permitted = false
        onExpiry = nil
        if let token { background.end(token) }
        token = nil
    }
}

/// A cancelled/timed-out model retains the sole reservation until it really returns.
/// Unstructured tasks are intentional: structured task groups would await an uncooperative model.
@MainActor
final class CleanupCoordinator {
    /// How long a short dictation waits for the model before the plain transcript is used.
    static let deadline: Duration = .seconds(4)
    /// The longest wait, for the longest dictations.
    static let maximumDeadline: Duration = .seconds(12)

    /// Four seconds up to 400 UTF-8 bytes, then one more second per 150 bytes, at most twelve:
    /// generation time grows with the answer's length, and a one-minute dictation (about 750 bytes)
    /// ran past a flat four seconds on the owner's iPhone.
    static func deadline(forUTF8Bytes bytes: Int) -> Duration {
        let milliseconds = 4000 + max(0, bytes - 400) * 1000 / 150
        return min(maximumDeadline, .milliseconds(milliseconds))
    }

    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<String, Never>
        let raw: String
        let started: ContinuousClock.Instant
        let dependencies: TranscriptCleanupDependencies
        let diagnostics: (any CleanupTextDiagnostics)?
    }

    private(set) var reservedBy: UUID?
    private var modelTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var pending: Pending?

    func admit(_ id: UUID) -> Bool {
        guard reservedBy == nil else { return false }
        reservedBy = id
        return true
    }

    func release(_ id: UUID) {
        guard reservedBy == id else { return }
        reservedBy = nil
        modelTask = nil
    }

    func prewarm(_ job: CleanupJob) {
        guard admit(job.id) else { return }
        modelTask = Task {
            await job.session.prewarm()
            release(job.id)
        }
    }

    func cancel(_ id: UUID, outcome: CleanupOutcome = .cancelled) {
        if let pending, pending.id == id { resolve(id, value: pending.raw, outcome: outcome) }
        if reservedBy == id { modelTask?.cancel() }
    }

    private func observe(_ outcome: CleanupOutcome, started: ContinuousClock.Instant,
                         dependencies: TranscriptCleanupDependencies,
                         diagnostics: (any CleanupTextDiagnostics)? = nil, changed: Bool? = nil) {
        let elapsed = started.duration(to: dependencies.clock()).components
        let milliseconds = max(0, elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let observation = CleanupObservation(outcome: outcome, latencyMilliseconds: milliseconds)
        dependencies.observer.record(observation)
        diagnostics?.cleanupResolved(observation, changed: changed)
    }

    func recordSkip(_ reason: CleanupSkipReason, dependencies: TranscriptCleanupDependencies,
                    diagnostics: (any CleanupTextDiagnostics)? = nil) {
        observe(.skipped(reason), started: dependencies.clock(), dependencies: dependencies, diagnostics: diagnostics)
    }

    private func resolve(_ id: UUID, value: String, outcome: CleanupOutcome, changed: Bool? = nil) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        // Only the resolution winner observes; late model/deadline/cancellation paths are no-ops.
        observe(outcome, started: pending.started, dependencies: pending.dependencies,
                diagnostics: pending.diagnostics, changed: changed)
        pending.continuation.resume(returning: value)
    }

    func clean(_ raw: String, job: CleanupJob?,
               dependencies: TranscriptCleanupDependencies, skipReason: CleanupSkipReason? = nil,
               vocabulary: [String] = [], context: CleanupContext = CleanupContext(),
               diagnostics: (any CleanupTextDiagnostics)? = nil) async -> String {
        let started = dependencies.clock()
        func skip(_ reason: CleanupSkipReason) -> String {
            observe(.skipped(reason), started: started, dependencies: dependencies, diagnostics: diagnostics)
            return raw
        }
        guard !Task.isCancelled else {
            observe(.cancelled, started: started, dependencies: dependencies, diagnostics: diagnostics)
            return raw
        }
        if skipReason == .off || skipReason == .verbatim { return skip(skipReason!) }
        // Hex #949: a numbers-only transcript has nothing to rewrite. Prewarm may already have run.
        if CleanupNumbers.only(raw) { return skip(.numbersOnly) }
        if let skipReason { return skip(skipReason) }
        guard let job else { return skip(.busy) }
        if job.expired {
            observe(.failed(.expired), started: started, dependencies: dependencies, diagnostics: diagnostics)
            return raw
        }
        guard job.permitted else { return skip(.noBackgroundLease) }
        guard dependencies.cleaner.unavailableReason == nil else { return skip(.unavailable) }
        guard admit(job.id) else { return skip(.busy) }
        return await withTaskCancellationHandler {
            // No suspension between cancellation check and continuation registration on MainActor.
            guard !Task.isCancelled else {
                release(job.id)
                observe(.cancelled, started: started, dependencies: dependencies, diagnostics: diagnostics)
                return raw
            }
            let prompt = CleanupPrompt.make(raw, vocabulary: vocabulary, context: context)
            return await withCheckedContinuation { continuation in
                pending = Pending(id: job.id, continuation: continuation, raw: raw, started: started,
                                  dependencies: dependencies, diagnostics: diagnostics)
                job.onExpiry = { [weak self] in self?.cancel(job.id, outcome: .failed(.expired)) }
                modelTask = Task {
                    let modelStarted = dependencies.clock()
                    do {
                        let answer = try await job.session.generate(prompt)
                        let modelMilliseconds = dictationLogMilliseconds(from: modelStarted, to: dependencies.clock())
                        // A model that ignored cancellation and returned after its job was resolved
                        // (deadline, expiry, cancel) only reports how long it really took.
                        if pending?.id != job.id {
                            diagnostics?.modelAnswer(answer, use: .late, modelMilliseconds: modelMilliseconds)
                            let elapsed = started.duration(to: dependencies.clock()).components
                            dependencies.observer.recordLate(
                                latencyMilliseconds: max(0, elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
                            release(job.id)
                            return
                        }
                        // As Hex: the trimmed answer, or the transcript when the answer is empty.
                        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.isEmpty {
                            diagnostics?.modelAnswer(answer, use: .rejected(.emptyOutput), modelMilliseconds: modelMilliseconds)
                            resolve(job.id, value: raw, outcome: .failed(.emptyOutput))
                        } else if let reason = CleanupGuard.rejection(answer: cleaned, transcript: raw) {
                            diagnostics?.modelAnswer(answer, use: .rejected(reason), modelMilliseconds: modelMilliseconds)
                            resolve(job.id, value: raw, outcome: .failed(reason))
                        } else {
                            let changed = cleaned != raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            dependencies.observer.recordChange(changed)
                            diagnostics?.modelAnswer(answer, use: .accepted, modelMilliseconds: modelMilliseconds)
                            resolve(job.id, value: cleaned, outcome: .completed, changed: changed)
                        }
                    } catch {
                        // Thrown after resolution (usually the cancellation sent at the deadline): its time
                        // is the cancellation's, not the model's, so it reports nothing.
                        if pending?.id != job.id { release(job.id); return }
                        diagnostics?.modelFailed(modelMilliseconds: dictationLogMilliseconds(from: modelStarted, to: dependencies.clock()))
                        // Never inspect descriptions, associated contexts, prompts, or refusal explanations.
                        let reason = (error as? CleanupModelError)?.reason ?? .generationFailed
                        let outcome: CleanupOutcome = reason == .unavailable ? .skipped(.unavailable) : .failed(reason)
                        resolve(job.id, value: raw, outcome: outcome)
                    }
                    release(job.id)
                }
                deadlineTask = Task {
                    do { try await dependencies.sleep(CleanupCoordinator.deadline(forUTF8Bytes: raw.utf8.count)) } catch { return }
                    guard !Task.isCancelled, pending?.id == job.id else { return }
                    cancel(job.id, outcome: .failed(.deadline))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(job.id) }
        }
    }
}
