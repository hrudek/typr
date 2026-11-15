import BackgroundTasks
import OSLog
import UIKit

/// Only the app's existing preparation uses this runtime; it never owns or creates a model.
@MainActor
protocol WhisperPreparationScheduling: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void)
    func update(_ progress: ModelPreparationProgress)
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
    private var operation: UUID?
    private var expiration: (@MainActor () -> Void)?
    private var continued: BGTask?
    private var maintenance: BGTask?
    private var grace: UIBackgroundTaskIdentifier = .invalid

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

    func begin(expiration: @escaping @MainActor () -> Void) {
        finish(success: false)
        let token = UUID()
        operation = token
        self.expiration = expiration
        // Covers the handoff to the continued task, and is the entire (bounded) fallback on
        // older iOS or rejected requests. No microphone, audio session or network is involved.
        grace = UIApplication.shared.beginBackgroundTask(withName: "Prepare Whisper") { [weak self] in
            // UIKit invokes this synchronously on the main thread. End the assertion before
            // returning; enqueueing a Task here could outlive the expiration deadline.
            MainActor.assumeIsolated { self?.expire(token) }
        }
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active else { return }
        let identifier = "\(Self.continuedPrefix).\(token.uuidString)"
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.operation == token else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.continued = task
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.expire(token) }
                }
                if let task = task as? BGContinuedProcessingTask {
                    Self.updateTaskProgress(task.progress, from: self.latestProgress)
                    if let progress = self.latestProgress {
                        task.updateTitle("Prepare Whisper", subtitle: progress.detail)
                    }
                    Self.logger.notice("Continued preparation task started")
                }
                self.endGrace()
            }
        }
        guard accepted else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Prepare Whisper", subtitle: "Preparing the installed model"
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
        }
    }

    /// Report only finished milestones, never synthetic timer-based progress. Core ML's
    /// duration remains unknown; the system's units count stages rather than time/percent.
    static func updateTaskProgress(_ progress: Progress, from update: ModelPreparationProgress?) {
        let total = WhisperPreparationComponent.totalPreparationStages
        progress.totalUnitCount = total
        guard let stage = update?.stageProgress, stage.total == total else { return }
        // Success is committed only by finish(), not a possibly queued "ready" callback.
        progress.completedUnitCount = max(progress.completedUnitCount, min(max(0, stage.completed), total - 1))
    }

    func update(_ progress: ModelPreparationProgress) {
        latestProgress = progress
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle("Prepare Whisper", subtitle: progress.detail)
            Self.updateTaskProgress(task.progress, from: progress)
        }
    }

    func finish(success: Bool) {
        operation = nil
        expiration = nil
        latestProgress = nil
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

    func scheduleMaintenance(needed: Bool) {
        guard maintenanceRegistered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.maintenanceIdentifier)
        guard needed else { return }
        let request = BGProcessingTaskRequest(identifier: Self.maintenanceIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        // Discretionary, not an immediate launch or a post-update execution guarantee.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleMaintenance(_ task: BGTask) {
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
