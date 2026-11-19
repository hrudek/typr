import Foundation

let usage = """
Usage: keyboard-replay EXPORT.json [--show-words] [--json] [--out FILE]
Replays a Typr typing log export through the keyboard's own engine and compares hit-area settings.
  --show-words  list the words that changed between settings or did not reproduce (private text)
  --json        print the report as JSON
  --out FILE    write the report to FILE (outside every Git checkout) instead of stdout
       keyboard-replay --make-fixture FILE
Types the invented test text through the engine and writes it as an export to FILE.
"""

/// Private text must not land where `git add` could pick it up, including through a symlink.
func requireOutsideCheckout(_ url: URL) throws {
    var resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    while true {
        if FileManager.default.fileExists(atPath: resolved.appendingPathComponent(".git").path) {
            throw ReplayError("\(url.path) is inside a Git checkout; use a private directory outside it")
        }
        let parent = resolved.deletingLastPathComponent().resolvingSymlinksInPath()
        if parent.path == resolved.path { return }
        resolved = parent
    }
}

func readExport(_ path: String) throws -> TypingLogExport {
    let url = URL(fileURLWithPath: path)
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size <= 256 * 1024 * 1024 else { throw ReplayError("\(path) is larger than 256 MB") }
    struct Header: Decodable { let format: String?; let version: Int? }
    let data = try Data(contentsOf: url)
    let header: Header
    do { header = try JSONDecoder().decode(Header.self, from: data) } catch {
        throw ReplayError("\(path) is not valid JSON")
    }
    guard header.format == TypingLogExport.format else { throw ReplayError("\(path) is not a Typr typing log export") }
    guard header.version == TypingLogExport.version else {
        throw ReplayError("Export version \(header.version.map(String.init) ?? "?") is not supported"
                          + " (expected \(TypingLogExport.version)); export again from the matching Typr build")
    }
    do { return try TypingLogExport.decoder().decode(TypingLogExport.self, from: data) } catch {
        throw ReplayError("\(path) does not match the typing log format: \(error)")
    }
}

@MainActor
func run(_ arguments: [String]) async throws {
    var input: String?
    var showWords = false, json = false
    var out: URL?
    var fixture: URL?
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        switch argument {
        case "--show-words": showWords = true
        case "--json": json = true
        case "--out":
            guard let path = rest.popFirst() else { throw ReplayError(usage) }
            out = URL(fileURLWithPath: path)
        case "--make-fixture":
            guard let path = rest.popFirst() else { throw ReplayError(usage) }
            fixture = URL(fileURLWithPath: path)
        case "-h", "--help": print(usage); return
        default:
            guard input == nil, !argument.hasPrefix("-") else { throw ReplayError(usage) }
            input = argument
        }
    }
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        throw ReplayError("Cannot locate the WordData folder next to keyboard-replay")
    }
    let words = try WordData(directory: executable.deletingLastPathComponent().appendingPathComponent("WordData"))
    if let fixture { return try await makeFixture(words: words, to: fixture) }
    guard let input else { throw ReplayError(usage) }
    if let out { try requireOutsideCheckout(out) }
    let export = try readExport(input)

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("typr-replay-\(UUID().uuidString)")
    try requireOutsideCheckout(scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let replayer = try Replayer(words: words, export: export, learningStore: scratch)

    var results: [Result<(PreparedWord, [ReplayedWord]), SkipReason>] = []
    var previous: [String] = []
    for word in export.words {
        let context = previous.joined()
        var result = replayer.prepare(word).map { ($0, [ReplayedWord]()) }
        for hitAreas in KeyboardHitAreas.allCases {
            guard case .success((let prepared, let replays)) = result else { break }
            result = try await replayer.replay(word, prepared, context: context, hitAreas: hitAreas)
                .map { (prepared, replays + [$0]) }
        }
        results.append(result)
        if Replayer.separators.contains(word.end), !word.meant.isEmpty {
            previous = Array((previous + [word.meant + word.end]).suffix(3))
        } else {
            previous = []
        }
    }
    let report = Report.build(words: export.words, results: results, showWords: showWords)
    let text: String
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        text = String(decoding: try encoder.encode(report), as: UTF8.self) + "\n"
    } else {
        text = report.text()
    }
    if let out {
        try Data(text.utf8).write(to: out, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
    } else {
        print(text, terminator: "")
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("keyboard-replay: \(error)\n".utf8))
    exit(1)
}
