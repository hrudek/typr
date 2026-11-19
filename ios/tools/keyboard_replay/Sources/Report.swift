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
    /// Committed by a strip pick; replayed with the same pick.
    var picked = 0
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

    /// `results[i]`: the variants' replays of the word, in `KeyboardHitAreas.allCases` order.
    /// `results[i]`: the word's preparation and its replays in `KeyboardHitAreas.allCases` order.
    static func build(words logged: [TypingLogWord], results: [Result<(PreparedWord, [ReplayedWord]), SkipReason>],
                      showWords: Bool) -> Report {
        var report = Report(exported: logged.count)
        let variants = KeyboardHitAreas.allCases
        let baseline = variants[0]
        for variant in variants.dropFirst() { report.changes["\(baseline.rawValue)->\(variant.rawValue)"] = Change() }
        var lines: [WordLine] = []
        for (word, result) in zip(logged, results) {
            let prepared: PreparedWord, replays: [ReplayedWord]
            switch result {
            case .success(let replayed): (prepared, replays) = replayed
            case .failure(let reason): report.skipped[reason.rawValue, default: 0] += 1; continue
            }
            report.replayed += 1
            let known = prepared.known
            var reproduced = true
            if let index = variants.firstIndex(where: { $0.rawValue == word.hitAreas }) {
                let replay = replays[index]
                var reproduction = report.reproduction[word.hitAreas, default: Reproduction()]
                reproduction.literals += 1
                if replay.literal == prepared.plan.literal { reproduction.literalMatches += 1 } else { reproduced = false }
                if let commit = word.commit {
                    if commit.correction == .spelling {
                        reproduction.systemSpelling += 1
                    } else if commit.kind == .pick {
                        reproduction.picked += 1
                    } else {
                        reproduction.commits += 1
                        if replay.committed == commit.text { reproduction.commitMatches += 1 } else { reproduced = false }
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

    func text() -> String {
        var out = "Typing log replay: \(exported) words exported, \(replayed) replayed\n"
        for setting in KeyboardHitAreas.allCases {
            guard let r = reproduction[setting.rawValue] ?? (setting == .standard ? Reproduction() : nil) else { continue }
            out += "Reproduction (\(setting.rawValue.capitalized)): committed word matches the iPhone for"
            out += " \(r.commitMatches)/\(r.commits) words, \(Self.percent(r.commitMatches, r.commits))\n"
            out += "  not compared: \(r.systemSpelling) fixed by system spelling, \(r.picked) picked from the strip\n"
            out += "  letters at the first boundary match for \(r.literalMatches)/\(r.literals) words\n"
        }
        if !skipped.isEmpty {
            out += "Skipped: " + skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ") + "\n"
        }
        for variant in KeyboardHitAreas.allCases {
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
                let replays = KeyboardHitAreas.allCases.compactMap { v in line.replayed[v.rawValue].map { "\(v.rawValue) \($0)" } }
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
