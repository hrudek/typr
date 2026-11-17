import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum TranscriptCleanupProduction {
    /// Claude works on any iOS version, so cleanup no longer depends on FoundationModels being present.
    static func dependencies() -> TranscriptCleanupDependencies {
        // The prompt editor is gone (Hex has none): a saved custom prompt is deleted, so the default applies.
        UserDefaults.standard.removeObject(forKey: "typr.cleanupPrompt")
        return TranscriptCleanupDependencies(cleaner: cleaner, background: CleanupBackgroundTasks(),
                                             isEnabled: { TyprSettings().aiCleanup },
                                             observer: CleanupObservers(observers: [CleanupLogger(), diagnostics]))
    }

    private static let engine: @MainActor () -> CleanupEngine = { CleanupEnginePreferences().engine }

    private static let cleaner = SelectedTranscriptCleaner(engine: engine, apple: appleCleaner, anthropic: AnthropicCleaner())

    private static var appleCleaner: any TyprTranscriptCleaning {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return TyprAppleCleaner() }
        #endif
        return UnsupportedAppleCleaner()
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
@MainActor
private final class AppleCleanupSession: CleanupSession {
    private let model: SystemLanguageModel
    private let session: LanguageModelSession

    /// No instructions: as in Hex, the whole request is the one prompt.
    init() {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        self.model = model
        session = LanguageModelSession(model: model)
    }

    func prewarm() async { session.prewarm() }

    func generate(_ prompt: String) async throws -> String {
        guard case .available = model.availability else { throw CleanupModelError.unavailable }
        do {
            // Greedy sampling is temperature 0: the same prompt always gets the same answer.
            let response = try await session.respond(to: prompt,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: min(1200, prompt.utf8.count / 2 + 128)))
            return response.content
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
