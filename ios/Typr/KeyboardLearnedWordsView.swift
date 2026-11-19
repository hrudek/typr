import SwiftUI

/// Sensitive saved words are loaded only on this explicitly opened page.
@MainActor
struct KeyboardLearnedWordsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: PersonalTypingModel.State?
    @State private var error: String?
    @State private var searchText = ""
    @State private var observer: KeyboardLearningObserver?
    @State private var editMode: EditMode = .inactive
    private let fixture: Bool

    init(fixture: Bool = KeyboardLearnedWordsView.isFixtureRequested) {
        self.fixture = fixture
    }

    static var isFixtureRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--snap-state"), index + 1 < args.count else { return false }
        return args[index + 1] == "settings-keyboard-learned-words"
    }

    static let summary = "Saved words and corrections stay on this iPhone. Swipe to delete."
    static let about = "Typr stores kept words, word counts, rejected corrections with up to two preceding words and which word followed one or two words, including words chosen from suggestions. Undo blocks that correction everywhere for 64 learned word events, then only in its saved context until event 256. Typing the original spelling independently again keeps it. Older saved rejections stay until deleted. Saved word counts and update dates also provide a weak recent German/English usage prior for suggestions. Deleting a word count removes its contribution; Reset learning clears the prior. These associations can reveal short phrases. No sentence archive, apps, websites or typed-text history is stored. Deleting a word removes every context containing it; Reset learning clears all contexts. Without Full Access, learning stays in the keyboard session and cannot be shown here. Imported contacts and dictation words are separate: use Personal names and terms in Words and privacy to delete that list or turn off a source."

    nonisolated static let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func fixtureState() -> PersonalTypingModel.State {
        var state = PersonalTypingModel.State()
        state.kept = ["typr": fixtureDate, "swift": fixtureDate]
        state.rejected = [.init(typed: "teh", replacement: "the")]
        state.counts = ["hello": .init(count: 12, lastUpdated: fixtureDate)]
        for _ in 0..<3 { state.bigrams?.record("world", after: "hello") }
        return state
    }

    var body: some View {
        List {
            Section {
                Text(Self.summary).font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("About saved learning") {
                    Text(Self.about).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            if let state {
                let results = SearchResults(state: state, query: searchText)
                let kept = results.kept
                let pairs = results.pairs
                let counts = results.counts
                Section("Kept words") {
                    ForEach(kept, id: \.self) { Text($0) }
                        .onDelete { offsets in delete(offsets.map { .kept(kept[$0]) }) }
                }
                Section("Rejected corrections") {
                    ForEach(pairs, id: \.self) { pair in
                        VStack(alignment: .leading) {
                            Text("\(pair.typed) → \(pair.replacement)")
                            if let context = pair.context {
                                Text("After: \(context)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                        .onDelete { offsets in delete(offsets.map { .rejected(pairs[$0]) }) }
                }
                Section("Frequent words") {
                    ForEach(counts, id: \.self) { word in
                        HStack { Text(word); Spacer(); Text("\(state.counts[word]?.count ?? 0)").foregroundStyle(.secondary) }
                    }
                    .onDelete { offsets in delete(offsets.map { .count(counts[$0]) }) }
                }
                Section("Words in next-word contexts") {
                    ForEach(results.pairWords, id: \.self) { Text($0) }
                        .onDelete { offsets in delete(offsets.map { .pairWord(results.pairWords[$0]) }) }
                }
                if kept.isEmpty && pairs.isEmpty && counts.isEmpty && results.pairWords.isEmpty {
                    Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No saved words or corrections."
                         : "No matching words or corrections.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No saved learning available. Full Access may be off, or nothing has been saved yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Manage learned words")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search words and corrections")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            Button(editMode.isEditing ? "Done" : "Edit",
                   systemImage: editMode.isEditing ? "checkmark" : "pencil") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
        }
        .environment(\.editMode, $editMode)
        .refreshable { reload() }
        .onAppear {
            reload()
            if !fixture { observer = KeyboardLearningObserver { reload() } }
        }
        .onDisappear { observer?.invalidate(); observer = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    /// Filtering never changes saved learning; deletion uses these same visible arrays.
    struct SearchResults {
        let kept: [String]
        let pairs: [RejectedCorrection]
        let counts: [String]
        let pairWords: [String]

        init(state: PersonalTypingModel.State, query: String) {
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            func matches(_ word: String) -> Bool {
                query.isEmpty || word.localizedStandardContains(query)
            }
            kept = state.kept.keys.filter { matches($0) }.sorted()
            pairs = state.rejected.filter { matches($0.typed) || matches($0.replacement) || matches($0.context ?? "") }
                .sorted { ($0.typed, $0.replacement) < ($1.typed, $1.replacement) }
            counts = state.counts.keys.filter { matches($0) }.sorted()
            pairWords = (state.bigrams?.words ?? []).filter { matches($0) }.sorted()
        }
    }

    private func reload() {
        state = fixture ? (state ?? Self.fixtureState()) : KeyboardLearningStore().learnedWords()
    }

    private func delete(_ entries: [KeyboardLearningStore.LearnedEntry]) {
        error = nil
        for entry in entries {
            if fixture {
                switch entry {
                case .kept(let word):
                    state?.kept.removeValue(forKey: word)
                    state?.bigrams?.purge(word)
                case .count(let word):
                    state?.counts.removeValue(forKey: word)
                    state?.bigrams?.purge(word)
                case .pairWord(let word): state?.bigrams?.purge(word)
                case .rejected(let pair): state?.rejected.removeAll { $0 == pair }
                }
            } else if !KeyboardLearningStore().deleteLearnedEntry(entry) {
                error = "Could not delete the saved entry. Try again."
                break
            }
        }
        reload()
    }
}
