import Darwin
import Foundation

/// The typing log's files in the App Group: the keyboard appends, the app exports and deletes.
/// JSON Lines in two rolling files: `current` becomes `previous` after `segmentWords` words, so
/// the log keeps the most recent `segmentWords` to `2 × segmentWords` words.
nonisolated final class TypingLogStore: @unchecked Sendable {
    static let currentName = "typing-log-v1.jsonl"
    static let previousName = "typing-log-v1-previous.jsonl"
    private static let lockName = "typing-log.lock"

    let directory: URL
    let segmentWords: Int
    private let queue = DispatchQueue(label: "dev.rudek.typr.typing-log", qos: .utility)
    /// Lines in `current`, counted once per process on the first append; only touched on `queue`.
    private var currentLines: Int?

    init(directory: URL, segmentWords: Int = 10_000) {
        self.directory = directory
        self.segmentWords = segmentWords
    }

    /// Returns at once; encoding and writing happen on a background queue.
    func append(_ word: TypingLogWord) {
        queue.async { [self] in
            guard let line = try? TypingLogExport.encoder().encode(word) else { return }
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
                currentLines = 0
            }
        }
    }

    /// Writes the export into a new folder in `folder` and returns the file.
    func export(touchModel: PersonalTypingModel.State?, appBuild: String, into folder: URL,
                now: Date = Date()) throws -> URL {
        var touch: PersonalTypingModel.State?
        if let touchModel {
            touch = PersonalTypingModel.State()
            touch?.layouts = touchModel.layouts
        }
        let export = TypingLogExport(exportedAt: now, appBuild: appBuild, touchModel: touch, words: try words())
        let workspace = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("typr-typing-log.json")
        try TypingLogExport.encoder().encode(export).write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    private func appendLine(_ line: Data) throws {
        let current = directory.appendingPathComponent(Self.currentName)
        var lines = try currentLines ?? countLines(current)
        let exists = FileManager.default.fileExists(atPath: current.path)
        if exists && lines >= segmentWords {
            let previous = directory.appendingPathComponent(Self.previousName)
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: current, to: previous)
        }
        if !exists || lines >= segmentWords {
            try Data().write(to: current, options: .completeFileProtectionUntilFirstUserAuthentication)
            try KeyboardLearningStore.protect(current)
            lines = 0
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data([0x0A]))
        currentLines = lines + 1
    }

    private func countLines(_ file: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try Data(contentsOf: file).reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
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
