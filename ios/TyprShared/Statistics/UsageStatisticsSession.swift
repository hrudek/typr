import Foundation
import CoreGraphics

/// Single keyboard writer. All lexical state and recent validated labels live only in RAM.
/// A frozen retry batch is never mutated, even if the disk write succeeded before throwing.
@MainActor
final class UsageStatisticsSession {
    struct RecentLabel {
        let letter: Character
        let point: CGPoint
        let layout: KeyboardLayoutSignature
    }
    let store: UsageStatisticsStore
    private let monotonic: () -> TimeInterval
    private let now: () -> Date
    private let automaticallyFlush: Bool
    private let allowsPersistence: () -> Bool
    private var basis: UsageStatisticsSnapshot?
    private var writer: UsageWriter
    private var days: [UsageDay] = []
    private var heat: [UsageHeat] = []
    private var frozen: UsageBatch?
    private var timer: Task<Void, Never>?
    private var observer: StoreChangeObserver?
    private var previousTime: TimeInterval?
    private var lastLoadAttempt: TimeInterval?
    private var words = UsageWordTracker()
    private var completedInSession: UInt64 = 0
    private(set) var recentLabels: [RecentLabel] = []
    private(set) var sessionRevision: UInt64 = 0
    private(set) var lastError: Error?

    init(store: UsageStatisticsStore = UsageStatisticsStore(),
         monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         now: @escaping () -> Date = Date.init, automaticallyFlush: Bool = true,
         allowsPersistence: @escaping () -> Bool = { true }) {
        self.store = store; self.monotonic = monotonic; self.now = now
        self.automaticallyFlush = automaticallyFlush; self.allowsPersistence = allowsPersistence
        writer = UsageWriter(id: UUID(), beganAt: now(), sequence: 1)
        do { basis = try store.snapshot() }
        catch { lastError = error; lastLoadAttempt = monotonic() }
        observer = store.observe { [weak self] in self?.refreshGeneration() }
    }

    func refreshGeneration() {
        guard allowsPersistence() else { discardPending(); return }
        do {
            let current = try store.snapshot()
            if current.generation != basis?.generation {
                discardPending(); basis = current
                writer = .init(id: UUID(), beganAt: now(), sequence: 1)
            }
        } catch { lastError = error }
    }

    func endSession() {
        sessionRevision &+= 1
        previousTime = nil; words.clear(); completedInSession = 0; recentLabels.removeAll()
    }
    func clearRecentLabels() { recentLabels.removeAll() }
    func ignoreOpenWord() { words.ignoreOpenWord() }

