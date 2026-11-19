import Foundation
import XCTest
@testable import Typr

@MainActor
final class OnDeviceModelPredictionTests: XCTestCase {
    private final class Checker: TextChecking {
        func isWordValid(_ word: String) -> Bool { true }
        func guesses(for word: String) -> [String] { [] }
        func completions(for prefix: String) -> [String] { [] }
    }

    private struct Refusal: Error {}

    private final class FakeSystemModel: OnDeviceNextWordModel {
        enum Mode { case answer, refuse, hold }
        let isAvailable: Bool
        let languages: Set<SpatialWordDecoder.Language>
        private let mode: Mode
        private let answer: (String) -> [String]
        private(set) var contexts: [String] = []
        private(set) var prewarms = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        init(available: Bool = true, languages: Set<SpatialWordDecoder.Language> = [.german, .english],
             mode: Mode = .answer, answer: @escaping (String) -> [String] = { _ in ["go"] }) {
            isAvailable = available
            self.languages = languages
            self.mode = mode
            self.answer = answer
        }

        func supports(_ language: SpatialWordDecoder.Language) -> Bool { languages.contains(language) }
        func prewarm() { prewarms += 1 }

        func nextWords(after context: String) async throws -> [String] {
            contexts.append(context)
            switch mode {
            case .answer: break
            case .refuse: throw Refusal()
            case .hold: await withCheckedContinuation { held.append($0) }
            }
            return answer(context)
        }

        func waitForRequests(_ count: Int) async {
            while contexts.count < count || held.count < count { await Task.yield() }
        }

        func release() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    private final class CloudModel: ModelPredictionProvider {
        func predictions(for request: ModelPredictionRequest) async throws -> [String] { ["cloud"] }
    }

    private let sentence = "I would like to "

    private func keyboard(_ model: FakeSystemModel?, timeout: Duration = .seconds(5),
                          configure: (FixtureTextTarget) -> Void = { _ in }) throws -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget()
        configure(target)
        let engine = FullKeyboardEngine(target: target, autocorrect: AutocorrectEngine(
            checker: Checker(), spatialDecoder: nil,
            contextResources: .init(model: try XCTUnwrap(BundledKeyboardData.contextModel))))
        engine.width = 393
        engine.modelPredictions = model.map {
            ModelPredictionSession(provider: OnDeviceModelPredictions(model: $0), timeout: timeout)
        }
        engine.configureForField()
        return (engine, target)
    }

    private func type(_ text: String, _ engine: FullKeyboardEngine, _ target: FixtureTextTarget) async {
        target.insertText(text)
        engine.textDidChange()
        await engine.waitForSuggestions()
    }

