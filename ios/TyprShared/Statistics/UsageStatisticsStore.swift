import Foundation
import CoreFoundation
import Darwin

/// Every mutation reloads under the same cross-process lock. No stale snapshot writes.
/// Errors are explicit: an unavailable/corrupt store is not an empty history.
@MainActor
final class UsageStatisticsStore {
    enum Failure: Error, Equatable {
        case unavailable, corrupt, newerSchema, staleGeneration, expired, capacity, invalid
    }
    static let maximumBytes = 2 * 1024 * 1024
    nonisolated static let changedNotification = "dev.rudek.typr.usage-statistics-changed"
    private let directory: URL?
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    // Fault-injection fence: exercise a committed write whose acknowledgement is lost.
    private let afterCommit: (() throws -> Void)?
    private let processLock = NSLock()

    init(directory: URL? = KeyboardLearningStore.sharedDirectory,
         now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current },
         afterCommit: (() throws -> Void)? = nil) {
        self.directory = directory; self.now = now; self.timeZone = timeZone
        self.afterCommit = afterCommit
    }

    func snapshot() throws -> UsageStatisticsSnapshot {
        try withLock { root in
            let data = try readData(root)
            var snapshot = try decode(data, now: now())
            if data == nil { try write(snapshot, root: root) }
            snapshot.prune(at: now())
            return snapshot
        }
    }
    func observe(_ changed: @escaping @MainActor @Sendable () -> Void) -> StoreChangeObserver {
        StoreChangeObserver(notificationName: Self.changedNotification, changed)
    }
    func beginCapture() throws -> UsageCaptureToken {
        let snapshot = try snapshot()
        return UsageCaptureToken(id: UUID(), generation: snapshot.generation, beganAt: now())
    }
    @discardableResult
    func reset() throws -> UsageStatisticsSnapshot {
        let snapshot = try withLock { root in
            // An explicit reset repairs corrupt data, but must not downgrade a future schema.
            let resetData: Data?
            do { resetData = try readData(root) }
            catch Failure.corrupt {
                resetData = nil
                // Foundation's atomic write does not reliably replace a symbolic link.
                // Remove only the link itself, never its target, while holding the lock.
                let url = root.appendingPathComponent("statistics-v1.json")
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Failure.unavailable }
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard unlink(url.path) == 0 else { throw Failure.unavailable }
                }
            }
            if let data = resetData {
                if let header = try? JSONDecoder().decode(Header.self, from: data), header.schemaVersion > 1 {
                    throw Failure.newerSchema
                }
            }
            let fresh = UsageStatisticsSnapshot(now: now(), timeZone: timeZone())
            try write(fresh, root: root)
            return fresh
        }
        Self.postChanged()
        return snapshot
    }

    /// Acknowledged retries are successful no-ops, including after a write whose caller
    /// failed to observe the acknowledgement. Receipts expire by BEGIN time, not retry time.
    func apply(_ batch: UsageBatch) throws {
        try transaction { snapshot, date in
            guard snapshot.generation == batch.generation else { throw Failure.staleGeneration }
            try Self.validateAge(batch.writer.beganAt, now: date)
            guard batch.writer.sequence > 0, batch.days.count <= 90, batch.heat.count <= 4,
                  Set(batch.days.map(\.id)).count == batch.days.count,
                  Set(batch.heat.map(\.id)).count == batch.heat.count,
                  batch.days.allSatisfy({ $0.totals.isValid }), batch.heat.allSatisfy(\.isValid) else { throw Failure.invalid }
            if let index = snapshot.writers.firstIndex(where: { $0.id == batch.writer.id }) {
                guard snapshot.writers[index].beganAt == batch.writer.beganAt else { throw Failure.invalid }
                if batch.writer.sequence <= snapshot.writers[index].sequence { return }
                snapshot.writers[index] = batch.writer
            } else {
                // Mounting a keyboard creates a new writer. Keep bounded retry state
                // without imposing a daily limit on keyboard sessions.
                if snapshot.writers.count == 16,
                   let oldest = snapshot.writers.indices.min(by: {
                       snapshot.writers[$0].beganAt < snapshot.writers[$1].beganAt
                   }) {
                    snapshot.writers.remove(at: oldest)
                }
                snapshot.writers.append(batch.writer)
            }
            let retained = snapshot.retainedDayIDs(at: date)
            for day in batch.days {
                guard retained.contains(day.id) else { throw Failure.expired }
                snapshot.add(day.totals, day: day.id)
            }
            for heat in batch.heat {
                guard heat.updatedAt <= date, date.timeIntervalSince(heat.updatedAt) <= 86400 else { throw Failure.invalid }
                if let index = snapshot.heat.firstIndex(where: { $0.id == heat.id }) {
                    for cell in heat.cells.indices {
                        snapshot.heat[index].cells[cell] = min(UsageTotals.ceiling, snapshot.heat[index].cells[cell] + heat.cells[cell])
                    }
                    snapshot.heat[index].updatedAt = max(snapshot.heat[index].updatedAt, heat.updatedAt)
                } else {
                    if snapshot.heat.count == 4 {
                        snapshot.heat.sort { $0.updatedAt < $1.updatedAt }
                        snapshot.heat.removeFirst()
                    }
                    snapshot.heat.append(heat)
                }
            }
        }
        Self.postChanged()
    }

    func recordCapture(_ token: UsageCaptureToken, words: UInt64, seconds: Double) throws {
        try transaction { snapshot, date in
            guard snapshot.generation == token.generation else { throw Failure.staleGeneration }
            try Self.validateAge(token.beganAt, now: date)
            guard words <= UsageTotals.ceiling, seconds.isFinite, seconds > 0,
                  seconds <= 86400 else { throw Failure.invalid }
            if let receipt = snapshot.captures.first(where: { $0.id == token.id }) {
                guard receipt.beganAt == token.beganAt else { throw Failure.invalid }
                return
            }
            guard snapshot.captures.count < 2048 else { throw Failure.capacity }
            snapshot.captures.append(.init(id: token.id, beganAt: token.beganAt))
            var totals = UsageTotals()
            totals.dictations = 1; totals.dictatedWords = words; totals.recordingSeconds = seconds
            snapshot.add(totals, day: snapshot.dayID(date))
        }
        Self.postChanged()
    }

    private static func validateAge(_ beganAt: Date, now: Date) throws {
        let age = now.timeIntervalSince(beganAt)
        guard age.isFinite, (0...86400).contains(age) else { throw Failure.expired }
    }
    private func transaction<T>(_ work: (inout UsageStatisticsSnapshot, Date) throws -> T) throws -> T {
        try withLock { root in
            let date = now()
            var snapshot = try decode(readData(root), now: date)
            snapshot.prune(at: date)
            let result = try work(&snapshot, date)
            guard snapshot.isValid else { throw Failure.invalid }
            try write(snapshot, root: root)
            try afterCommit?()
            return result
        }
    }
    nonisolated private struct Header: Decodable { let schemaVersion: Int }
    private func decode(_ data: Data?, now: Date) throws -> UsageStatisticsSnapshot {
        guard let data else { return .init(now: now, timeZone: timeZone()) }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.schemaVersion > 1 { throw Failure.newerSchema }
            guard header.schemaVersion == 1 else { throw Failure.corrupt }
            let snapshot = try JSONDecoder().decode(UsageStatisticsSnapshot.self, from: data)
            guard snapshot.isValid else { throw Failure.corrupt }
            return snapshot
        } catch let error as Failure { throw error }
        catch { throw Failure.corrupt }
    }
    private func readData(_ root: URL) throws -> Data? {
        let url = root.appendingPathComponent("statistics-v1.json")
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= Self.maximumBytes else { throw Failure.corrupt }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw Failure.corrupt }
        return data
    }
    private func write(_ snapshot: UsageStatisticsSnapshot, root: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw Failure.capacity }
        let url = root.appendingPathComponent("statistics-v1.json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try protect(url, isDirectory: false)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func protect(_ url: URL, isDirectory: Bool) throws {
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard info.isSymbolicLink != true,
              (isDirectory ? info.isDirectory == true : info.isRegularFile == true) else { throw Failure.unavailable }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            .posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func withLock<T>(_ work: (URL) throws -> T) throws -> T {
        guard let directory else { throw Failure.unavailable }
        processLock.lock(); defer { processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory, isDirectory: true)
        let file = directory.appendingPathComponent("statistics.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unavailable }
        var locked = false
        for _ in 0..<3 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
        }
        guard locked else { throw Failure.unavailable }
        defer { _ = flock(fd, LOCK_UN) }
        try protect(file, isDirectory: false)
        return try work(directory)
    }
    nonisolated private static func postChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotification as CFString), nil, nil, true)
    }
}
