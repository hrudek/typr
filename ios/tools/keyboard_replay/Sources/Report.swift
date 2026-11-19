import Foundation

struct Score: Codable {
    var words = 0
    var wordErrors = 0
    var letters = 0
    var letterErrors = 0

    mutating func add(committed: String, meant: String) {
        words += 1
        letters += meant.count
        let distance = editDistance(Array(committed), Array(meant))
        letterErrors += distance
        if distance > 0 { wordErrors += 1 }
    }
}

struct Split: Codable {
    var known = Score()
    var unknown = Score()

    subscript(known isKnown: Bool) -> Score {
        get { isKnown ? known : unknown }
        set { if isKnown { known = newValue } else { unknown = newValue } }
    }
}

struct Counts: Codable {
    var known = 0
    var unknown = 0

    subscript(known isKnown: Bool) -> Int {
        get { isKnown ? known : unknown }
        set { if isKnown { known = newValue } else { unknown = newValue } }
    }
}

/// Words the variant gets right where the baseline does not (`fixed`), and the reverse.
struct Change: Codable {
    var fixed = Counts()
    var broken = Counts()
}

struct Reproduction: Codable {
    var literals = 0
    var literalMatches = 0
    var commits = 0
    var commitMatches = 0
    /// Committed by a strip pick, or edited again after the separator before the user moved on.
    var commitsNotComparable = 0
    /// Corrected by system spelling, which the replay does not have.
    var systemSpelling = 0
}

struct WordLine: Codable {
    var meant: String
    var known: Bool
    var logged: String
    var replayed: [String: String]
}

struct Report: Codable {
    var exported = 0
    var replayed = 0
    var skipped: [String: Int] = [:]
    var reproduction: [String: Reproduction] = [:]
    var variants: [String: Split] = [:]
    var changes: [String: Change] = [:]
    var words: [WordLine]?

    /// `results[i]`: the variants' replays of the word, in `HitAreas.allCases` order.
    static func build(words logged: [TypingLogWord], results: [Result<[ReplayedWord], SkipReason>],
                      isKnown: (Int, TypingLogWord) -> Bool, showWords: Bool) -> Report {
        var report = Report(exported: logged.count)
        let variants = HitAreas.allCases
        let baseline = variants[0]
        var lines: [WordLine] = []
        for (index, (word, result)) in zip(logged, results).enumerated() {
            let replays: [ReplayedWord]
            switch result {
            case .success(let replayed): replays = replayed
            case .failure(let reason): report.skipped[reason.rawValue, default: 0] += 1; continue
            }
            report.replayed += 1
            let known = isKnown(index, word)
            var reproduced = true
            if let index = variants.firstIndex(where: { $0.rawValue == word.hitAreas }) {
                let replay = replays[index]
                var reproduction = report.reproduction[word.hitAreas, default: Reproduction()]
                reproduction.literals += 1
                if replay.literal == word.literal { reproduction.literalMatches += 1 } else { reproduced = false }
                if let commit = word.commit {
                    if commit.correction == .spelling {
                        reproduction.systemSpelling += 1
                    } else if commitIsComparable(word, commit) {
                        reproduction.commits += 1
                        if replay.committed == commit.text { reproduction.commitMatches += 1 } else { reproduced = false }
                    } else {
                        reproduction.commitsNotComparable += 1
                    }
                }
                report.reproduction[word.hitAreas] = reproduction
            }
            for (variant, replay) in zip(variants, replays) {
                report.variants[variant.rawValue, default: Split()][known: known]
                    .add(committed: replay.committed, meant: word.meant)
            }
            let baseRight = replays[0].committed == word.meant
            for (variant, replay) in zip(variants, replays).dropFirst() {
                let right = replay.committed == word.meant
                let key = "\(baseline.rawValue)->\(variant.rawValue)"
                if right != baseRight {
                    var change = report.changes[key, default: Change()]
                    if right { change.fixed[known: known] += 1 } else { change.broken[known: known] += 1 }
                    report.changes[key] = change
                }
            }
            let changed = Set(replays.map(\.committed)).count > 1
            if showWords, changed || !reproduced {
                lines.append(WordLine(meant: word.meant, known: known, logged: word.commit?.text ?? word.literal,
                                      replayed: Dictionary(uniqueKeysWithValues: zip(variants.map(\.rawValue),
                                                                                    replays.map(\.committed)))))
            }
        }
        if showWords { report.words = lines }
        return report
    }

    /// The logged taps stood at the separator unless the word was picked, reopened or typed on after an undo.
    static func commitIsComparable(_ word: TypingLogWord, _ commit: TypingLogWord.Commit) -> Bool {
        guard commit.kind == .literal || commit.kind == .autocorrect,
              !word.corrections.contains(where: { $0.kind == .reopen }) else { return false }
        guard let undo = word.corrections.firstIndex(where: { $0.kind == .undo }) else { return true }
        return undo == word.corrections.count - 1 && word.corrections[undo].to == word.literal
    }

    func text() -> String {
        var out = "Typing log replay: \(exported) words exported, \(replayed) replayed\n"
        if reproduction.isEmpty { out += "Reproduction: no replayed word was logged with a setting this tool knows\n" }
        for (setting, r) in reproduction.sorted(by: { $0.key < $1.key }) {
            out += "Reproduction (\(setting.capitalized)): committed word matches the iPhone for"
            out += " \(r.commitMatches)/\(r.commits) words, \(Self.percent(r.commitMatches, r.commits))\n"
            out += "  not compared: \(r.systemSpelling) fixed by system spelling,"
            out += " \(r.commitsNotComparable) picked or edited after the separator\n"
            out += "  typed letters match for \(r.literalMatches)/\(r.literals) words\n"
        }
        if !skipped.isEmpty {
            out += "Skipped: " + skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ") + "\n"
        }
        for variant in HitAreas.allCases {
            guard let split = variants[variant.rawValue] else { continue }
            out += "\n\(variant.rawValue.capitalized) vs meant word:\n"
            out += Self.line("known", split.known) + Self.line("unknown", split.unknown)
        }
        for (key, change) in changes.sorted(by: { $0.key < $1.key }) {
            out += "\n\(key): fixed \(change.fixed.known) known, \(change.fixed.unknown) unknown;"
            out += " broken \(change.broken.known) known, \(change.broken.unknown) unknown\n"
        }
        if let words {
            out += "\nChanged or not reproduced (\(words.count)):\n"
            for line in words {
                let replays = HitAreas.allCases.compactMap { v in line.replayed[v.rawValue].map { "\(v.rawValue) \($0)" } }
                out += "  meant \(line.meant) | logged \(line.logged) | " + replays.joined(separator: " | ")
                out += line.known ? "\n" : " (unknown)\n"
            }
        }
        return out
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "-" : String(format: "%.1f%%", Double(part) * 100 / Double(whole))
    }

    private static func line(_ name: String, _ score: Score) -> String {
        return "  \(name) \(score.words) words: word errors \(percent(score.wordErrors, score.words))"
            + " (\(score.wordErrors)), letter errors \(percent(score.letterErrors, score.letters))"
            + " (\(score.letterErrors)/\(score.letters))\n"
    }
}

func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    var previous = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: b.count)
        for (j, y) in b.enumerated() {
            current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
        }
        previous = current
    }
    return previous[b.count]
}