    private func settle(_ engine: FullKeyboardEngine) async {
        await engine.waitForSuggestions()
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        while engine.modelPredictions?.isActive == true, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func bar(_ engine: FullKeyboardEngine) -> [String] { engine.suggestions.map(\.replacement) }

    private func countedBar() async throws -> [String] {
        let (engine, target) = try keyboard(nil)
        await type(sentence, engine, target)
        return bar(engine)
    }

    private func view() -> FullKeyboardView {
        FullKeyboardView(model: KeyboardViewModel(), target: FixtureTextTarget(),
                         autocorrect: AutocorrectEngine(spatialDecoder: nil))
    }

    // MARK: - Choosing the source

    func testOnDeviceModelRunsOnlyWhenAvailableForEveryEnabledLanguage() {
        let both: Set<SpatialWordDecoder.Language> = [.german, .english]
        XCTAssertNil(ModelPredictionSource.choose(hasCloud: false, onDevice: nil, languages: both))
        XCTAssertNil(ModelPredictionSource.choose(hasCloud: false, onDevice: FakeSystemModel(available: false),
                                                  languages: both))
        XCTAssertNil(ModelPredictionSource.choose(hasCloud: false, onDevice: FakeSystemModel(languages: [.english]),
                                                  languages: both), "German enabled but unsupported")
        XCTAssertNil(ModelPredictionSource.choose(hasCloud: false, onDevice: FakeSystemModel(), languages: []))
        XCTAssertEqual(ModelPredictionSource.choose(hasCloud: false, onDevice: FakeSystemModel(languages: [.english]),
                                                    languages: [.english]), .onDevice)
        XCTAssertEqual(ModelPredictionSource.choose(hasCloud: false, onDevice: FakeSystemModel(), languages: both),
                       .onDevice)
        XCTAssertEqual(ModelPredictionSource.choose(hasCloud: true, onDevice: FakeSystemModel(), languages: both),
                       .cloud, "A stored cloud key wins")
    }

    func testKeyboardInstallsAndPrewarmsTheOnDeviceModelOnlyWhenUsable() {
        let unavailable = FakeSystemModel(available: false)
        let offline = view()
        offline.onDeviceModel = unavailable
        offline.prepareForField()
        XCTAssertNil(offline.engine.modelPredictions)
        XCTAssertEqual(unavailable.prewarms, 0)

        let unsupported = FakeSystemModel(languages: [])
        let foreign = view()
        foreign.onDeviceModel = unsupported
        foreign.prepareForField()
        XCTAssertNil(foreign.engine.modelPredictions)

        let model = FakeSystemModel()
        let keyboard = view()
        keyboard.onDeviceModel = model
        keyboard.prepareForField()
        XCTAssertTrue(keyboard.engine.modelPredictions?.provider is OnDeviceModelPredictions)
        XCTAssertEqual(model.prewarms, 1, "Prewarmed when the keyboard appears")

        keyboard.cloudPredictions = CloudModel()
        XCTAssertTrue(keyboard.engine.modelPredictions?.provider is CloudModel)
        keyboard.cloudPredictions = nil
        XCTAssertTrue(keyboard.engine.modelPredictions?.provider is OnDeviceModelPredictions)
    }

    // MARK: - Requests

    func testUnavailableModelIsNeverAskedAndCountPredictionsStay() async throws {
        let counted = try await countedBar()
        let model = FakeSystemModel(available: false)
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        await settle(engine)
        XCTAssertEqual(model.contexts, [])
        XCTAssertEqual(bar(engine), counted)
    }

    func testOnDeviceWordsMergeIntoTheBar() async throws {
        let model = FakeSystemModel { _ in ["see", "Visit"] }
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        await settle(engine)
        XCTAssertEqual(model.contexts, [sentence], "Only the text before the caret")
        XCTAssertEqual(Array(bar(engine).prefix(2)), ["Visit", "see"])
    }

    func testRefusalTimeoutAndUnusableWordsKeepCountPredictions() async throws {
        let counted = try await countedBar()
        let refusing = FakeSystemModel(mode: .refuse)
        let (refused, refusedTarget) = try keyboard(refusing)
        await type(sentence, refused, refusedTarget)
        await settle(refused)
        XCTAssertEqual(refusing.contexts.count, 1)
        XCTAssertEqual(bar(refused), counted)

        let slow = FakeSystemModel(mode: .hold) { _ in ["late"] }
        let (timed, timedTarget) = try keyboard(slow, timeout: .milliseconds(50))
        await type(sentence, timed, timedTarget)
        await settle(timed)
        await slow.waitForRequests(1)
        slow.release()
        await Task.yield()
        XCTAssertEqual(bar(timed), counted)

        let (garbled, garbledTarget) = try keyboard(FakeSystemModel { _ in ["two words", "1234", ""] })
        await type(sentence, garbled, garbledTarget)
        await settle(garbled)
        XCTAssertEqual(bar(garbled), counted)
    }

    func testStaleAnswerIsDropped() async throws {
        let model = FakeSystemModel(mode: .hold) { $0.hasSuffix("go ") ? ["fresh"] : ["stale"] }
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        await type("go ", engine, target)
        await model.waitForRequests(2)
        model.release()
        await settle(engine)
        XCTAssertFalse(bar(engine).contains("stale"))
        XCTAssertTrue(bar(engine).contains("fresh"))
    }

    func testSecureUrlEmailAndNumberFieldsNeverReachTheModel() async throws {
        let fields: [(FixtureTextTarget) -> Void] = [
            { $0.isSecureTextEntry = true }, { $0.keyboardType = .URL }, { $0.keyboardType = .emailAddress },
            { $0.keyboardType = .numberPad }, { $0.keyboardType = .numbersAndPunctuation },
        ]
        for configure in fields {
            let model = FakeSystemModel()
            let (engine, target) = try keyboard(model, configure: configure)
            await type(sentence, engine, target)
            await settle(engine)
            XCTAssertEqual(model.contexts, [])
        }
    }
}
