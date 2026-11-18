import Foundation

/// Typr's built-in technical vocabulary: how Apple Speech mishears common (German) developer
/// terms, and what the speaker meant. It runs on the recognized text before AI cleanup, so the
/// model sees "Pull Request" instead of guessing "Puzzle-Quest" from "Pulrigquest".
///
/// How to extend it from a dictation log:
/// 1. Take the misheard form from the entry's *Recognized* text, not from the AI answer.
/// 2. If the form is not a real word in German or English ("Gitub", "Orcherator"), add it to
///    `heardAs` of the intended term: it is replaced everywhere.
/// 3. If it is a real word ("gemerkt", "Pain", "Herder"), either add it to `heardInContext` with
///    `context` words that must appear in the same dictation, or make the neighbouring word part
///    of a phrase entry ("Herder Pain" → "herdr pane", "paar Agenten" → "pi Agenten").
/// 4. Add a synthetic test to `TechGlossaryTests` and bump `revision`.
/// Forms match like Custom vocabulary terms: across case, spaces, a single hyphen and
/// possessives, longest phrase first. A user's own term or sounds-like form always wins.
nonisolated enum TechGlossary {
    /// Recorded in every dictation log entry, so log analysis can tell glossary versions apart.
    static let revision = "2026-11-18a"
    /// Glossary terms named to AI cleanup per dictation, beyond the user's own terms.
    static let maxCleanupTerms = 15

    struct Entry: Sendable {
        /// The intended spelling, written exactly like this.
        let term: String
        /// Misheard forms that are never meant literally: always replaced.
        var heardAs: [String] = []
        /// Misheard forms that are also ordinary words: replaced only when the same dictation
        /// mentions one of the `context` words or phrases.
        var heardInContext: [String] = []
        var context: [String] = []
        /// Whether the term is a hint for Apple Speech and, when it appears in a dictation,
        /// named to AI cleanup as a spelling. Phrase fixes ("Reviewer kommt") are not.
        var listed = true
    }

    struct Result: Equatable, Sendable {
        let text: String
        /// Listed terms that appear in the corrected text, in glossary order.
        let terms: [String]
    }

    private static let gitContext = [
        "PR", "PRs", "Pull Request", "Pull Requests", "Branch", "Branches", "merge", "mergen",
        "gemergt", "Merge Conflict", "Commit", "Commits", "Rebase", "GitHub", "Git", "Repository",
        "Repo", "Worktree", "pushen", "gepusht", "Review", "Reviewer",
    ]
    private static let herdrSounds = ["herdr", "Herder", "Herda", "Hurder", "Hda", "Hörder", "Härder"]
    private static let paneSounds = ["pane", "Pain", "Payne", "Pein", "Paine"]
    private static let piSounds = ["pi", "Pay", "paar", "Pei"]

    private static func phrases(_ first: [String], _ second: [String]) -> [String] {
        first.flatMap { a in second.map { b in "\(a) \(b)" } }
    }

    static let entries: [Entry] = [
        // Git and code review
        Entry(term: "Pull Request", heardAs: ["Pullrequest", "Pul Request", "Pulrequest", "Pulrigquest",
                                               "Pul Rigquest", "Pull Rigquest", "Pullrigquest"]),
        Entry(term: "Pull Requests", heardAs: ["Pullrequests", "Pul Requests", "Pulrequests", "Pulrigquests"]),
        Entry(term: "PR"),
        Entry(term: "GitHub", heardAs: ["Github", "Git Hub", "Gitub", "Githab", "Gitup"]),
        Entry(term: "Git"),
        Entry(term: "Commit", heardAs: ["Kommit", "Komitt"]),
        Entry(term: "Branch", heardAs: ["Bränch", "Brensch"], heardInContext: ["Brunch"], context: gitContext),
        Entry(term: "Rebase", heardAs: ["Ribase", "Rebeis", "Riebase"]),
        Entry(term: "mergen"),
        Entry(term: "gemergt", heardAs: ["gemerged", "gemerget", "gemerd", "gemerge", "gemörgt"],
              heardInContext: ["gemerkt"], context: gitContext),
        Entry(term: "pushen"),
        Entry(term: "Repository", heardAs: ["Repositori", "Repositorie", "Ripository"]),
        Entry(term: "Worktree", heardAs: ["Work Tree", "Worktrie"]),
        Entry(term: "Reviewer"),
        Entry(term: "Reviewer kommt", heardAs: ["Reviewercom", "Reviewer com"], listed: false),
        Entry(term: "Review Agent", heardAs: ["ReviewAgent"], listed: false),
        Entry(term: "Review Agenten", heardAs: ["ReviewAgenten"], listed: false),
        Entry(term: "Deployment", heardAs: ["Deploiment", "Deployement", "Diployment"]),
        Entry(term: "Feature Flag", heardAs: ["Featureflag", "Fietscher Flag"]),
        Entry(term: "Feature Flags", heardAs: ["Featureflags", "Fietscher Flags"]),
        // Agents and prompts
        Entry(term: "Agent"),
        Entry(term: "Orchestrator", heardAs: ["Orcherator", "Orkestrator", "Orchestrater", "Orchesterator",
                                               "Orkhestrator"]),
        Entry(term: "Prompt", heardAs: ["Promt"]),
        Entry(term: "Prompts", heardAs: ["Promts"]),
        Entry(term: "prompten", heardAs: ["promten", "prommpten"]),
        Entry(term: "promptest", heardAs: ["promtest", "prommptest"], listed: false),
        Entry(term: "gepromptet", heardAs: ["gepromtet", "geprommptet"], listed: false),
        Entry(term: "Session"),
        Entry(term: "Token"),
        Entry(term: "Tokens"),
        Entry(term: "Speech to Text", heardAs: ["Speech zu Text", "Spietsch to Text", "Speach to Text",
                                                 "Beach to Text", "As Beach to Text", "Text As Beach to Text"]),
        Entry(term: "AI Correction", heardAs: ["AIKorrection", "AI Korrection", "AIKorrektion"], listed: false),
        Entry(term: "Apple Intelligence"),
        Entry(term: "Typr", heardAs: ["Typa", "Taipa", "Teipa", "Typar", "Taiper", "Teiper", "Tiper"],
              heardInContext: ["Typer"],
              context: ["Typr", "App", "Tastatur", "Keyboard", "Diktat", "diktieren", "Dictation",
                        "TestFlight", "Speech to Text"]),
        // The owner's tools: the pi coding agent and the herdr terminal multiplexer.
        Entry(term: "pi"),
        Entry(term: "pi Agent", heardAs: phrases(piSounds, ["Agent"]), listed: false),
        Entry(term: "pi Agenten", heardAs: phrases(piSounds, ["Agenten"]), listed: false),
        Entry(term: "pi Agents", heardAs: phrases(piSounds, ["Agents"]), listed: false),
        Entry(term: "herdr", heardAs: ["Herdr"], heardInContext: Array(herdrSounds.dropFirst()),
              context: ["pane", "panes", "Pain", "Payne", "Tab", "Tabs", "Terminal", "tmux", "pi", "Agent",
                        "Agenten"]),
        Entry(term: "pane", heardInContext: Array(paneSounds.dropFirst()),
              context: ["herdr", "tmux", "Terminal", "Tab", "Tabs", "Split"]),
        Entry(term: "herdr pane", heardAs: phrases(herdrSounds, paneSounds), listed: false),
    ]

    /// Listed terms, in glossary order: Apple Speech hints after the user's own terms.
    static var listedTerms: [String] {
        entries.filter(\.listed).map(\.term)
    }

    /// Replaces misheard forms in one pass for unambiguous forms, then one pass for the
    /// context-dependent forms whose context the (already corrected) dictation mentions.
    /// Forms whose spelling key is in `protectedKeys` (the user's own terms and forms) are
    /// skipped, so user vocabulary always wins.
    static func apply(to text: String, entries: [Entry] = TechGlossary.entries, protectedKeys: Set<String> = [],
                      onReplacement: ((_ before: String, _ after: String, _ term: String) -> Void)? = nil) -> Result {
        func rules(_ forms: (Entry) -> [String], of selected: [Entry]) -> [VocabularySpelling.Rule] {
            selected.flatMap { entry in
                forms(entry).map { VocabularySpelling.Rule(match: $0, spelling: entry.term) }
            }.filter { !protectedKeys.contains(VocabularySpelling.normalizedKey($0.match)) }
        }

        var output = VocabularySpelling.apply(rules: rules(\.heardAs, of: entries), to: text,
                                              onReplacement: onReplacement)
        let words = wordKeys(output)
        let inContext = entries.filter { entry in
            !entry.heardInContext.isEmpty && entry.context.contains { mentions(words, $0) }
        }
        let contextual = rules(\.heardInContext, of: inContext)
        if !contextual.isEmpty {
            output = VocabularySpelling.apply(rules: contextual, to: output, onReplacement: onReplacement)
        }

        let finalWords = wordKeys(output)
        var seen = Set<String>()
        let terms = entries.filter(\.listed).map(\.term).filter { term in
            seen.insert(VocabularySpelling.normalizedKey(term)).inserted && mentions(finalWords, term)
        }
        return Result(text: output, terms: Array(terms.prefix(maxCleanupTerms)))
    }

    /// Lowercased letter/digit runs of the text, the same units that spelling keys are built from.
    private static func wordKeys(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Whether the words contain the phrase as consecutive words, or glued into one word.
    private static func mentions(_ words: [String], _ phrase: String) -> Bool {
        let keys = wordKeys(phrase)
        guard !keys.isEmpty, words.count >= 1 else { return false }
        if keys.count > 1, words.contains(keys.joined()) { return true }
        guard words.count >= keys.count else { return false }
        for start in 0...(words.count - keys.count) where Array(words[start..<(start + keys.count)]) == keys {
            return true
        }
        return false
    }
}
