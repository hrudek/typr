import Foundation
import UIKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// An on-device model that is available or not, supports some languages, answers or refuses.
@MainActor
final class FakeOnDeviceModel: OnDeviceNextWordModel {
    struct Refusal: Error {}
    let isAvailable: Bool
    let languages: Set<SpatialWordDecoder.Language>
    let words: [String]?
    private(set) var contexts: [String] = []

    init(available: Bool = true, languages: Set<SpatialWordDecoder.Language> = [.german, .english], words: [String]?) {
        isAvailable = available
        self.languages = languages
        self.words = words
    }

    func supports(_ language: SpatialWordDecoder.Language) -> Bool { languages.contains(language) }
    func prewarm() {}

    func nextWords(after context: String) async throws -> [String] {
        contexts.append(context)
        guard let words else { throw Refusal() }
        return words
    }
}

@MainActor
func modelPredictionReport(words: WordData) async throws -> String {
    func engine(_ target: TraitTarget, provider: (any ModelPredictionProvider)?,
                timeout: Duration = .seconds(5)) -> FullKeyboardEngine {
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
    let model = FakeModel(["go", "visit", "see"], mode: .hold)
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

    report["cloud"] = await cloudReport(engine: engine, sentence: sentence)

    var onDevice: [String: Any] = [:]
    let both: Set<SpatialWordDecoder.Language> = [.german, .english]
    let sources: [(String, Bool, FakeOnDeviceModel?, Set<SpatialWordDecoder.Language>)] = [
        ("none", false, nil, both),
        ("unavailable", false, FakeOnDeviceModel(available: false, words: ["go"]), both),
        ("englishOnlyModel", false, FakeOnDeviceModel(languages: [.english], words: ["go"]), both),
        ("englishOnlyModelEnglishKeyboard", false, FakeOnDeviceModel(languages: [.english], words: ["go"]), [.english]),
        ("noLanguages", false, FakeOnDeviceModel(words: ["go"]), []),
        ("available", false, FakeOnDeviceModel(words: ["go"]), both),
        ("cloudKey", true, FakeOnDeviceModel(words: ["go"]), both),
    ]
    var chosen: [String: String] = [:]
    for (name, hasCloud, model, languages) in sources {
        chosen[name] = ModelPredictionSource.choose(hasCloud: hasCloud, onDevice: model, languages: languages)
            .map { "\($0)" } ?? "none"
    }
    onDevice["source"] = chosen

    let offline = FakeOnDeviceModel(available: false, words: ["go"])
    let offlineTarget = TraitTarget()
    let offlineEngine = engine(offlineTarget, provider: OnDeviceModelPredictions(model: offline))
    await typed(sentence, offlineTarget, offlineEngine)
    await settle(offlineEngine)
    onDevice["unavailable"] = ["bar": bar(offlineEngine), "calls": offline.contexts.count]

    let refusing = FakeOnDeviceModel(words: nil)
    let refusedTarget = TraitTarget()
    let refusedEngine = engine(refusedTarget, provider: OnDeviceModelPredictions(model: refusing))
    await typed(sentence, refusedTarget, refusedEngine)
    await settle(refusedEngine)
    onDevice["refused"] = ["bar": bar(refusedEngine), "calls": refusing.contexts.count]

    let answering = FakeOnDeviceModel(words: ["see", "Visit"])
    let answeredTarget = TraitTarget()
    let answeredEngine = engine(answeredTarget, provider: OnDeviceModelPredictions(model: answering))
    await typed(sentence, answeredTarget, answeredEngine)
    await settle(answeredEngine)
    onDevice["answered"] = ["bar": bar(answeredEngine), "contexts": answering.contexts]
    report["onDevice"] = onDevice

    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}

/// Records each request and answers like the Messages API would; no network.
actor FakeAnthropic {
    enum Reply { case words(String), status(Int), malformed, hang }
    private let reply: Reply
    private(set) var requests: [URLRequest] = []

    init(_ reply: Reply) { self.reply = reply }

    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status: Int
        let body: Data
        switch reply {
        case .words(let text):
            status = 200
            body = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
        case .status(let code): status = code; body = Data("{}".utf8)
        case .malformed: status = 200; body = Data("not json".utf8)
        case .hang:
            try await Task.sleep(for: .seconds(30))
            status = 200; body = Data()
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

let replayKey = "sk-ant-replay-key"

@MainActor
func cloudReport(engine: (TraitTarget, (any ModelPredictionProvider)?, Duration) -> FullKeyboardEngine,
                 sentence: String) async -> [String: Any] {
    func run(_ reply: FakeAnthropic.Reply, key: String? = replayKey,
             configure: (TraitTarget) -> Void = { _ in }) async -> [String: Any] {
        let api = FakeAnthropic(reply)
        let provider = AnthropicPredictionProvider(key: { key }, transport: { try await api.respond($0) })
        let target = TraitTarget()
        configure(target)
        let keyboard = engine(target, provider, .milliseconds(200))
        target.text = sentence
        keyboard.textDidChange()
        await keyboard.waitForSuggestions()
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        while keyboard.modelPredictions?.isActive == true, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let requests = await api.requests
        var result: [String: Any] = ["bar": keyboard.suggestions.map(\.replacement), "requests": requests.count]
        if let request = requests.first,
           let body = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] {
            let messages = body["messages"] as? [[String: Any]]
            result["sent"] = messages?.map { $0["content"] as? String ?? "" } ?? []
            result["model"] = body["model"] as? String ?? ""
            result["keyHeader"] = request.value(forHTTPHeaderField: "x-api-key") == key
            result["url"] = request.url?.absoluteString ?? ""
        }
        return result
    }
    return [
        "noKey": await run(.words("go"), key: nil),
        "emptyKey": await run(.words("go"), key: "  "),
        "success": await run(.words("go\nsee\nVisit")),
        "rateLimited": await run(.status(429)),
        "overloaded": await run(.status(529)),
        "malformed": await run(.malformed),
        "timeout": await run(.hang),
        "secure": await run(.words("go")) { $0.isSecureTextEntry = true },
    ]
}
