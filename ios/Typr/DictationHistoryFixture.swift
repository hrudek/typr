#if targetEnvironment(simulator)
import Foundation

/// Synthetic dictations in a temporary archive for the `settings-history-sample` screenshot scene.
/// Never touches the real archive or shared preferences.
enum DictationHistoryFixture {
    static func isRequested(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == SettingsDestination.historySampleScene
    }

    @MainActor
    static func store() -> DictationLogStore {
        let id = UUID().uuidString
        let settings = TyprSettings(defaults: UserDefaults(suiteName: "typr.history-fixture.\(id)"))
        settings.dictationLog = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typr-history-fixture-\(id)", isDirectory: true)
            .appendingPathComponent("dictation-log.json")
        let store = DictationLogStore(storage: DictationLogStorage(url: url), settings: settings)
        Task { await seed(store) }
        return store
    }

    @MainActor
    private static func seed(_ store: DictationLogStore) async {
        await store.waitForFeedbackReadiness()
        let hour: TimeInterval = 3_600
        let samples: [(age: TimeInterval, text: String, rating: String?)] = [
            (0.2 * hour, "Can we move the design review to Thursday afternoon? I'll send the updated mockups tonight.", nil),
            (2 * hour, "Remind me to pick up the dry cleaning and call the dentist before five.", "good"),
            (26 * hour, "The deploy failed because the staging database migration timed out. Rolling back now.", "bad"),
            (30 * hour, "Thanks, that works for me. See you at the station at eight.", "good"),
            (75 * hour, "Draft reply: happy to help with the onboarding docs next week.", nil)
        ]
        for sample in samples {
            var context = DictationLogContext()
            context.createdAt = Date().addingTimeInterval(-sample.age)
            context.keyboardJob = true
            guard let recording = store.begin(token: store.token(), context: context) else { continue }
            recording.recognized(sample.text, spelled: sample.text, asrMilliseconds: 420)
            recording.finish(text: sample.text, beforeSpelling: sample.text)
            if let rating = sample.rating { store.rate(recording.entryID, rating: rating) }
        }
    }
}
#endif
