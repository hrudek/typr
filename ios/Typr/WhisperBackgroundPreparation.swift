import BackgroundTasks
import OSLog
import UIKit

/// Only the app's existing preparation uses this runtime; it never owns or creates a model.
@MainActor
protocol WhisperPreparationScheduling: AnyObject {
    /// `userInitiated`: a tap in Typr started this preparation. Only then may a continued
    /// task (and its system Live Activity) be requested; automatic starts use UIKit grace only.
    func begin(userInitiated: Bool, expiration: @escaping @MainActor () -> Void)
    func update(_ progress: ModelPreparationProgress)
    func sceneDidBecomeActive()
    func finish(success: Bool)
    func scheduleMaintenance(needed: Bool)
}

@MainActor
final class WhisperBackgroundPreparation: WhisperPreparationScheduling {
    static let shared = WhisperBackgroundPreparation()
    static let maintenanceIdentifier = "dev.rudek.typr.whisper-maintenance"
    static let continuedPrefix = "dev.rudek.typr.whisper-prepare"

    private static let logger = Logger(subsystem: "dev.rudek.typr", category: "WhisperPreparation")
    private var latestProgress: ModelPreparationProgress?
    private var registered = false
    private var maintenanceRegistered = false
    private var maintenanceSubmitted = false
    private var operation: UUID?
    private var operationUserInitiated = false
    private var shownSubtitle: String?
    private var expiration: (@MainActor () -> Void)?
    private var continued: BGTask?
    private var maintenance: BGTask?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var heartbeat: Task<Void, Never>?
    private var pendingSubmission: Task<Void, Never>?

    /// Sub-units per milestone stage, filled only by heartbeats while that stage runs.
    static let unitsPerStage: Int64 = 1000
    /// Well inside the observed stall window; 999 ticks cover more than 80 minutes per stage.
    static let heartbeatInterval: Duration = .seconds(5)
    static let startConfirmationDelay: Duration = .seconds(1)
    static let maxSubmissionAttempts = 3