    /// A semantic direct insertion, never a proxy operation. `replacement` is supplied
    /// only for an actual autocorrection boundary, and only words begun here earn credit.
    func direct(_ text: String, boundaryReplacement: String? = nil) {
        guard prepare() else { return }
        var totals = measured(graphemes: UInt64(text.count))
        totals.directGraphemes = UInt64(text.count)
        if let replacement = boundaryReplacement, words.hasWord {
            words.clear()
            totals.completedWords = UsageWordTracker.count(replacement)
        } else { totals.completedWords = words.feed(text) }
        completedInSession = min(UsageTotals.ceiling, completedInSession + totals.completedWords)
        append(totals)
    }
    func deletion(wholeWord: Bool = false, undo: Bool = false, removedGraphemes: Int = 1) {
        guard prepare() else { return }
        var totals = measured(graphemes: 0); totals.deletions = 1
        if wholeWord || undo { words.clear() }
        else { for _ in 0..<removedGraphemes { words.delete() } }
        append(totals)
    }
    func suggestion(_ replacement: String, boundaryOriginal: String?) {
        guard prepare() else { return }
        var totals = UsageTotals(); totals.suggestions = 1
        let count = UsageWordTracker.count(replacement)
        // A boundary chip may replace a predecessor already counted at Space. Do not
        // count that predecessor again. Never subtract more than our own session credit.
        let alreadyCompleted: UInt64 = boundaryOriginal.map {
            let total = UsageWordTracker.count($0)
            return total > 0 && words.hasWord ? total - 1 : total
        } ?? 0
        let credit = min(completedInSession, alreadyCompleted)
        totals.completedWords = count > credit ? count - credit : 0
        words.clear(); previousTime = nil
        completedInSession = min(UsageTotals.ceiling, completedInSession + totals.completedWords)
        append(totals)
    }
    private func measured(graphemes: UInt64) -> UsageTotals {
        var totals = UsageTotals()
        let time = monotonic()
        if let previousTime {
            let delta = time - previousTime
            if delta.isFinite, delta > 0, delta <= 4 {
                totals.typingSeconds = delta; totals.timedGraphemes = graphemes
            }
        }
        previousTime = time.isFinite ? time : nil
        return totals
    }
    private func prepare() -> Bool {
        guard allowsPersistence() else {
            discardPending(); lastError = UsageStatisticsStore.Failure.unavailable
            return false
        }
        if basis == nil {
            let tick = monotonic()
            if let lastLoadAttempt, tick >= lastLoadAttempt, tick - lastLoadAttempt < 1 { return false }
            lastLoadAttempt = tick
            do {
                basis = try store.snapshot(); lastError = nil
                writer = .init(id: UUID(), beganAt: now(), sequence: 1)
            } catch { lastError = error; return false }
        }
        return true
    }
    private func append(_ totals: UsageTotals) {
        guard let basis else { return }
        let day = basis.dayID(now())
        if let index = days.firstIndex(where: { $0.id == day }) { days[index].totals.add(totals) }
        else {
            if days.count == 90 { days.removeFirst() }
            days.append(.init(id: day, totals: totals))
        }
        scheduleFlush()
    }
    func recordHeat(point: CGPoint, layout: KeyboardLayout) {
        guard prepare(), let signature = Self.heatSignature(layout),
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x < layout.width, point.y >= 0,
              point.y < KeyboardLayout.height(for: layout.orientation, showsStrip: layout.showsStrip) else { return }
        let x = Int(point.x / layout.width * CGFloat(UsageHeat.columns))
        let height = KeyboardLayout.height(for: layout.orientation, showsStrip: layout.showsStrip)
        let y = Int(point.y / height * CGFloat(UsageHeat.rows))
        let id = "g1-\(signature.id)"
        if !heat.contains(where: { $0.id == id }) {
            if heat.count == 4 {
                heat.sort { $0.updatedAt < $1.updatedAt }
                heat.removeFirst()
            }
            heat.append(.init(layout: signature, geometryVersion: 1,
                              cells: Array(repeating: 0, count: UsageHeat.columns * UsageHeat.rows), updatedAt: now()))
        }
        guard let index = heat.firstIndex(where: { $0.id == id }) else { return }
        let cell = y * UsageHeat.columns + x
        heat[index].cells[cell] = min(UsageTotals.ceiling, heat[index].cells[cell] + 1)
        heat[index].updatedAt = now()
        scheduleFlush()
    }
    static func heatSignature(_ layout: KeyboardLayout) -> KeyboardLayoutSignature? {
        guard layout.layer == .letters, layout.field == .text, layout.horizontalInset == 0,
              layout.width.isFinite, (8...4096).contains(layout.width),
              KeyboardLayout.height(for: layout.orientation, showsStrip: layout.showsStrip) > 0 else { return nil }
        return KeyboardLayoutSignature(layout)
    }
    func validatedLabel(_ label: TouchLabel, layout: KeyboardLayout) {
        guard let signature = Self.heatSignature(layout) else { return }
        if recentLabels.last?.layout != signature { recentLabels.removeAll() }
        if recentLabels.count == 128 { recentLabels.removeFirst() }
        recentLabels.append(.init(letter: label.letter, point: label.point, layout: signature))
    }
    private func scheduleFlush() {
        guard automaticallyFlush, timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil; self.flush()
        }
    }
    private func discardPending() {
        frozen = nil; days.removeAll(); heat.removeAll(); endSession(); basis = nil; lastLoadAttempt = nil
    }
    func flush() {
        timer?.cancel(); timer = nil
        guard allowsPersistence() else { discardPending(); return }
        guard let basis else { return }
        do {
            // First retry the exact frozen contents. Newer edits remain in days/heat.
            if let frozen { try store.apply(frozen); self.frozen = nil }
            if !days.isEmpty || !heat.isEmpty {
                let batch = UsageBatch(generation: basis.generation, writer: writer, days: days, heat: heat)
                frozen = batch; days.removeAll(); heat.removeAll()
                // Reserve the next sequence BEFORE I/O, including failed acknowledgement.
                writer.sequence += 1
                try store.apply(batch); frozen = nil
            }
            let current = try store.snapshot()
            if current.generation != basis.generation { endSession() }
            self.basis = current; lastError = nil
            if now().timeIntervalSince(writer.beganAt) > 23 * 3600, frozen == nil {
                writer = .init(id: UUID(), beganAt: now(), sequence: 1)
            }
        } catch {
            lastError = error
            if let failure = error as? UsageStatisticsStore.Failure {
                if [.staleGeneration, .expired].contains(failure) {
                    discardPending()
                } else if failure == .capacity {
                    // A permanently oversized batch must not block newer events.
                    // Do not retry it under another identity: it may have committed.
                    frozen = nil
                    writer = .init(id: UUID(), beganAt: now(), sequence: 1)
                }
            }
        }
    }
}
