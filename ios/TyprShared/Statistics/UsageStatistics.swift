import Foundation

/// Text-free additive populations. Counts describe edit events, not document contents.
nonisolated struct UsageTotals: Codable, Equatable, Sendable {
    static let ceiling: UInt64 = 1_000_000_000_000
    static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (0...253_402_214_400).contains(seconds)
    }
    var directGraphemes: UInt64 = 0
    var timedGraphemes: UInt64 = 0
    var deletions: UInt64 = 0
    var suggestions: UInt64 = 0
    var completedWords: UInt64 = 0
    var typingSeconds: Double = 0
    var dictations: UInt64 = 0
    var dictatedWords: UInt64 = 0
    var recordingSeconds: Double = 0

    // Speeds need 60 s of their own population and always use summed totals, never an
    // average of daily speeds. Typing uses 5-grapheme standard words over active intervals
    // (<= 4 s); dictation uses raw recognized words over stopped capture duration.
    var typingWPM: Double? { typingSeconds >= 60 ? Double(timedGraphemes) * 12 / typingSeconds : nil }
    var dictationWPM: Double? { recordingSeconds >= 60 ? Double(dictatedWords) * 60 / recordingSeconds : nil }
    var isValid: Bool {
        [directGraphemes, timedGraphemes, deletions, suggestions, completedWords, dictations, dictatedWords]
            .allSatisfy { $0 <= Self.ceiling }
            && timedGraphemes <= directGraphemes
            && [typingSeconds, recordingSeconds].allSatisfy { $0.isFinite && (0...Double(Self.ceiling)).contains($0) }
    }
    mutating func add(_ other: Self) {
        func sum(_ a: UInt64, _ b: UInt64) -> UInt64 { min(Self.ceiling, min(Self.ceiling, a) + min(Self.ceiling, b)) }
        directGraphemes = sum(directGraphemes, other.directGraphemes)
        timedGraphemes = sum(timedGraphemes, other.timedGraphemes)
        deletions = sum(deletions, other.deletions)
        suggestions = sum(suggestions, other.suggestions)
        completedWords = sum(completedWords, other.completedWords)
        dictations = sum(dictations, other.dictations)
        dictatedWords = sum(dictatedWords, other.dictatedWords)
        typingSeconds = min(Double(Self.ceiling), typingSeconds + other.typingSeconds)
        recordingSeconds = min(Double(Self.ceiling), recordingSeconds + other.recordingSeconds)
    }
}

nonisolated struct UsageDay: Codable, Equatable, Sendable {
    let id: String
    var totals = UsageTotals()
}

/// Fixed measured density, never a label or a model estimate. Geometry 1: letter/text,
/// zero inset only; normalized board coordinates, separate orientation/width/accessories/split arrangement.
nonisolated struct UsageHeat: Codable, Equatable, Sendable {
    static let columns = 64
    static let rows = 24
    let layout: KeyboardLayoutSignature
    let geometryVersion: Int
    var cells: [UInt64]
    var updatedAt: Date
    var id: String { "g\(geometryVersion)-\(layout.id)" }
    var isValid: Bool {
        geometryVersion == 1 && layout.isValid
            && cells.count == Self.columns * Self.rows && cells.allSatisfy { $0 <= UsageTotals.ceiling }
            && UsageTotals.validDate(updatedAt)
    }
}

nonisolated struct UsageStatisticsSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generation: UUID
    let startedAt: Date
    let timeZone: String
    var days: [UsageDay] = []
    var heat: [UsageHeat] = []
    var writers: [UsageWriter] = []
    var captures: [UsageCaptureReceipt] = []

    init(now: Date, timeZone: TimeZone) {
        schemaVersion = 1; generation = UUID(); startedAt = now; self.timeZone = timeZone.identifier
    }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    func dayID(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func retainedDayIDs(at now: Date) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set((0..<90).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.map(dayID))
    }
    func totals(lastDays: Int, at now: Date) -> UsageTotals {
        let today = calendar.startOfDay(for: now)
        let ids = Set((0..<min(90, max(0, lastDays))).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }.map(dayID))
        return days.filter { ids.contains($0.id) }.reduce(into: UsageTotals()) { $0.add($1.totals) }
    }
    var isValid: Bool {
        schemaVersion == 1 && TimeZone(identifier: timeZone) != nil && UsageTotals.validDate(startedAt)
            && days.count <= 90 && Set(days.map(\.id)).count == days.count
            && days.allSatisfy { day in
                let parts = day.id.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3, day.id.count == 10,
                      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
                return dayID(date) == day.id && day.totals.isValid
            }
            && heat.count <= 4 && Set(heat.map(\.id)).count == heat.count && heat.allSatisfy(\.isValid)
            && writers.count <= 16 && Set(writers.map(\.id)).count == writers.count
            && writers.allSatisfy { $0.sequence > 0 && UsageTotals.validDate($0.beganAt) }
            && captures.count <= 2048 && Set(captures.map(\.id)).count == captures.count
            && captures.allSatisfy { UsageTotals.validDate($0.beganAt) }
    }
    mutating func prune(at now: Date) {
        let ids = retainedDayIDs(at: now)
        days.removeAll { !ids.contains($0.id) }
        writers.removeAll { now.timeIntervalSince($0.beganAt) > 86400 }
        captures.removeAll { now.timeIntervalSince($0.beganAt) > 86400 }
    }
    mutating func add(_ totals: UsageTotals, day: String) {
        if let index = days.firstIndex(where: { $0.id == day }) { days[index].totals.add(totals) }
        else { days.append(UsageDay(id: day, totals: totals)); days.sort { $0.id < $1.id } }
    }
}

nonisolated struct UsageWriter: Codable, Equatable, Sendable {
    let id: UUID
    let beganAt: Date
    var sequence: UInt64
}
nonisolated struct UsageCaptureReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let beganAt: Date
}
nonisolated struct UsageCaptureToken: Sendable {
    let id: UUID
    let generation: UUID
    let beganAt: Date
}
nonisolated struct UsageBatch: Sendable {
    let generation: UUID
    let writer: UsageWriter
    let days: [UsageDay]
    let heat: [UsageHeat]
}

/// RAM-only lexical state. No host context, strings, or tokens are persisted.
/// Apostrophe/hyphen joins require alphanumerics on both sides.
nonisolated struct UsageWordTracker {
    // Only character classes, not characters. Cap memory even for an unbroken token.
    private var classes: [Bool] = [] // true = alphanumeric; false = internal join candidate
    private var overflow = false
    private var foreignWord = false
    var hasWord: Bool { !classes.isEmpty && !overflow && !foreignWord }
    mutating func clear() { classes.removeAll(keepingCapacity: true); overflow = false; foreignWord = false }
    mutating func ignoreOpenWord() { clear(); foreignWord = true }
    mutating func delete() { if !overflow, !classes.isEmpty { classes.removeLast() } }
    private mutating func push(_ alphanumeric: Bool) {
        if classes.count < 4096 { classes.append(alphanumeric) } else { overflow = true }
    }
    mutating func feed(_ text: String) -> UInt64 {
        var completed: UInt64 = 0
        for character in text {
            if foreignWord {
                if character.isLetter || character.isNumber || ["'", "’", "-"].contains(character) { continue }
                clear()
                continue
            }
            if character.isLetter || character.isNumber {
                push(true)
            } else if ["'", "’", "-"].contains(character), classes.last == true {
                push(false)
            } else {
                if hasWord { completed += 1 }
                clear()
            }
        }
        return completed
    }
    static func count(_ text: String) -> UInt64 {
        var tracker = Self()
        return tracker.feed(text + " ")
    }
}
