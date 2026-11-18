import ActivityKit
import Foundation

@MainActor
final class LiveActivityCoordinator {
    private var currentActivityID: String?

    init() {
        endEarlierActivities()
    }

    func startRecording(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = TyprDictationActivityAttributes.ContentState(
            stage: .recording,
            startedAt: startedAt,
            subtitle: "Recording on this iPhone"
        )
        if let id = currentActivityID {
            Task.detached {
                await Self.updateActivity(id: id, state: state, staleDate: startedAt.addingTimeInterval(90))
            }
            return
        }

        let attributes = TyprDictationActivityAttributes(sessionID: UUID().uuidString)
        if let created = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: startedAt.addingTimeInterval(90)),
            pushType: nil
        ) {
            currentActivityID = created.id
            endEarlierActivities()
        }
    }

    /// Activities outlive the process that started them, also across a restart. One whose
    /// recording ended with an earlier process would otherwise keep showing it.
    private func endEarlierActivities() {
        var ids = Set(Activity<TyprDictationActivityAttributes>.activities.map(\.id))
        if let currentActivityID { ids.remove(currentActivityID) }
        guard !ids.isEmpty else { return }
        Task.detached {
            await Self.end(ids: ids)
        }
    }

    func markTranscribing(startedAt: Date) {
        guard let id = currentActivityID else { return }
        let state = TyprDictationActivityAttributes.ContentState(
            stage: .transcribing,
            startedAt: startedAt,
            subtitle: "Transcribing locally…"
        )
        Task.detached {
            await Self.updateActivity(id: id, state: state, staleDate: Date().addingTimeInterval(30))
        }
    }

    func finishCopied() {
        guard let id = currentActivityID else { return }
        currentActivityID = nil
        let state = TyprDictationActivityAttributes.ContentState(
            stage: .copied,
            startedAt: Date(),
            subtitle: "Copied to clipboard"
        )
        Task.detached {
            await Self.endActivity(
                id: id,
                state: state,
                staleDate: Date().addingTimeInterval(4),
                dismissAfterSeconds: 2
            )
        }
    }

    func endImmediately() {
        let ids = currentActivityID.map { Set([$0]) }
            ?? Set(Activity<TyprDictationActivityAttributes>.activities.map(\.id))
        currentActivityID = nil
        Task.detached {
            await Self.end(ids: ids)
        }
    }

    nonisolated private static func updateActivity(
        id: String,
        state: TyprDictationActivityAttributes.ContentState,
        staleDate: Date?
    ) async {
        guard let activity = Activity<TyprDictationActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated private static func endActivity(
        id: String,
        state: TyprDictationActivityAttributes.ContentState,
        staleDate: Date?,
        dismissAfterSeconds: TimeInterval
    ) async {
        guard let activity = Activity<TyprDictationActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.end(
            ActivityContent(state: state, staleDate: staleDate),
            dismissalPolicy: .after(Date().addingTimeInterval(dismissAfterSeconds))
        )
    }

    nonisolated private static func end(ids: Set<String>) async {
        let state = TyprDictationActivityAttributes.ContentState(
            stage: .copied,
            startedAt: Date(),
            subtitle: "Done"
        )
        for activity in Activity<TyprDictationActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }
}
