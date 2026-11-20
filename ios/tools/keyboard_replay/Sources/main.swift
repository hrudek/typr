import Foundation

let usage = """
Usage: keyboard-replay EXPORT.json [--show-words] [--json]
Replays a Typr typing log export through the keyboard's own engine.
  --show-words  list the words that did not reproduce or differ from the meant word (private text)
  --json        print the report as JSON
       keyboard-replay --make-fixture FILE
Types the invented test text through the engine and writes it as an export to FILE.
       keyboard-replay --touch-posterior
Prints the learned touch densities after fixed labels as JSON, for the touch-model tests.
"""

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
    var fixture: URL?
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        switch argument {
        case "--show-words": showWords = true
        case "--json": json = true
        case "--make-fixture":
            guard let path = rest.popFirst() else { throw ReplayError(usage) }
            fixture = URL(fileURLWithPath: path)
        case "-h", "--help": print(usage); return
        case "--touch-posterior": print(try touchPosteriorReport(), terminator: ""); return
        default:
            guard input == nil, !argument.hasPrefix("-") else { throw ReplayError(usage) }
            input = argument
        }
    }
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        throw ReplayError("Cannot locate the WordData folder next to keyboard-replay")
    }
    let words = try WordData(directory: executable.deletingLastPathComponent().appendingPathComponent("WordData"))
    if let fixture {
        return try await makeFixture(words: words, to: fixture)
    }
    guard let input else { throw ReplayError(usage) }
    let export = try readExport(input)

    let replayer = try Replayer(words: words, export: export)

    var results: [Result<(PreparedWord, ReplayedWord), SkipReason>] = []
    var previous: [String] = []
    for word in export.words {
        let context = previous.joined()
        switch replayer.prepare(word) {
        case .success(let prepared):
            results.append(try await replayer.replay(word, prepared, context: context).map { (prepared, $0) })
        case .failure(let reason):
            results.append(.failure(reason))
        }
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
    print(text, terminator: "")
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("keyboard-replay: \(error)\n".utf8))
    exit(1)
}
