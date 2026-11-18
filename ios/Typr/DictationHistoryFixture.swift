#if targetEnvironment(simulator)
import Foundation

/// Synthetic dictations in a temporary archive for the history screenshot scenes.
/// Never touches the real archive or shared preferences.
@MainActor
enum DictationHistoryFixture {
    private static var seeding: Task<UUID?, Never>?

    private static var scene: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var isRequested: Bool {
        scene == SettingsDestination.historySampleScene || scene == SettingsDestination.historyDetailScene
    }

    static func store() -> DictationLogStore {
        let id = UUID().uuidString
        let settings = TyprSettings(defaults: UserDefaults(suiteName: "typr.history-fixture.\(id)"))
        settings.dictationLog = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typr-history-fixture-\(id)", isDirectory: true)
            .appendingPathComponent("dictation-log.json")
        let store = DictationLogStore(storage: DictationLogStorage(url: url), settings: settings)
        seeding = Task { await seed(store) }
        return store
    }

    /// The Problem-rated sample, opened only by the detail scene.
    static func detailEntry() async -> UUID? {
        guard scene == SettingsDestination.historyDetailScene else { return nil }
        return await seeding?.value
    }

    private static func seed(_ store: DictationLogStore) async -> UUID? {
        await store.waitForFeedbackReadiness()
        let hour: TimeInterval = 3_600
        let samples: [(age: TimeInterval, text: String, rating: String?)] = [
            (0.2 * hour, "Can we move the design review to Thursday afternoon? I'll send the updated mockups tonight.", nil),
            (2 * hour, "Remind me to pick up the dry cleaning and call the dentist before five.", "good"),
            (26 * hour, "The deploy failed because the stage in database migration timed out. Rolling back now.", "bad"),
            (30 * hour, "Thanks, that works for me. See you at the station at eight.", "good"),
            (75 * hour, "Draft reply: happy to help with the onboarding docs next week.", nil)
        ]
        var problem: UUID?
        for sample in samples {
            var context = DictationLogContext()
            context.createdAt = Date().addingTimeInterval(-sample.age)
            context.keyboardJob = true
            guard let recording = store.begin(token: store.token(), context: context) else { continue }
            recording.recognized(sample.text, spelled: sample.text, asrMilliseconds: 420)
            recording.finish(text: sample.text, beforeSpelling: sample.text)
            if sample.rating == "bad" {
                problem = recording.entryID
                store.rate(recording.entryID, rating: "bad", issues: ["misheard", "vocabulary_name"])
                store.saveFeedback(for: recording.entryID, expectedText: nil, note: "\"staging\" became \"stage in\".")
            } else if let rating = sample.rating {
                store.rate(recording.entryID, rating: rating)
            }
        }
        return problem
    }
}
#endif
