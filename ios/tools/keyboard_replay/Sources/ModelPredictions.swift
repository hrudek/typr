import Foundation
import UIKit

/// A text field whose traits a scenario sets.
@MainActor
final class TraitTarget: KeyboardTextTarget {
    var text = ""
    var autocorrectionType: UITextAutocorrectionType? = .default
    var isSecureTextEntry: Bool? = false
    var keyboardType: UIKeyboardType? = .default
    var inlinePredictionType: UITextInlinePredictionType? = .default
    var documentContextBeforeInput: String? { text }
    var hasText: Bool { !text.isEmpty }
    var autocapitalizationType: UITextAutocapitalizationType? { .sentences }
    var returnKeyType: UIReturnKeyType? { .default }
    var keyboardAppearance: UIKeyboardAppearance? { .default }
    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

/// Answers for each context, fails, or waits until released, ignoring cancellation like a slow model.
actor FakeModel: ModelPredictionProvider {
    enum Mode { case answer, fail, hold }
    private let answer: @Sendable (String) -> [String]
    private let mode: Mode
    private(set) var contexts: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ words: [String], mode: Mode = .answer) {
        self.init(mode: mode) { _ in words }
    }

    init(mode: Mode = .answer, answer: @escaping @Sendable (String) -> [String]) {
        self.answer = answer
        self.mode = mode
    }

    func predictions(for request: ModelPredictionRequest) async throws -> [String] {
        contexts.append(request.context)
        switch mode {
        case .answer: break
        case .fail: throw CancellationError()
        case .hold: await withCheckedContinuation { held.append($0) }
        }
        return answer(request.context)
    }

    func waitForRequests(_ count: Int) async {
        while contexts.count < count || held.count < count { await Task.yield() }
    }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }
}

@MainActor
func modelPredictionReport(words: WordData) async throws -> String {
    func engine(_ target: TraitTarget, provider: FakeModel?, timeout: Duration = .seconds(5)) -> FullKeyboardEngine {
        let autocorrect = AutocorrectEngine(checker: LexiconChecker(words.lexicons[.english]),
                                            spatialDecoder: SpatialWordDecoder(lexicons: words.lexicons),
                                            contextResources: KeyboardContextResources(model: words.context))
        let engine = FullKeyboardEngine(target: target, autocorrect: autocorrect)
        engine.width = 393
        engine.modelPredictions = provider.map { ModelPredictionSession(provider: $0, timeout: timeout) }
        engine.configureForField()
        return engine
    }
    func bar(_ engine: FullKeyboardEngine) -> [String] { engine.suggestions.map(\.replacement) }
    func settle(_ engine: FullKeyboardEngine) async {
        await engine.waitForSuggestions()
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        while engine.modelPredictions?.isActive == true, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func typed(_ text: String, _ target: TraitTarget, _ engine: FullKeyboardEngine) async {
        target.text = text
        engine.textDidChange()
        await engine.waitForSuggestions()
    }

    var report: [String: Any] = [:]
    let sentence = "I would like to "

    let plainTarget = TraitTarget()
    let plain = engine(plainTarget, provider: nil)
    await typed(sentence, plainTarget, plain)
    report["noProvider"] = bar(plain)

    let answerTarget = TraitTarget()
    let model = FakeModel(["go", "Visit", "see"], mode: .hold)
    let answered = engine(answerTarget, provider: model)
    await typed(sentence, answerTarget, answered)
    let immediate = bar(answered)
    await model.waitForRequests(1)
    await model.release()
    await settle(answered)
    let merged = bar(answered)
    answered.textDidChange()
    await settle(answered)
    report["answer"] = ["immediate": immediate, "merged": merged, "republished": bar(answered),
                        "contexts": await model.contexts]

    let staleTarget = TraitTarget()
    let held = FakeModel(mode: .hold) { $0.hasSuffix("go ") ? ["fresh"] : ["stale"] }
    let stale = engine(staleTarget, provider: held)
    await typed(sentence, staleTarget, stale)
    await typed(sentence + "go ", staleTarget, stale)
    await held.waitForRequests(2)
    await held.release()
    await settle(stale)
    report["stale"] = ["bar": bar(stale), "contexts": await held.contexts]

    let timeoutTarget = TraitTarget()
    let slow = FakeModel(["late"], mode: .hold)
    let timedOut = engine(timeoutTarget, provider: slow, timeout: .milliseconds(50))
    await typed(sentence, timeoutTarget, timedOut)
    let beforeTimeout = bar(timedOut)
    await settle(timedOut)
    await slow.waitForRequests(1)
    await slow.release()
    try await Task.sleep(for: .milliseconds(20))
    report["timeout"] = ["before": beforeTimeout, "after": bar(timedOut)]

    let failTarget = TraitTarget()
    let failing = engine(failTarget, provider: FakeModel([], mode: .fail))
    await typed(sentence, failTarget, failing)
    await settle(failing)
    report["failure"] = bar(failing)

    var restricted: [String: Int] = [:]
    let fields: [(String, (TraitTarget) -> Void)] = [
        ("secure", { $0.isSecureTextEntry = true }), ("url", { $0.keyboardType = .URL }),
        ("email", { $0.keyboardType = .emailAddress }), ("numberPad", { $0.keyboardType = .numberPad }),
        ("numbersAndPunctuation", { $0.keyboardType = .numbersAndPunctuation }),
        ("noAutocorrect", { $0.autocorrectionType = .no }), ("noPredictive", { $0.inlinePredictionType = .no }),
    ]
    for (name, configure) in fields {
        let target = TraitTarget()
        configure(target)
        let spy = FakeModel(["go"])
        let restrictedEngine = engine(target, provider: spy)
        await typed(sentence, target, restrictedEngine)
        await settle(restrictedEngine)
        restricted[name] = await spy.contexts.count
    }
    report["restrictedRequests"] = restricted

    let boundedTarget = TraitTarget()
    let bounded = FakeModel(["go"])
    let boundedEngine = engine(boundedTarget, provider: bounded)
    let paragraph = String(repeating: "We walked along the river ", count: 12)
    await typed("Secret first paragraph.\n" + paragraph, boundedTarget, boundedEngine)
    await settle(boundedEngine)
    report["boundedContexts"] = await bounded.contexts

    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}
