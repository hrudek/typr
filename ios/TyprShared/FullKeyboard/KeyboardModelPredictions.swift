import Foundation

/// What a prediction model may see: the current paragraph before the caret, at most
/// `characterLimit` characters starting at a word, never text after the caret. RAM-only.
nonisolated struct ModelPredictionRequest: Equatable, Sendable {
    static let characterLimit = 200
    let context: String

    /// Nil unless the caret follows whitespace after some text in the current paragraph.
    init?(before: String?) {
        guard let before, before.last?.isWhitespace == true else { return nil }
        var paragraph = before.lastIndex(where: \.isNewline).map { before[before.index(after: $0)...] } ?? before[...]
        if paragraph.count > Self.characterLimit {
            paragraph = paragraph.suffix(Self.characterLimit)
            if let space = paragraph.firstIndex(where: \.isWhitespace) { paragraph = paragraph[space...] }
        }
        let context = paragraph.drop(while: \.isWhitespace)
        guard !context.isEmpty else { return nil }
        self.context = String(context)
    }
}

/// A next-word source that may take a while (an on-device or cloud model).
protocol ModelPredictionProvider: Sendable {
    /// Likeliest next words first. Throwing or returning nothing keeps the count-based predictions.
    func predictions(for request: ModelPredictionRequest) async throws -> [String]
}

/// Runs at most one model request: a newer context replaces the active one, and a result
/// arrives only if no newer request, cancellation or timeout happened meanwhile.
@MainActor
final class ModelPredictionSession {
    nonisolated static let wordLimit = 3
    private nonisolated static let wordLength = 32

    let provider: any ModelPredictionProvider
    private let timeout: Duration
    private var epoch: UInt64 = 0
    private var active: (request: ModelPredictionRequest, finish: @MainActor ([String]) -> Void)?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastAnswer: (request: ModelPredictionRequest, words: [String])?

    init(provider: any ModelPredictionProvider, timeout: Duration = .milliseconds(1_500)) {
        self.provider = provider
        self.timeout = timeout
    }

    var isActive: Bool { active != nil }

    func words(for request: ModelPredictionRequest) -> [String]? {
        lastAnswer?.request == request ? lastAnswer?.words : nil
    }

    /// `finish` gets the cleaned words on the main actor; failures and timeouts call nothing.
    /// The same request while it is active keeps running and takes the newer `finish`.
    func request(_ request: ModelPredictionRequest, finish: @escaping @MainActor ([String]) -> Void) {
        if active?.request == request {
            active?.finish = finish
            return
        }
        cancel()
        let epoch = self.epoch
        active = (request, finish)
        let provider = self.provider, timeout = self.timeout
        work = Task { [weak self] in
            let words = try? await provider.predictions(for: request)
            self?.deliver(words, epoch: epoch)
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, epoch == self.epoch else { return }
            self.cancel()
        }
    }

    /// Cancels the active request unless it is for `request`.
    func keep(only request: ModelPredictionRequest?) {
        if active != nil, active?.request != request { cancel() }
    }

    func cancel() {
        epoch &+= 1
        active = nil
        work?.cancel()
        timer?.cancel()
        work = nil
        timer = nil
    }

    private func deliver(_ words: [String]?, epoch: UInt64) {
        guard epoch == self.epoch, let active else { return }
        let finish = active.finish
        cancel()
        let cleaned = Self.clean(words ?? [])
        guard !cleaned.isEmpty else { return }
        lastAnswer = (active.request, cleaned)
        finish(cleaned)
    }

    /// Single words only (letters, apostrophes, inner hyphens), case-insensitively unique.
    nonisolated static func clean(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in words where result.count < wordLimit {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard (1...wordLength).contains(word.count),
                  word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }),
                  word.contains(where: \.isLetter),
                  seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
        }
        return result
    }

    /// Model and count-based words alternate, model first, without repeats, in strip order
    /// (likeliest in the centre). `counted` is in strip order already.
    nonisolated static func merge(_ words: [String], into counted: [KeyboardSuggestion]) -> [KeyboardSuggestion] {
        let model = words.map { KeyboardSuggestion(displayText: $0, replacement: $0, kind: .secondary, isCompletion: true) }
        let ranked = counted.filter { $0.kind != .secondary } + counted.filter { $0.kind == .secondary }
        var alternating: [KeyboardSuggestion] = []
        for index in 0..<max(model.count, ranked.count) {
            alternating += [model, ranked].compactMap { $0.indices.contains(index) ? $0[index] : nil }
        }
        var seen: Set<String> = []
        let merged = alternating.filter { seen.insert($0.replacement.lowercased()).inserted }
        return KeyboardContextModel.stripOrder(Array(merged.prefix(wordLimit)).enumerated().map { index, suggestion in
            var placed = KeyboardSuggestion(displayText: suggestion.displayText, replacement: suggestion.replacement,
                                            kind: index == 0 ? .primary(autoReplace: false) : .secondary,
                                            isCompletion: true)
            placed.isPersonal = suggestion.isPersonal
            placed.ownership = suggestion.ownership
            return placed
        })
    }
}