    /// Called by the app delegate before didFinishLaunching returns. Continued-task handlers
    /// are registered for unique concrete identifiers immediately before foreground submission
    /// (the documented exception to the launch-time registration rule).
    func register() {
        guard !registered else { return }
        registered = true
        maintenanceRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.maintenanceIdentifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                Self.shared.handleMaintenance(task)
            }
        }
    }

    func begin(userInitiated: Bool, expiration: @escaping @MainActor () -> Void) {
        finish(success: false)
        let token = UUID()
        operation = token
        operationUserInitiated = userInitiated
        self.expiration = expiration
        // Covers the handoff to the continued task, and is the entire (bounded) fallback on
        // older iOS or rejected requests. No microphone, audio session or network is involved.
        grace = UIApplication.shared.beginBackgroundTask(withName: "Prepare Whisper") { [weak self] in
            // UIKit invokes this synchronously on the main thread. End the assertion before
            // returning; enqueueing a Task here could outlive the expiration deadline.
            MainActor.assumeIsolated { self?.expire(token) }
        }
        // Apple: continued tasks start only from an explicit action, never automatically
        // (launch, reopening, maintenance), even if the person chose the engine earlier.
        guard userInitiated else { return }
        submitContinued(for: token, attempt: 1)
    }

    /// A tapped preparation that is still running without a continued task (a rejected
    /// request) asks again whenever the app becomes active. Submission requires foreground.
    func sceneDidBecomeActive() {
        guard let token = operation, operationUserInitiated, continued == nil,
              pendingSubmission == nil else { return }
        submitContinued(for: token, attempt: 1)
    }

    private func submitContinued(for token: UUID, attempt: Int) {
        guard #available(iOS 26.0, *), operation == token, continued == nil,
              UIApplication.shared.applicationState == .active else { return }
        pendingSubmission?.cancel()
        pendingSubmission = nil
        let identifier = "\(Self.continuedPrefix).\(UUID().uuidString)"
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                // A late handler from an earlier attempt must not replace the attached task.
                guard let self, self.operation == token, self.continued == nil else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task, token: token)
            }
        }
        guard accepted else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: Self.taskTitle, subtitle: Self.taskSubtitle(for: latestProgress)
        )
        request.strategy = .fail // Never queue a second, stale preparation.
        // Default is zero, not "all supported resources". ANE access uses the separate
        // Background Inference entitlement; the only additional resource bit is GPU.
        request.requiredResources = []
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Foreground work still runs; UIKit grace is all that is available in background.
            let error = error as NSError
            Self.logger.error("Continued preparation submission failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
            return
        }
        // The scheduler can reject a foreground submission without throwing; observed on device
        // when the app had become active ~20 ms earlier and was not yet in the scheduler's
        // foreground list. The launch handler then never runs. Confirm the start and retry.
        pendingSubmission = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startConfirmationDelay)
            guard !Task.isCancelled, let self, self.operation == token, self.continued == nil else { return }
            self.pendingSubmission = nil
            Self.logger.notice("Continued preparation was not started by the system: attempt=\(attempt)")
            guard attempt < Self.maxSubmissionAttempts else { return }
            // Withdraw this request first so a slow launch cannot start a duplicate task that
            // the late-handler guard would then have to fail visibly in the Dynamic Island.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            self.submitContinued(for: token, attempt: attempt + 1)
        }
    }

    private func attach(_ task: BGTask, token: UUID) {
        pendingSubmission?.cancel()
        pendingSubmission = nil
        continued = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(token) }
        }
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            Self.updateTaskProgress(task.progress, from: latestProgress)
            shownSubtitle = nil
            updateSubtitle(of: task)
            startHeartbeat(for: task, token: token)
            Self.logger.notice("Continued preparation task started")
        }
        endGrace()
    }

    /// The scheduler marks a continued task stalled and expires it when NSProgress does not
    /// change within its expected cadence (observed: ~46 s without an update). A single Core ML
    /// specialization can run for minutes without any callback, so milestones alone are too
    /// sparse. While the task is attached, each tick advances one sub-unit inside the running
    /// stage. It never reaches that stage's milestone and never completes the task.
    @available(iOS 26.0, *)
    private func startHeartbeat(for task: BGContinuedProcessingTask, token: UUID) {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            var loggedCeiling = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self, self.operation == token, self.continued === task else { return }
                if Self.advanceHeartbeat(task.progress) {
                    loggedCeiling = false
                } else if !loggedCeiling {
                    // Ceiling of the running stage (~83 min); a later stall expiry is expected.
                    // Keeps looping: the next real milestone opens room again.
                    loggedCeiling = true
                    Self.logger.notice("Preparation heartbeat reached its stage ceiling")
                }
            }
        }
    }

    /// System progress counts stages. Each finished milestone jumps to its stage boundary;
    /// heartbeats fill sub-units inside the current stage only. No percent is shown in the app.
    static func updateTaskProgress(_ progress: Progress, from update: ModelPreparationProgress?) {
        let stages = WhisperPreparationComponent.totalPreparationStages
        progress.totalUnitCount = stages * unitsPerStage
        guard let stage = update?.stageProgress, stage.total == stages else { return }
        // Success is committed only by finish(), not a possibly queued "ready" callback.
        let milestone = min(max(0, stage.completed), stages - 1) * unitsPerStage
        progress.completedUnitCount = max(progress.completedUnitCount, milestone)
    }

    /// Advances one sub-unit, stopping one unit short of the next milestone (and of completion).
    @discardableResult
    static func advanceHeartbeat(_ progress: Progress) -> Bool {
        let total = WhisperPreparationComponent.totalPreparationStages * unitsPerStage
        guard progress.totalUnitCount == total else { return false }
        let completed = progress.completedUnitCount
        let ceiling = min((completed / unitsPerStage + 1) * unitsPerStage - 1, total - 1)
        guard completed < ceiling else { return false }
        progress.completedUnitCount = completed + 1
        return true
    }

    func update(_ progress: ModelPreparationProgress) {
        latestProgress = progress
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            Self.updateTaskProgress(task.progress, from: progress)
            updateSubtitle(of: task)
        }
    }

    /// Succinct title and a short, informative subtitle (Apple's guidance). The system bar
    /// shows how far it is; detailed stage names and step counts stay in the app.
    static let taskTitle = "Preparing Whisper"

    static func taskSubtitle(for progress: ModelPreparationProgress?) -> String {
        guard let progress, let stage = progress.stageProgress else { return "Starting" }
        if stage.completed >= stage.total - 1 { return "Checking model" }
        if progress.detail.hasPrefix("Optimizing") { return "Optimizing for this iPhone" }
        return "Loading model"
    }

    /// Pushes text to the system UI only when the step changes, not on every callback.
    @available(iOS 26.0, *)
    private func updateSubtitle(of task: BGContinuedProcessingTask) {
        let subtitle = Self.taskSubtitle(for: latestProgress)
        guard subtitle != shownSubtitle else { return }
        shownSubtitle = subtitle
        task.updateTitle(Self.taskTitle, subtitle: subtitle)
    }

    func finish(success: Bool) {
        operation = nil
        operationUserInitiated = false
        shownSubtitle = nil
        expiration = nil
        latestProgress = nil
        heartbeat?.cancel()
        heartbeat = nil
        pendingSubmission?.cancel()
        pendingSubmission = nil
        let tasks = [continued, maintenance].compactMap { $0 }
        continued = nil
        maintenance = nil
        for task in tasks {
            if #available(iOS 26.0, *), success, let task = task as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
        endGrace()
    }

    /// Idempotent within a process: resubmitting would cancel the pending request and push its
    /// earliest begin date out again on every activation or background transition. A request
    /// left by an earlier process survives `needed: false`; that is harmless because
    /// `handleMaintenance` re-checks engine, install and readiness before doing any work.
    func scheduleMaintenance(needed: Bool) {
        guard maintenanceRegistered, needed != maintenanceSubmitted else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.maintenanceIdentifier)
        maintenanceSubmitted = false
        guard needed else { return }
        let request = BGProcessingTaskRequest(identifier: Self.maintenanceIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        // Discretionary, not an immediate launch or a post-update execution guarantee.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            maintenanceSubmitted = true
        } catch {
            let error = error as NSError
            Self.logger.error("Maintenance submission failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
    }

    private func handleMaintenance(_ task: BGTask) {
        maintenanceSubmitted = false // The system consumed the request.
        guard task is BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        // A stale request can outlive a changed preference or removed install. Check before
        // constructing the shared controller: its normal launch path can prepare other engines.
        guard TyprSettings().preferredSpeechEngine == .whisperLargeV3Turbo,
              WhisperModelStore.production.isInstalled else {
            task.setTaskCompleted(success: true)
            return
        }
        let controller = DictationController.shared
        guard controller.needsWhisperPreparation else {
            task.setTaskCompleted(success: true)
            return
        }
        if operation == nil {
            // Starting uses the same serial controller loader as foreground preparation.
            controller.prepareInstalledWhisperIfNeeded()
        }
        guard let token = operation else {
            task.setTaskCompleted(success: false)
            return
        }
        maintenance = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(token) }
        }
        endGrace()
        scheduleMaintenance(needed: true)
    }

    private func expire(_ token: UUID) {
        guard operation == token else { return }
        Self.logger.notice("Preparation runtime expired; cancelling current generation")
        let cancel = expiration
        finish(success: false)
        cancel?()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        let old = grace
        grace = .invalid
        UIApplication.shared.endBackgroundTask(old)
    }
}

/// Registration must happen even on a background-only launch, without opening a SwiftUI view.
final class TyprAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            WhisperBackgroundPreparation.shared.register()
        }
        return true
    }
}
