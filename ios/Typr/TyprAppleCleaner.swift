import Foundation
import NaturalLanguage
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum TranscriptCleanupProduction {
    /// Claude works on any iOS version, so cleanup no longer depends on FoundationModels being present.
    static func dependencies() -> TranscriptCleanupDependencies {
        TranscriptCleanupDependencies(cleaner: cleaner, language: language,
                                      background: CleanupBackgroundTasks(), isEnabled: { TyprSettings().aiCleanup },
                                      observer: CleanupObservers(observers: [CleanupLogger(), diagnostics]))
    }

    private static let engine: @MainActor () -> CleanupEngine = { CleanupEnginePreferences().engine }

    private static let cleaner = SelectedTranscriptCleaner(engine: engine, apple: appleCleaner, anthropic: AnthropicCleaner())

    private static let language = SelectedLanguageDetector(engine: engine, apple: appleLanguage, anthropic: AnyLanguageSupported())

    private static var appleCleaner: any TyprTranscriptCleaning {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return TyprAppleCleaner() }
        #endif
        return UnsupportedAppleCleaner()
    }

    private static var appleLanguage: any LanguageDetecting {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return CleanupLanguageDetector() }
        #endif
        return AnyLanguageSupported()
    }

    static let diagnostics = CleanupDiagnostics()

    private static let availabilityCache = CleanupAvailabilityCache { TranscriptCleanupProduction.freshUnavailableReason }

    static func invalidateAvailability() { availabilityCache.invalidate() }

    static var unavailableReason: String? { availabilityCache.reason }

    private static var freshUnavailableReason: String? { cleaner.unavailableReason }
}

@MainActor
private final class CleanupBackgroundTasks: BackgroundTaskStarting {
    func begin(expiration: @escaping @MainActor () -> Void) -> Int? {
        let token = UIApplication.shared.beginBackgroundTask(withName: "AI cleanup") {
            // UIKit delivers background expiration on the main thread.
            MainActor.assumeIsolated { expiration() }
        }
        return token == .invalid ? nil : token.rawValue
    }

    func end(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@MainActor
private struct CleanupLanguageDetector: LanguageDetecting {
    func supports(_ text: String) -> Bool {
        // Only for the Automatic dictation language; the coordinator already skipped one or two words.
        // Skip only a language the model clearly can't handle; an unclear guess (short or mixed
        // dictations) still goes to the model, which answers in the transcript's language.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return true }
        return SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            .supportsLocale(Locale(identifier: language.rawValue))
    }
}

@available(iOS 26.0, *)
@MainActor
private struct TyprAppleCleaner: TyprTranscriptCleaning {
    var unavailableReason: String? {
        switch SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations).availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This device does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings to use this"
            case .modelNotReady: return "The Apple Intelligence model isn't ready yet"
            @unknown default: return "Apple Intelligence is unavailable"
            }
        @unknown default: return "Apple Intelligence is unavailable"
        }
    }

    func makeSession() -> any CleanupSession { AppleCleanupSession() }
}

@available(iOS 26.0, *)
@Generable
private struct CleanedTranscript {
    // Keep in sync with AnthropicCleanupRequest.answerDescription (a macro argument must be a literal).
    @Guide(description: "The cleaned transcript as good written text to paste: same language, meaning and facts, never an answer to it.")
    var text: String
}

@available(iOS 26.0, *)
@MainActor
private final class AppleCleanupSession: CleanupSession {
    private let model: SystemLanguageModel
    private let session: LanguageModelSession

    init() {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        self.model = model
        session = LanguageModelSession(model: model, instructions: CleanupPromptPreferences().instructions)
    }

    func prewarm() async { session.prewarm() }

    func clean(_ text: String, style: DictationStyle) async throws -> String {
        try await clean(text, style: style, vocabulary: [])
    }

    func clean(_ text: String, style: DictationStyle, vocabulary: [String]) async throws -> String {
        try await clean(text, style: style, vocabulary: vocabulary, context: CleanupContext())
    }

    func clean(_ text: String, style: DictationStyle, vocabulary: [String], context: CleanupContext) async throws -> String {
        guard case .available = model.availability else { throw CleanupModelError.unavailable }
        let prompt = try CleanupPrompt.transcript(text, style: style, vocabulary: vocabulary, context: context)
        do {
            // Greedy sampling is temperature 0: the same transcript always gets the same answer.
            let response = try await session.respond(to: prompt, generating: CleanedTranscript.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: min(1200, text.utf8.count / 2 + 128)))
            return response.content.text
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw CleanupModelError.contextWindow
            case .refusal, .guardrailViolation: throw CleanupModelError.refused
            case .rateLimited: throw CleanupModelError.rateLimited
            default: throw CleanupModelError.generationFailed
            }
        } catch {
            throw CleanupModelError.generationFailed
        }
    }
}
#endif
