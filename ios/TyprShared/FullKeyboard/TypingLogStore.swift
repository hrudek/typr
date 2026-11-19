import Darwin
import Foundation

/// The typing log's files in the App Group: the keyboard appends, the app exports and deletes.
/// JSON Lines in two rolling files: `current` becomes `previous` after `segmentWords` words, so
/// the log keeps the most recent `segmentWords` to `2 × segmentWords` words.
nonisolated final class TypingLogStore: @unchecked Sendable {
    static let currentName = "typing-log-v1.jsonl"
    static let previousName = "typing-log-v1-previous.jsonl"
    private static let lockName = "typing-log.lock"
    static let maxLineBytes = 16 * 1024

    let directory: URL
    let segmentWords: Int
    private let queue = DispatchQueue(label: "dev.rudek.typr.typing-log", qos: .utility)
    /// `current` after this process's last append; only touched on `queue`. Other keyboard processes
    /// append and rotate too: while both files keep their identity, only later bytes need counting.
    private var currentCount: Count?

    private struct Count {
        let current: UInt64
        let previous: UInt64?
        let bytes: UInt64
        let lines: Int
    }

    init(directory: URL, segmentWords: Int = 10_000) {
        self.directory = directory
        self.segmentWords = segmentWords
    }

    /// Returns at once; encoding and writing happen on a background queue.
    func append(_ word: TypingLogWord) {
        queue.async { [self] in
            guard let line = try? TypingLogExport.encoder().encode(word), line.count <= Self.maxLineBytes else { return }
            try? withLock { try appendLine(line) }
        }
    }

    /// Waits for earlier appends of this process.
    func waitForWrites() { queue.sync {} }

    func words() throws -> [TypingLogWord] {
        try queue.sync { try withLock { try readWords() } }
    }

    func wordCount() throws -> Int {
        try queue.sync {
            try withLock {
                try [Self.previousName, Self.currentName].reduce(0) { $0 + (try countLines(directory.appendingPathComponent($1))) }
            }
        }
    }

    func delete() throws {
        try queue.sync {
            try withLock {
                for name in [Self.previousName, Self.currentName] {
                    let file = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
                currentCount = nil
            }
        }
    }

    /// Writes the export into a new folder in `folder` and returns the file.
    func export(learning: PersonalTypingModel.State?, protectedWords: [String], appBuild: String, into folder: URL,
                now: Date = Date()) throws -> URL {
        let export = TypingLogExport(exportedAt: now, appBuild: appBuild, learning: learning,
                                     protectedWords: protectedWords, words: try words())
        let workspace = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("typr-typing-log.json")
        try TypingLogExport.encoder().encode(export).write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    private func appendLine(_ line: Data) throws {
        let current = directory.appendingPathComponent(Self.currentName)
        let previous = directory.appendingPathComponent(Self.previousName)
        var lines = 0
        if let id = fileNumber(current) {
            lines = try countLines(current, id: id, previous: fileNumber(previous))
            if lines >= segmentWords {
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: current, to: previous)
            }
        }
        if fileNumber(current) == nil {
            try Data().write(to: current, options: .completeFileProtectionUntilFirstUserAuthentication)
            try KeyboardLearningStore.protect(current)
            lines = 0
        }
        let handle = try FileHandle(forUpdating: current)
        defer { try? handle.close() }
        var data = line + Data([0x0A])
        let end = try handle.seekToEnd()
        if end > 0 {
            // A line cut short by a crash must not swallow this one.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
        currentCount = fileNumber(current).map {
            Count(current: $0, previous: fileNumber(previous), bytes: end + UInt64(data.count),
                  lines: lines + data.count - line.count)
        }
    }

    private func fileNumber(_ file: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func countLines(_ file: URL, id: UInt64, previous: UInt64?) throws -> Int {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let known = currentCount, known.current == id, known.previous == previous else {
            return Self.newlines(in: try handle.readToEnd() ?? Data())
        }
        try handle.seek(toOffset: known.bytes)
        return known.lines + Self.newlines(in: try handle.readToEnd() ?? Data())
    }

    private static func newlines(in data: Data) -> Int { data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }

    private func countLines(_ file: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return Self.newlines(in: try Data(contentsOf: file))
    }

    /// Skips lines that do not decode, such as one cut short by a crash mid-append.
    private func readWords() throws -> [TypingLogWord] {
        let decoder = TypingLogExport.decoder()
        var words: [TypingLogWord] = []
        for name in [Self.previousName, Self.currentName] {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            for line in try Data(contentsOf: file).split(separator: 0x0A) {
                if let word = try? decoder.decode(TypingLogWord.self, from: line) { words.append(word) }
            }
        }
        return words
    }

    /// Serializes keyboard appends with app reads and deletes across processes.
    private func withLock<T>(_ work: () throws -> T) throws -> T {
        try KeyboardLearningStore.protect(directory, directory: true)
        let file = directory.appendingPathComponent(Self.lockName)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(fd, LOCK_UN) }
        try KeyboardLearningStore.protect(file)
        return try work()
    }
}
