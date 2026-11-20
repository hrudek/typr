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

    private final class FakeSystemModel: OnDeviceNextWordModel {
        let isAvailable: Bool
        let languages: Set<SpatialWordDecoder.Language>
        private let answer: (String) -> [String]
        private(set) var contexts: [String] = []
        private(set) var prewarms = 0

        init(available: Bool = true, languages: Set<SpatialWordDecoder.Language> = [.german, .english],
             answer: @escaping (String) -> [String] = { _ in ["go"] }) {
            isAvailable = available
            self.languages = languages
            self.answer = answer
        }

        func supports(_ language: SpatialWordDecoder.Language) -> Bool { languages.contains(language) }
        func prewarm() { prewarms += 1 }

        func nextWords(after context: String) async throws -> [String] {
            contexts.append(context)
            return answer(context)
        }
    }

    private final class CloudModel: ModelPredictionProvider {
        func predictions(for request: ModelPredictionRequest) async throws -> [String] { ["cloud"] }
    }

    private let sentence = "I would like to "

    private func keyboard(_ model: FakeSystemModel?) throws -> (FullKeyboardEngine, FixtureTextTarget) {
        let target = FixtureTextTarget()
        let engine = FullKeyboardEngine(target: target, autocorrect: AutocorrectEngine(
            checker: Checker(), spatialDecoder: nil,
            contextResources: .init(model: try XCTUnwrap(BundledKeyboardData.contextModel))))
        engine.width = 393
        engine.modelPredictions = model.map {
            ModelPredictionSession(provider: OnDeviceModelPredictions(model: $0), timeout: .seconds(5))
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

        var keyStored = false
        keyboard.hasCloudKey = { keyStored }
        keyboard.cloudPredictions = CloudModel()
        XCTAssertTrue(keyboard.engine.modelPredictions?.provider is OnDeviceModelPredictions, "No key: on-device")
        keyStored = true
        keyboard.prepareForField()
        XCTAssertTrue(keyboard.engine.modelPredictions?.provider is CloudModel, "A stored key wins")
        XCTAssertEqual(model.prewarms, 1, "No prewarm while the cloud runs")
        keyStored = false
        keyboard.prepareForField()
        XCTAssertTrue(keyboard.engine.modelPredictions?.provider is OnDeviceModelPredictions, "Key removed")
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
        let counted = try await countedBar()
        let model = FakeSystemModel { _ in ["see", "Visit"] }
        let (engine, target) = try keyboard(model)
        await type(sentence, engine, target)
        await settle(engine)
        XCTAssertEqual(model.contexts, [sentence], "Only the text before the caret")
        let shown = bar(engine)
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(shown[1], "see", "Likeliest model word in the centre")
        XCTAssertEqual(shown[0], counted[1], "Then the likeliest count word")
        XCTAssertEqual(shown[2].lowercased(), "visit")
    }
}
