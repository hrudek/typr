import Foundation
import Observation

@MainActor @Observable
final class StatisticsModel {
    private(set) var usage: UsageStatisticsSnapshot?
    private(set) var learning: KeyboardLearningSnapshot?
    private(set) var problem: String?
    private(set) var resetProblem: String?
    @ObservationIgnored private var fixture: StatisticsFixture?
    @ObservationIgnored private var fixtureUsageReset = false
    @ObservationIgnored private var tapCache: [String: TapStatistics] = [:]
    @ObservationIgnored private let store: UsageStatisticsStore
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var usageObserver: StoreChangeObserver?
    @ObservationIgnored private var learningObserver: StoreChangeObserver?

    init(directory: URL? = KeyboardLearningStore.sharedDirectory,
         defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup),
         fixture: StatisticsFixture? = nil) {
        self.fixture = fixture
        self.directory = directory; self.defaults = defaults
        store = UsageStatisticsStore(directory: directory)
        refresh()
        guard fixture == nil else { return }
        usageObserver = store.observe { [weak self] in self?.refresh() }
        learningObserver = KeyboardLearningObserver { [weak self] in self?.refresh() }
    }
    func refresh() {
        tapCache.removeAll()
        if let fixture {
            let snapshots = fixture.snapshots()
            learning = snapshots.1
            if !fixtureUsageReset { usage = snapshots.0 }
            problem = fixture == .unavailable && !fixtureUsageReset ? "Synthetic unavailable statistics." : nil
            return
        }
        do { usage = try store.snapshot(); problem = nil }
        catch {
            usage = nil
            problem = "Statistics are unavailable. Typr could not read its shared storage. Try again or reset statistics."
        }
        let snapshot = KeyboardLearningStore.readSnapshot(directory: directory, defaults: defaults)
        learning = snapshot.isPersistent && snapshot.modelAvailable ? snapshot : nil
    }
    func presentationDate(at date: Date) -> Date {
        fixture == nil ? date : StatisticsFixture.referenceDate
    }

    var signatures: [KeyboardLayoutSignature] {
        let heat = usage?.heat.map { ($0.layout, $0.updatedAt) } ?? []
        let saved = learning?.model.layouts.map { ($0.signature, $0.lastUpdated) } ?? []
        var seen = Set<String>()
        return (heat + saved).sorted {
            $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1
        }.compactMap { seen.insert($0.0.id).inserted ? $0.0 : nil }
    }
    func taps(for signature: KeyboardLayoutSignature) -> TapStatistics {
        if let cached = tapCache[signature.id] { return cached }
        let taps = TapStatistics(signature: signature,
                                 model: learning?.model.layouts.first { $0.signature == signature },
                                 heat: usage?.heat.first { $0.layout == signature })
        tapCache[signature.id] = taps
        return taps
    }
    func reset() {
        tapCache.removeAll()
        if fixture != nil {
            fixtureUsageReset = true
            usage = UsageStatisticsSnapshot(now: StatisticsFixture.referenceDate, timeZone: TimeZone(secondsFromGMT: 0)!)
            problem = nil; resetProblem = nil
            return
        }
        do { _ = try store.reset(); resetProblem = nil }
        catch { resetProblem = "Could not reset statistics. Saved data has not been confirmed as cleared." }
        refresh()
    }
}
