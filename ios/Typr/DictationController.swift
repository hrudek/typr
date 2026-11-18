import AVFAudio
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class DictationController {
    static let shared = DictationController(
        autoPrepareOnInit: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        cleanup: TranscriptCleanupProduction.dependencies(),
        dictationLog: .shared,
        statistics: UsageDictationRecorder(store: UsageStatisticsStore()),
        modelBackground: ModelBackgroundPreparation.shared,
        deferPreparationUntilActive: true
    )

    private static let minCaptureDuration: TimeInterval = 0.30
    private static let maxCaptureDuration: TimeInterval = 60.0
    private static let resultDeliveryTTL: TimeInterval = 30.0
    /// Waits before each further microphone activation attempt. After another app ends an audio
    /// interruption (observed: WhatsApp voice messages), iOS refuses Typr's activation for about
    /// five seconds ("Cannot start playing"); later attempts succeed. About 5.5 s in total.
    nonisolated static let audioActivationRetryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .milliseconds(1500), .milliseconds(2500),
    ]
    nonisolated static let audioBusyMessage = "Another app is still using audio. Try again in a moment."

    enum Phase: Equatable {
        case modelRequired
        case preparingModel
        case ready
        case requestingPermission
        case recording
        case transcribing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparingModel, .requestingPermission, .transcribing:
                true
            default:
                false
            }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    enum AutoReturnState: Equatable {
        case idle
        case attempting
        case succeeded
        case swipeFallback
    }

    private struct ActiveCaptureSession {
        let statisticsToken: UsageCaptureToken?
        let generation: UInt64
        let capture: any ActiveAudioCapture
        let startedAt: TimeInterval
        let keyboardJobID: String?
        let style: DictationStyle
        let vocabularyTerms: [String]
        /// Speech hints, spelling passes and cleanup terms (Custom vocabulary + built-in glossary).
        let vocabulary: DictationVocabulary
        let vocabularyEnabled: Bool
        let typrCleanupEnabled: Bool
        let copyToPasteboard: Bool
        let cleanupJob: CleanupJob?
        let cleanupSkipReason: CleanupSkipReason?
        let logToken: DictationLogToken?
        let logCleanupPath: DictationLogCleanupPath
        /// Dictation language, host app and data-only caret text for Typr cleanup, frozen at start.
        let cleanupContext: CleanupContext
        /// The engine and language this capture is transcribed with, frozen at start: a later
        /// engine or language change applies to the next dictation only.
        let transcriber: any LocalTranscribing
        let language: DictationLanguage
        let speechLanguageName: String
    }

    private struct PendingKeyboardHandoff {
        let jobID: String?
        let style: DictationStyle
        let requestedAt: TimeInterval
        let attemptAutoReturn: Bool
    }

    private var transcriber: any LocalTranscribing
    /// Test seam for the automatic (no engine chosen) path; nil uses the provider's automatic choice.
    private let transcriberFactory: (() async -> any LocalTranscribing)?
    private let engineProvider: any SpeechEngineProviding
    private let modelBackground: (any ModelPreparationScheduling)?
    private var deferredLaunchPreparation: Bool
    private let customVocabularySettings: CustomVocabularySettings
    private let audio: any AudioManaging
    private let keyboardBridge: KeyboardBridge
    private let fileManager: FileManager
    private let now: () -> TimeInterval
    private let liveActivity = LiveActivityCoordinator()
    private let hostReturner: HostReturner
    /// The app the current cold-start handoff came from, by bundle ID; nil when the keyboard could not name it.
    private var returnHost: String?

    private let cleanup: TranscriptCleanupDependencies?
    private let cleanupCoordinator = CleanupCoordinator()
    private let statistics: UsageDictationRecorder?
    private let languageSettings: TyprSettings
    private var pendingCleanupJob: CleanupJob?
    private var transcriptionHeartbeat: Task<Void, Never>?
    private let dictationLog: DictationLogStore?
    private var transcribingLog: DictationLogRecording?
    @ObservationIgnored private var loudestAverageDBFS: Float?

    private func endCleanupJob() {
        if let job = pendingCleanupJob {
            cleanupCoordinator.cancel(job.id)
            job.finish()
        }
        pendingCleanupJob = nil
        transcriptionHeartbeat?.cancel()
        transcriptionHeartbeat = nil
    }

    private var jobGeneration: UInt64 = 0
    private var modelPrepGeneration: UInt64 = 0
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    private var activeCapture: ActiveCaptureSession?
    /// Latched before audio activation: once interrupted, other audio may report false.
    private var releaseAudioAfterCapture = false
    private var meterTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    // Cancellation is cooperative: an old task can still own a model after the UI returns to
    // ready. Keep a fence until its actual completion, including tasks superseded by a capture.
    private var inFlightTranscriptions: Set<UUID> = []
    private var inFlightPermissionRequests = 0
    private var pendingAppleLanguageChange = false
    private var keyboardSessionTask: Task<Void, Never>?
    private var autoReturnFallbackTask: Task<Void, Never>?

    private var lastKeyboardCommandID: String?
    private var lastHandledLaunchJobID: String?
    private var activeKeyboardJobID: String?
    private var keyboardResultID: String?
    private var keyboardFeedbackOffer: DictationFeedbackOffer?
    private var keyboardResultExpiresAt: TimeInterval?
    private var keyboardResult: String?
    private var keyboardMessage: String?
    private var pendingHandoff: PendingKeyboardHandoff?
    private var keyboardSessionExpiresAt: TimeInterval = 0
    private var suspendedWarmSessionOnInterruption = false
    @ObservationIgnored private var interruptionResumeTask: Task<Void, Never>?
    /// Between `.interruptionBegan` and `.interruptionEnded`, independent of a pending resume.
    private var interruptionInProgress = false
    private let audioRetryDelays: [Duration]
    /// Set when a transcription failed in a way that may come from the engine itself. Other
    /// failures (microphone, silence) keep the prepared model for the next dictation.
    private var modelNeedsReload = false

    private(set) var phase = Phase.modelRequired
    private(set) var isModelReady = false
    private(set) var transcript = ""
    private(set) var lastLoggedTranscriptID: UUID?
    @ObservationIgnored private(set) var audioLevel: Float = 0
    @ObservationIgnored private(set) var loudnessDB: Float = -120
    @ObservationIgnored private var rawRecordingDuration: TimeInterval = 0
    private(set) var recordingWholeSeconds: Int = 0
    private(set) var recordingDuration: TimeInterval {
        get { rawRecordingDuration }
        set {
            rawRecordingDuration = newValue
            let whole = max(0, Int(newValue))
            if recordingWholeSeconds != whole {
                recordingWholeSeconds = whole
            }
        }
    }
    private(set) var copied = false
    private(set) var keyboardSessionEnabled = false
    @ObservationIgnored private var rawKeyboardSessionRemaining: TimeInterval = 0
    private(set) var keyboardSessionDisplayRemaining = "0:00"
    private(set) var keyboardSessionRemaining: TimeInterval {
        get { rawKeyboardSessionRemaining }
        set {
            rawKeyboardSessionRemaining = newValue
            let formatted = TyprTheme.formatRemaining(newValue)
            if keyboardSessionDisplayRemaining != formatted {
                keyboardSessionDisplayRemaining = formatted
            }
        }
    }
    @ObservationIgnored private var lastPublishedSnapshotSignature: String?
    @ObservationIgnored private var lastPublishedSnapshotAt: TimeInterval = -100
    private(set) var warmDuration: WarmSessionDuration
    private(set) var style: DictationStyle
    private(set) var allowBluetoothMic: Bool
    private(set) var autoReturnState: AutoReturnState = .idle
    private(set) var handoffNotice: String?
    private(set) var engineName = "Local speech"
    private(set) var transcriptionLanguage = "English"
    /// The chosen dictation language (Typr settings); Automatic keeps the previous behavior.
    private(set) var dictationLanguage: DictationLanguage
    /// The engine the user explicitly chose (persisted). nil: never chosen, the original
    /// automatic choice applies. An explicit engine is never replaced by another one.
    private(set) var preferredEngine: SpeechEngineChoice?
    /// The engine of the ready transcriber; nil while none is ready or while switching.
    private(set) var currentEngine: SpeechEngineChoice?
    private(set) var isDeletingModel = false
    @ObservationIgnored private var loadingEngine: SpeechEngineChoice? {
        didSet {
            guard loadingEngine == nil else { return }
            let waiters = loadFinishedWaiters
            loadFinishedWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
    @ObservationIgnored private var loadFinishedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var modelPreparation = ModelPreparationProgress(
        fractionCompleted: 0,
        detail: "Checking model files"
    )

    init(
        audio: (any AudioManaging)? = nil,
        keyboardBridge: KeyboardBridge? = nil,
        transcriber: (any LocalTranscribing)? = nil,
        transcriberFactory: (() async -> any LocalTranscribing)? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        autoPrepareOnInit: Bool = true,
        hostReturner: HostReturner? = nil,
        customVocabularySettings: CustomVocabularySettings = CustomVocabularySettings(),
        cleanup: TranscriptCleanupDependencies? = nil,
        dictationLog: DictationLogStore? = nil,
        statistics: UsageDictationRecorder? = nil,
        languageSettings: TyprSettings = TyprSettings(),
        engineProvider: (any SpeechEngineProviding)? = nil,
        audioActivationRetryDelays: [Duration] = DictationController.audioActivationRetryDelays,
        modelBackground: (any ModelPreparationScheduling)? = nil,
        deferPreparationUntilActive: Bool = false
    ) {
        self.audioRetryDelays = audioActivationRetryDelays
        let resolvedBridge = keyboardBridge ?? KeyboardBridge()
        let resolvedAudio = audio ?? SystemAudioManager()
        let initialTranscriber = transcriber ?? ParakeetTranscriber()
        let resolvedProvider = engineProvider ?? ProductionSpeechEngineProvider()
        let preferred = languageSettings.preferredSpeechEngine

        self.cleanup = cleanup
        self.dictationLog = dictationLog
        self.statistics = statistics
        self.languageSettings = languageSettings
        self.dictationLanguage = languageSettings.dictationLanguage
        self.audio = resolvedAudio
        self.keyboardBridge = resolvedBridge
        self.transcriber = initialTranscriber
        self.transcriberFactory = transcriberFactory
        self.engineProvider = resolvedProvider
        self.modelBackground = modelBackground
        self.deferredLaunchPreparation = autoPrepareOnInit && deferPreparationUntilActive
        self.preferredEngine = preferred
        self.customVocabularySettings = customVocabularySettings
        self.fileManager = fileManager
        self.now = now
        self.warmDuration = resolvedBridge.warmDuration
        self.style = resolvedBridge.style
        self.allowBluetoothMic = resolvedBridge.allowBluetoothMic
        self.hostReturner = hostReturner ?? .live

        let hasCachedModel = ParakeetTranscriber.hasCachedModel
        resolvedBridge.publish(.offline)
        // The keyboard's flag follows the selected engine; no choice keeps the original Parakeet check.
        resolvedBridge.setModelInstalled(preferred.map { resolvedProvider.isInstalled($0) } ?? hasCachedModel)
        if let preferred {
            engineName = preferred.displayName
        }

        wireAudioCallbacks()
        wireSystemIntentBus()

        if Self.applyLaunchFixtureIfPresent(to: self) {
            return
        }

        if autoPrepareOnInit, !deferPreparationUntilActive {
            prepareLaunchModel()
        }
    }

    /// A background-only process launch must not start another engine (or download its assets)
    /// before the scheduler validates the request. Production defers the usual launch behavior
    /// until an active scene; tests can still exercise immediate initialization explicitly.
    private func prepareLaunchModel() {
        guard phase == .modelRequired, canChangeEngine else { return }
        if let preferred = preferredEngine {
            // An explicit engine prepares at launch only without downloading: Apple Speech (iOS
            // manages its assets), Parakeet when cached, downloaded engines when verified on disk.
            switch preferred {
            case .appleSpeech:
                prepareModel()
            case .parakeetV2, .whisperLargeV3Turbo, .parakeetV3, .orukeet, .cohereTranscribe:
                if engineProvider.isInstalled(preferred) {
                    prepareModel()
                }
            }
        } else {
            if ParakeetTranscriber.hasCachedModel {
                engineName = "Parakeet V2"
                prepareModel()
            } else if #available(iOS 26.0, *), AppleSpeechTranscriber.isAvailable {
                let language = dictationLanguage
                let launchGeneration = modelPrepGeneration
                Task { [weak self] in
                    let available = await AppleSpeechTranscriber.preferredLocale(language: language, strict: false) != nil
                    guard let self, self.modelPrepGeneration == launchGeneration,
                          self.preferredEngine == nil, self.phase == .modelRequired,
                          self.canChangeEngine else { return }
                    if available {
                        self.engineName = "Apple Speech"
                        self.prepareModel()
                    } else {
                        self.engineName = "Parakeet V2"
                    }
                }
            }
        }
    }

    var isRecording: Bool {
        phase == .recording
    }

    var primaryTitle: String {
        switch phase {
        case .modelRequired, .failed:
            "Prepare \(engineName)"
        case .preparingModel:
            "Preparing \(engineName)"
        case .ready:
            "Start dictation"
        case .requestingPermission:
            "Checking microphone"
        case .recording:
            "Finish"
        case .transcribing:
            "Transcribing…"
        }
    }

    // MARK: - Settings

    func setWarmDuration(_ duration: WarmSessionDuration) {
        warmDuration = duration
        keyboardBridge.warmDuration = duration

        if keyboardSessionEnabled {
            if let seconds = duration.seconds {
                keyboardSessionExpiresAt = now() + seconds
                keyboardSessionRemaining = seconds
                publishKeyboardSnapshot()
            } else if phase == .ready {
                endWarmSession()
            }
        }
    }

    /// Used by the settings segmented control: picking a duration warms immediately; picking Off ends it.
    func selectWarmDuration(_ duration: WarmSessionDuration) {
        setWarmDuration(duration)
        if duration == .off {
            if keyboardSessionEnabled {
                endWarmSession()
            }
        } else if !keyboardSessionEnabled {
            requestWarmSession(attemptAutoReturn: false)
        }
    }

    func setStyle(_ newStyle: DictationStyle) {
        style = newStyle
        keyboardBridge.style = newStyle
    }

    /// The language picker: stored for the next recording's cleanup. Apple Speech holds one locale,
    /// so an idle, prepared Apple Speech engine is prepared again for the new language; otherwise the
    /// next preparation (relaunch, retry) uses it.
    func setDictationLanguage(_ language: DictationLanguage) {
        guard language != dictationLanguage else { return }
        dictationLanguage = language
        languageSettings.dictationLanguage = language
        // Apple Speech prepares one locale. Do not mutate the current capture; reprepare when
        // idle, including after a cancelled inference has really released its snapshot.
        if preferredEngine == .appleSpeech || transcriber.displayName == "Apple Speech" || engineName == "Apple Speech" {
            pendingAppleLanguageChange = true
            preparePendingAppleLanguageIfIdle()
        }
    }

    private func preparePendingAppleLanguageIfIdle() {
        guard pendingAppleLanguageChange, canChangeEngine, phase != .preparingModel else { return }
        prepareModel()
    }

    // MARK: - Speech Engine

    enum SpeechEngineSelection: Equatable {
        case selected
        case alreadySelected
        /// A dictation is being set up, recorded, transcribed or cleaned up.
        case busy
        /// A downloaded engine is not downloaded and verified; nothing is downloaded by selecting it.
        case notInstalled
    }

    enum ModelDeletion: Equatable {
        case deleted
        /// A dictation or another deletion is running.
        case busy
        /// Apple Speech: iOS manages its assets.
        case notDeletable
        case failed(String)
    }

    /// False from the microphone permission request until transcription and cleanup finish, and
    /// while a model is being deleted.
    var canChangeEngine: Bool {
        switch phase {
        case .requestingPermission, .recording, .transcribing:
            return false
        case .modelRequired, .preparingModel, .ready, .failed:
            return activeCapture == nil && pendingCleanupJob == nil && transcribingLog == nil
                && inFlightTranscriptions.isEmpty && inFlightPermissionRequests == 0 && !isDeletingModel
        }
    }

    /// Deletes the engine's model files. A loaded or preparing model of that engine is released
    /// first (ending a warm session); the chosen engine stays chosen and is never replaced.
    @discardableResult
    func deleteModel(_ engine: SpeechEngineChoice) async -> ModelDeletion {
        guard engine.hasDeletableModel else { return .notDeletable }
        guard canChangeEngine else { return .busy }
        isDeletingModel = true
        let preparingEngine = preferredEngine ?? SpeechEngineChoice(displayName: engineName)
        if currentEngine == engine || (!isModelReady && preparingEngine == engine) {
            if keyboardSessionEnabled { endWarmSession() }
            modelPrepGeneration &+= 1
            preparationTask?.cancel()
            modelBackground?.finish(success: false)
            transcriber = UnpreparedTranscriber(displayName: engineName)
            currentEngine = nil
            isModelReady = false
            phase = .modelRequired
        }
        // A Core ML load cannot be interrupted, also one superseded by another engine's choice.
        while loadingEngine == engine {
            await withCheckedContinuation { loadFinishedWaiters.append($0) }
        }
        let result: ModelDeletion
        do {
            try engineProvider.deleteModel(engine)
            result = .deleted
        } catch {
            result = .failed(error.localizedDescription)
        }
        if !isModelReady {
            keyboardBridge.setModelInstalled(
                preferredEngine.map { engineProvider.isInstalled($0) } ?? ParakeetTranscriber.hasCachedModel)
        }
        publishKeyboardSnapshot()
        scheduleModelMaintenance()
        isDeletingModel = false
        fulfillPendingHandoffOrPrepare()
        return result
    }

    /// OS, device, language and install status for the settings section. Starts no model work.
    func engineAvailability(_ engine: SpeechEngineChoice) async -> SpeechEngineAvailability {
        await engineProvider.availability(of: engine, language: dictationLanguage)
    }

    /// The settings section's choice: persisted, then the previous engine is released and the
    /// chosen one prepared while idle. Never falls back to another engine.
    @discardableResult
    func selectEngine(_ engine: SpeechEngineChoice) -> SpeechEngineSelection {
        guard canChangeEngine else { return .busy }
        guard engine != preferredEngine else { return .alreadySelected }
        if engine.requiresExplicitDownload, !engineProvider.isInstalled(engine) {
            return .notInstalled
        }
        preferredEngine = engine
        languageSettings.preferredSpeechEngine = engine
        engineName = engine.displayName
        // Pinning the automatically ready engine needs no model reload.
        if currentEngine != engine || !isModelReady { prepareModel() }
        return .selected
    }

    func setAllowBluetoothMic(_ allow: Bool) {
        guard allowBluetoothMic != allow else { return }
        allowBluetoothMic = allow
        keyboardBridge.allowBluetoothMic = allow
        if keyboardSessionEnabled, phase == .ready {
            do { try startWarmInput() }
            catch { endWarmSession() }
        }
    }

    // MARK: - Standalone & System Actions

    func performPrimaryAction() {
        switch phase {
        case .modelRequired, .failed:
            prepareModel()
        case .ready:
            startRecording(copyToPasteboard: false)
        case .recording:
            finishRecording()
        case .preparingModel, .requestingPermission, .transcribing:
            break
        }
    }

    func cancelCurrentJob() {
        transcribingLog?.finishIfOpen(.cancelled)
        transcribingLog = nil
        endCleanupJob()
        jobGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        liveActivity.endImmediately()

        if let session = activeCapture {
            activeCapture = nil
            stopMetering()
            session.capture.stop()
            try? fileManager.removeItem(at: session.capture.url)
        }

        if activeKeyboardJobID != nil {
            keyboardMessage = nil
        }
        activeKeyboardJobID = nil
        audioLevel = 0
        loudnessDB = -120
        recordingDuration = 0
        if phase == .recording || phase == .transcribing || phase == .requestingPermission {
            phase = .ready
        }
        restoreAudioAfterCapture()
        publishKeyboardSnapshot()
        preparePendingAppleLanguageIfIdle()
    }

    func clearTranscript() {
        transcript = ""
        copied = false
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        UIPasteboard.general.string = transcript
        copied = true
    }

    func toggleWarmSession() {
        if keyboardSessionEnabled {
            endWarmSession()
        } else {
            if warmDuration == .off {
                setWarmDuration(.fifteenMinutes)
            }
            requestWarmSession(attemptAutoReturn: false)
        }
    }

    func endWarmSession(message: String? = nil) {
        keyboardSessionTask?.cancel()
        keyboardSessionTask = nil
        pendingHandoff = nil
        suspendedWarmSessionOnInterruption = false
        releaseAudioAfterCapture = false

        // Cancel an unaccepted in-progress recording, but preserve any already-accepted transcription!
        if let session = activeCapture {
            endCleanupJob()
            jobGeneration &+= 1
            activeCapture = nil
            stopMetering()
            session.capture.stop()
            try? fileManager.removeItem(at: session.capture.url)
            activeKeyboardJobID = nil
            audioLevel = 0
            loudnessDB = -120
            recordingDuration = 0
            liveActivity.endImmediately()
            if phase == .recording {
                phase = .ready
            }
        }

        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        keyboardSessionEnabled = false
        keyboardSessionRemaining = 0
        keyboardSessionExpiresAt = 0
        keyboardMessage = message

        if phase != .recording {
            audio.deactivateSession()
        }

        publishKeyboardSnapshot()
        preparePendingAppleLanguageIfIdle()
    }

    /// Reopening prepares only an installed, explicitly selected downloaded engine, never a
    /// download or a replacement engine. Also used by maintenance: both paths join the same preparation.
    var needsDownloadedModelPreparation: Bool {
        preferredDownloadedEngineIsInstalled && !isModelReady && canChangeEngine
    }

    private var preferredDownloadedEngineIsInstalled: Bool {
        guard let preferredEngine, preferredEngine.requiresExplicitDownload else { return false }
        return engineProvider.isInstalled(preferredEngine)
    }

    func prepareInstalledModelIfNeeded() {
        guard needsDownloadedModelPreparation, phase != .preparingModel else { return }
        prepareModel()
    }

    func noteSceneDidBecomeActive() {
        if deferredLaunchPreparation {
            deferredLaunchPreparation = false
            prepareLaunchModel()
        }
        prepareInstalledModelIfNeeded()
        // A preparation that lost or never got its continued task asks again while active.
        modelBackground?.sceneDidBecomeActive()
        scheduleModelMaintenance()
    }

    private func scheduleModelMaintenance() {
        modelBackground?.scheduleMaintenance(needed: preferredDownloadedEngineIsInstalled)
    }

    private func expireModelPreparation(_ engine: SpeechEngineChoice, generation: UInt64) {
        guard modelPrepGeneration == generation, phase == .preparingModel else { return }
        // Invalidate immediately, but retain the task so a retry waits for any non-interruptible
        // Core ML call to return and release its candidate before allocating another one.
        modelPrepGeneration &+= 1
        preparationTask?.cancel()
        pendingHandoff = nil
        phase = .failed("\(engine.shortName) preparation paused. Open Typr or tap Try again to continue. iOS controls background time.")
        modelPreparation = ModelPreparationProgress(fractionCompleted: nil, detail: "\(engine.shortName) preparation paused")
        publishKeyboardSnapshot()
        scheduleModelMaintenance()
    }

    func noteSceneDidEnterBackground() {
        scheduleModelMaintenance()
        autoReturnFallbackTask?.cancel()
        autoReturnFallbackTask = nil
        if case .attempting = autoReturnState {
            autoReturnState = .succeeded
        }
    }

    // MARK: - Keyboard Launch & Auto-Return

    func handleKeyboardLaunch(_ request: KeyboardLaunchRequest) {
        if case .setup = request {
            return
        }
        autoReturnFallbackTask?.cancel()
        autoReturnState = .idle
        handoffNotice = nil
        returnHost = request.host

        let currentTime = now()
        if request.isHandoffExpired(at: currentTime) {
            handoffNotice = "Timed out"
            pendingHandoff = PendingKeyboardHandoff(
                jobID: nil,
                style: style,
                requestedAt: currentTime,
                attemptAutoReturn: false
            )
            fulfillPendingHandoffOrPrepare()
            return
        }

        switch request {
        case .setup:
            break

        case .startSession:
            pendingHandoff = PendingKeyboardHandoff(
                jobID: nil,
                style: style,
                requestedAt: currentTime,
                attemptAutoReturn: true
            )
            fulfillPendingHandoffOrPrepare()

        case .startRecording(let jobID, _, let requestedStyle, _):
            guard !jobID.isEmpty, jobID != lastHandledLaunchJobID else { return }
            lastHandledLaunchJobID = jobID
            if let requestedStyle {
                setStyle(requestedStyle)
            }
            pendingHandoff = PendingKeyboardHandoff(
                jobID: jobID,
                style: requestedStyle ?? style,
                requestedAt: currentTime,
                attemptAutoReturn: true
            )
            fulfillPendingHandoffOrPrepare()
        }
    }

    private func fulfillPendingHandoffOrPrepare() {
        guard let handoff = pendingHandoff else { return }

        if now() - handoff.requestedAt > KeyboardLaunchRequest.handoffWindow {
            handoffNotice = "Timed out"
            pendingHandoff = PendingKeyboardHandoff(
                jobID: nil,
                style: handoff.style,
                requestedAt: now(),
                attemptAutoReturn: false
            )
        }

        switch phase {
        case .failed where canReusePreparedModel:
            // A microphone or capture failure leaves the prepared model usable. Reloading it
            // here only made the next dictation wait for preparation again.
            phase = .ready
            activateWarmSessionAndRunHandoff()
        case .modelRequired, .failed:
            prepareModel()
        case .ready:
            activateWarmSessionAndRunHandoff()
        case .preparingModel, .requestingPermission, .recording, .transcribing:
            break
        }
    }

    private func requestWarmSession(attemptAutoReturn: Bool) {
        pendingHandoff = PendingKeyboardHandoff(
            jobID: nil,
            style: style,
            requestedAt: now(),
            attemptAutoReturn: attemptAutoReturn
        )
        fulfillPendingHandoffOrPrepare()
    }

    private func activateWarmSessionAndRunHandoff() {
        guard phase == .ready else { return }
        let handoff = pendingHandoff
        pendingHandoff = nil

        // If a one-shot recording was requested (`warmDuration == .off` and a jobID is present),
        // go straight into recording and release the mic as soon as capture finishes.
        if warmDuration == .off, let jobID = handoff?.jobID {
            let expired = handoff.map { now() - $0.requestedAt > KeyboardLaunchRequest.handoffWindow } ?? false
            if !expired {
                startRecording(
                    keyboardJobID: jobID,
                    styleOverride: handoff?.style,
                    copyToPasteboard: false,
                    attemptAutoReturnOnStart: handoff?.attemptAutoReturn ?? false
                )
                startKeyboardSessionLoop()
            } else {
                handoffNotice = "Timed out"
                autoReturnState = .swipeFallback
            }
            return
        }

        // A warm-only request must not interrupt media. A fresh dictation below is
        // allowed to interrupt it, but must release the session when capture ends.
        let hasFreshCapture = handoff?.jobID != nil
            && handoff.map { now() - $0.requestedAt <= KeyboardLaunchRequest.handoffWindow } == true
        if audio.isOtherAudioPlaying, !hasFreshCapture {
            endWarmSession()
            handoffNotice = "Media is playing. Start dictation to use the microphone."
            maybeAutoReturnAfterActivation(allowed: handoff?.attemptAutoReturn ?? false)
            return
        }

        if keyboardSessionEnabled, audio.isKeepaliveRunning {
            refreshWarmExpiry()
            if let jobID = handoff?.jobID {
                let expired = handoff.map { now() - $0.requestedAt > KeyboardLaunchRequest.handoffWindow } ?? false
                if !expired {
                    startRecording(
                        keyboardJobID: jobID,
                        styleOverride: handoff?.style,
                        copyToPasteboard: false,
                        attemptAutoReturnOnStart: handoff?.attemptAutoReturn ?? false
                    )
                    return
                } else {
                    handoffNotice = "Timed out"
                }
            }
            maybeAutoReturnAfterActivation(allowed: handoff?.attemptAutoReturn ?? false)
            return
        }

        jobGeneration &+= 1
        let requestGen = jobGeneration
        phase = .requestingPermission
        keyboardMessage = nil
        // This activation replaces a pending resume after an interruption.
        takeOverInterruptionResume()

        Task {
            let granted = await audio.requestPermission()
            guard self.jobGeneration == requestGen else { return }
            guard granted else {
                phase = .failed("Microphone access is off. Allow it in Settings to dictate.")
                publishKeyboardSnapshot()
                return
            }

            // If we also have a fresh recording job, begin capture directly so we don't bounce keepalive -> recorder!
            if let jobID = handoff?.jobID,
               let requestedAt = handoff?.requestedAt,
               self.now() - requestedAt <= KeyboardLaunchRequest.handoffWindow {
                self.enableWarmSessionBookkeeping()
                self.phase = .ready
                self.startKeyboardSessionLoop()
                self.startRecording(
                    keyboardJobID: jobID,
                    styleOverride: handoff?.style,
                    copyToPasteboard: false,
                    attemptAutoReturnOnStart: handoff?.attemptAutoReturn ?? false
                )
                return
            }

            if let jobID = handoff?.jobID, !jobID.isEmpty {
                self.handoffNotice = "Timed out"
            }

            do {
                try await activateAudio(isCurrent: { self.jobGeneration == requestGen }) {
                    try self.startWarmInput()
                }
                noteAudioActivated()
                enableWarmSessionBookkeeping()
                phase = .ready
                startKeyboardSessionLoop()
                publishKeyboardSnapshot()
                maybeAutoReturnAfterActivation(allowed: handoff?.attemptAutoReturn ?? false)
            } catch {
                guard self.jobGeneration == requestGen else { return }
                audio.deactivateSession()
                phase = audio.isOtherAudioPlaying ? .ready : .failed(Self.audioFailureMessage(for: error))
                publishKeyboardSnapshot()
            }
        }
    }

    /// Recheck on every warm start, including route changes and interruption retries.
    /// Never seize the microphone just to keep it warm while media is playing.
    private func startWarmInput() throws {
        guard !audio.isOtherAudioPlaying else { throw CancellationError() }
        try audio.startKeepalive(allowBluetooth: allowBluetoothMic)
    }

    private func enableWarmSessionBookkeeping() {
        let seconds = warmDuration.seconds ?? (15 * 60)
        keyboardSessionEnabled = true
        keyboardSessionExpiresAt = now() + seconds
        keyboardSessionRemaining = seconds
    }

    private func refreshWarmExpiry() {
        guard keyboardSessionEnabled, let seconds = warmDuration.seconds else { return }
        keyboardSessionExpiresAt = now() + seconds
        keyboardSessionRemaining = seconds
    }

    /// Back to the app the dictation came from, else the swipe-back cue.
    /// A field inside Typr itself needs no return.
    private func maybeAutoReturnAfterActivation(allowed: Bool) {
        guard allowed else { return }
        guard let host = returnHost else {
            autoReturnState = .swipeFallback
            return
        }
        guard host != HostReturnCatalog.typrBundleID else { return }
        triggerAutoReturn(to: host)
    }

    private func triggerAutoReturn(to host: String) {
        autoReturnFallbackTask?.cancel()
        autoReturnState = .attempting
        let returner = hostReturner

        Task {
            let opened = await returner.open(host)
            guard case .attempting = self.autoReturnState else { return }
            if !opened {
                self.autoReturnState = .swipeFallback
                return
            }
            self.autoReturnFallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(950))
                guard !Task.isCancelled, let self else { return }
                if case .attempting = self.autoReturnState {
                    self.autoReturnState = .swipeFallback
                }
            }
        }
    }

    // MARK: - Model Preparation

    func prepareModel() {
        // This is also called by handoff/intents and tests, not just the settings button.
        guard canChangeEngine else { return }
        pendingAppleLanguageChange = false
        modelNeedsReload = false
        modelPrepGeneration &+= 1
        let prepGen = modelPrepGeneration
        modelBackground?.finish(success: false)
        phase = .preparingModel
        copied = false
        let downloaded = preferredEngine.flatMap { $0.requiresExplicitDownload ? $0 : nil }
        modelPreparation = ModelPreparationProgress(
            fractionCompleted: downloaded == nil ? 0 : nil,
            detail: "Checking model files"
        )
        let preferred = preferredEngine
        let language = dictationLanguage
        let previous = preparationTask
        previous?.cancel()
        // Release the previous engine before the next one loads, so two large models are never
        // held together. A running transcription keeps its own snapshot until it ends.
        transcriber = UnpreparedTranscriber(displayName: engineName)
        currentEngine = nil
        isModelReady = false
        keyboardBridge.setModelInstalled(preferred.map { engineProvider.isInstalled($0) } ?? ParakeetTranscriber.hasCachedModel)
        publishKeyboardSnapshot()
        if let downloaded {
            modelBackground?.begin(downloaded) { [weak self] in
                self?.expireModelPreparation(downloaded, generation: prepGen)
            }
        }
        scheduleModelMaintenance()

        preparationTask = Task {
            defer {
                if self.modelPrepGeneration == prepGen, downloaded != nil {
                    self.modelBackground?.finish(success: self.isModelReady)
                }
            }
            // A superseded preparation finishes (and is dropped) before this one creates a model.
            await previous?.value
            guard self.modelPrepGeneration == prepGen else { return }
            do {
                let candidate: any LocalTranscribing
                if let preferred {
                    candidate = try await engineProvider.transcriber(for: preferred, language: language)
                } else if let transcriberFactory {
                    candidate = await transcriberFactory()
                } else {
                    candidate = await engineProvider.automaticTranscriber(language: language)
                }
                guard self.modelPrepGeneration == prepGen else { return }
                engineName = candidate.displayName
                loadingEngine = SpeechEngineChoice(displayName: candidate.displayName)
                defer { loadingEngine = nil }
                try await candidate.prepare { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.modelPrepGeneration == prepGen else { return }
                        guard self.phase == .preparingModel else { return }
                        self.modelPreparation = progress
                        if downloaded != nil { self.modelBackground?.update(progress) }
                    }
                }
                let candidateLanguageName = await candidate.languageName
                guard self.modelPrepGeneration == prepGen else { return }
                // A language change while preparation awaited must not publish the old Apple
                // locale as ready. The replacement waits for this task to release its candidate.
                if candidate.displayName == "Apple Speech", self.dictationLanguage != language {
                    self.pendingAppleLanguageChange = true
                    self.phase = .ready
                    self.preparePendingAppleLanguageIfIdle()
                    return
                }
                self.transcriber = candidate
                self.currentEngine = SpeechEngineChoice(displayName: candidate.displayName)
                self.transcriptionLanguage = candidateLanguageName
                self.keyboardBridge.setModelInstalled(true)
                self.isModelReady = true
                self.phase = .ready
                self.publishKeyboardSnapshot()
                if self.pendingHandoff != nil {
                    self.activateWarmSessionAndRunHandoff()
                }
            } catch {
                guard self.modelPrepGeneration == prepGen else { return }
                self.keyboardBridge.setModelInstalled(
                    preferred.map { self.engineProvider.isInstalled($0) } ?? ParakeetTranscriber.hasCachedModel)
                self.pendingHandoff = nil
                self.phase = .failed(error.localizedDescription)
                self.publishKeyboardSnapshot()
                self.preparePendingAppleLanguageIfIdle()
            }
        }
    }

    // MARK: - Capture & Generation-Scoped Transcription

    func startRecording(
        keyboardJobID: String? = nil,
        styleOverride: DictationStyle? = nil,
        copyToPasteboard: Bool = false,
        attemptAutoReturnOnStart: Bool = false,
        keyboardContext: CleanupContext? = nil
    ) {
        guard activeCapture == nil else { return }
        // Never begin a new Apple capture with the previous locale. The current capture is
        // unaffected, but the next waits for the deferred local preparation.
        if pendingAppleLanguageChange {
            preparePendingAppleLanguageIfIdle()
            return
        }
        guard isModelReady, phase != .preparingModel, phase != .requestingPermission else { return }
        if let keyboardJobID, keyboardJobID == activeKeyboardJobID {
            return
        }
        activeKeyboardJobID = keyboardJobID
        if keyboardJobID != nil {
            keyboardMessage = nil
        }

        // Bumping generation invalidates any stale winding-down transcription task so it can never
        // overwrite our new capture's phase, job state, or temporary WAV file.
        jobGeneration &+= 1
        let captureGeneration = jobGeneration
        transcribingLog?.finishIfOpen(.cancelled)
        transcribingLog = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        endCleanupJob()
        let captureTranscriber = transcriber
        let captureLanguage = dictationLanguage
        let captureLanguageName = switch SpeechEngineChoice(displayName: captureTranscriber.displayName) {
        case .whisperLargeV3Turbo: WhisperTranscriber.languageName(for: captureLanguage)
        case .parakeetV3: ParakeetV3Transcriber.languageName(for: captureLanguage)
        case .orukeet: OrukeetTranscriber.languageName(for: captureLanguage)
        case .cohereTranscribe: CohereTranscriber.languageName(for: captureLanguage)
        default: transcriptionLanguage
        }
        let effectiveStyle = styleOverride ?? style
        let vocabularyEnabled = customVocabularySettings.isEnabled
        let savedVocabularyTerms = customVocabularySettings.terms
        let vocabularyTerms = vocabularyEnabled ? savedVocabularyTerms : []
        let vocabulary = DictationVocabulary(settings: customVocabularySettings)
        let enabled = cleanup?.isEnabled() == true
        let logToken = dictationLog?.token()
        let logCleanupPath: DictationLogCleanupPath = effectiveStyle == .verbatim ? .none
            : (enabled ? .typr : .none)
        let cleanupEnabled = enabled && effectiveStyle != .verbatim
        let disabledCleanupReason: CleanupSkipReason? = !enabled ? .off : (effectiveStyle == .verbatim ? .verbatim : nil)
        // The keyboard's caret text and host app; a cold start knows only the app it came from.
        var cleanupContext = keyboardContext ?? CleanupContext(application: attemptAutoReturnOnStart ? returnHost : nil)
        cleanupContext.language = captureLanguage

        phase = .requestingPermission
        copied = false
        // The capture starts the input itself. A resume still retrying after an interruption
        // must not restart (stop) the input under it later.
        takeOverInterruptionResume()

        inFlightPermissionRequests += 1
        Task {
            defer {
                self.inFlightPermissionRequests -= 1
                self.preparePendingAppleLanguageIfIdle()
            }
            let granted = await audio.requestPermission()
            guard self.jobGeneration == captureGeneration else { return }
            guard granted else {
                activeKeyboardJobID = nil
                let message = "Microphone access is off. Allow it in Settings."
                keyboardMessage = keyboardJobID == nil ? nil : message
                phase = .failed(message)
                publishKeyboardSnapshot()
                return
            }

            let captureURL = fileManager.temporaryDirectory
                .appendingPathComponent("typr-\(captureGeneration)-\(UUID().uuidString)")
                .appendingPathExtension("wav")

            do {
                let capture = try await activateAudio(isCurrent: { self.jobGeneration == captureGeneration }) {
                    // Read before activating: activation itself pauses other audio. OR
                    // across retries so a partial activation cannot erase that decision.
                    self.releaseAudioAfterCapture = self.releaseAudioAfterCapture || self.audio.isOtherAudioPlaying
                    return try self.audio.beginCapture(
                        at: captureURL,
                        maxDuration: Self.maxCaptureDuration,
                        allowBluetooth: self.allowBluetoothMic
                    )
                }
                guard self.jobGeneration == captureGeneration else {
                    capture.stop()
                    try? fileManager.removeItem(at: captureURL)
                    return
                }
                noteAudioActivated()

                let startedAt = now()
                var cleanupJob: CleanupJob?
                var cleanupSkipReason = disabledCleanupReason
                if cleanupEnabled, let cleanup {
                    if cleanup.cleaner.unavailableReason != nil {
                        cleanupSkipReason = .unavailable
                    } else if cleanupCoordinator.reservedBy != nil {
                        cleanupSkipReason = .busy
                    } else {
                        let job = CleanupJob(session: cleanup.cleaner.makeSession(), background: cleanup.background)
                        cleanupJob = job
                        pendingCleanupJob = job
                        cleanupCoordinator.prewarm(job)
                    }
                }
                activeCapture = ActiveCaptureSession(
                    statisticsToken: statistics?.beginCapture(),
                    generation: captureGeneration,
                    capture: capture,
                    startedAt: startedAt,
                    keyboardJobID: keyboardJobID,
                    style: effectiveStyle,
                    vocabularyTerms: vocabularyTerms,
                    vocabulary: vocabulary,
                    vocabularyEnabled: vocabularyEnabled,
                    typrCleanupEnabled: enabled,
                    copyToPasteboard: copyToPasteboard,
                    cleanupJob: cleanupJob,
                    cleanupSkipReason: cleanupSkipReason,
                    logToken: logToken,
                    logCleanupPath: logCleanupPath,
                    cleanupContext: cleanupContext,
                    transcriber: captureTranscriber,
                    language: captureLanguage,
                    speechLanguageName: captureLanguageName
                )
                refreshWarmExpiry()
                audioLevel = 0
                loudnessDB = -120
                loudestAverageDBFS = nil
                recordingDuration = 0
                phase = .recording
                liveActivity.startRecording(startedAt: Date(timeIntervalSince1970: startedAt))
                startMetering(for: captureGeneration)
                publishKeyboardSnapshot()

                if attemptAutoReturnOnStart {
                    maybeAutoReturnAfterActivation(allowed: true)
                }
            } catch {
                try? fileManager.removeItem(at: captureURL)
                guard self.jobGeneration == captureGeneration else { return }
                let message = Self.audioFailureMessage(for: error)
                activeKeyboardJobID = nil
                keyboardMessage = keyboardJobID == nil ? nil : message
                phase = .failed(message)
                restoreAudioAfterCapture()
                publishKeyboardSnapshot()
            }
        }
    }

    func finishRecording() {
        guard let session = activeCapture else { return }
        let stoppedAt = ContinuousClock.now
        activeCapture = nil

        stopMetering()
        let finalDuration = max(recordingDuration, session.capture.currentTime)
        session.capture.stop()
        audioLevel = 0
        loudnessDB = -120

        let captureURL = session.capture.url
        let captureGeneration = session.generation
        let keyboardJobID = session.keyboardJobID

        guard finalDuration >= Self.minCaptureDuration else {
            endCleanupJob()
            try? fileManager.removeItem(at: captureURL)
            recordingDuration = 0
            activeKeyboardJobID = nil
            keyboardMessage = nil
            phase = .ready
            liveActivity.endImmediately()
            restoreAudioAfterCapture()
            publishKeyboardSnapshot()
            return
        }

        let recording = session.logToken.flatMap { token in
            dictationLog?.begin(token: token, context: .capture(
                keyboardJob: keyboardJobID != nil, copyToPasteboard: session.copyToPasteboard,
                style: session.style, engine: session.transcriber.displayName, language: session.speechLanguageName,
                duration: finalDuration, loudestAverage: loudestAverageDBFS,
                cleanupPath: session.logCleanupPath, vocabularyCount: session.vocabularyTerms.count,
                vocabularyEnabled: session.vocabularyEnabled,
                upstreamCleanupEnabled: false,
                typrCleanupEnabled: session.typrCleanupEnabled,
                cleanupContext: session.cleanupContext),
                stoppedAt: stoppedAt)
        }
        transcribingLog = recording
        phase = .transcribing
        session.cleanupJob?.begin()
        transcriptionHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.jobGeneration == captureGeneration, self.phase == .transcribing else { return }
                self.publishKeyboardSnapshot()
            }
        }
        liveActivity.markTranscribing(startedAt: Date(timeIntervalSince1970: session.startedAt))
        restoreAudioAfterCapture()
        publishKeyboardSnapshot()

        let activeTranscriber = session.transcriber

        transcriptionTask?.cancel()
        let inferenceID = UUID()
        inFlightTranscriptions.insert(inferenceID)
        let task = Task { [weak self] in
            let asrStarted = ContinuousClock.now
            defer {
                recording?.finishIfOpen(.cancelled) // Also outside the generation fence: stale tasks terminate their own entry.
                try? FileManager.default.removeItem(at: captureURL)
                session.cleanupJob?.finish()
                if let self, self.jobGeneration == captureGeneration {
                    self.transcribingLog = nil
                    self.endCleanupJob()
                }
            }

            do {
                let rawText = try await activeTranscriber.transcribe(
                    captureURL,
                    vocabulary: session.vocabulary.speechHints,
                    language: session.language
                )
                guard let self, self.jobGeneration == captureGeneration, !Task.isCancelled else {
                    return
                }
                // Spelling (Custom vocabulary, then the built-in tech glossary) runs before
                // optional cleanup so cleanup sees the intended words, then the user's terms
                // again after formatting because a style can lowercase a term or capitalize a
                // sentence start ("iPhone" -> "IPhone").
                let asrMilliseconds = dictationLogMilliseconds(from: asrStarted)
                var firstPass = DictationLogSpellingPass()
                let observeFirst: ((String, String, String, DictationVocabulary.Source) -> Void)? = recording == nil ? nil : {
                    before, after, term, source in
                    firstPass.record(before: before, after: after, term: term,
                                     source: source == .builtIn ? source.rawValue : nil)
                }
                // Hyphens between words become spaces first (owner style, every style and path), so
                // spelling and cleanup see "Pull Request" and a hyphenated user term is restored.
                let prepared = session.vocabulary.beforeCleanup(CleanupHyphens.spaceCompounds(rawText),
                                                                onReplacement: observeFirst)
                let spelled = prepared.text
                recording?.recognized(rawText, spelled: spelled, asrMilliseconds: asrMilliseconds, spellingPass: firstPass)
                var text = spelled
                if let cleanup = self.cleanup, session.cleanupSkipReason != .off {
                    // Typr AI cleanup is on.
                    if session.cleanupSkipReason == .verbatim {
                        // Verbatim remains synchronous: no prepare, model call, lease or await.
                        self.cleanupCoordinator.recordSkip(.verbatim, dependencies: cleanup, diagnostics: recording)
                    } else {
                        text = await self.cleanupCoordinator.clean(spelled, job: session.cleanupJob,
                            dependencies: cleanup, skipReason: session.cleanupSkipReason,
                            vocabulary: prepared.cleanupTerms, context: session.cleanupContext, diagnostics: recording)
                        guard self.jobGeneration == captureGeneration, !Task.isCancelled else { return }
                    }
                } else {
                    if let cleanup = self.cleanup {
                        // Off remains synchronous: no prepare, model call, lease or await.
                        self.cleanupCoordinator.recordSkip(.off, dependencies: cleanup, diagnostics: recording)
                    }
                    text = spelled
                }
                let beforeSpelling = TranscriptFormatter.format(text, style: session.style)
                recording?.processingStages(cleanupOutput: text, formattedText: beforeSpelling)
                var secondPass = DictationLogSpellingPass()
                let observeSecond: ((String, String, String) -> Void)? = recording == nil ? nil : { before, after, term in
                    secondPass.record(before: before, after: after, term: term)
                }
                let formatted = session.vocabulary.afterFormatting(beforeSpelling, onReplacement: observeSecond)
                if keyboardJobID != nil, recording != nil {
                    // An offer omitted while the archive loads cannot be added after insertion:
                    // the keyboard deliberately consumes each result exactly once.
                    await self.dictationLog?.waitForFeedbackReadiness()
                    guard self.jobGeneration == captureGeneration, !Task.isCancelled else { return }
                }
                self.statistics?.success(session.statisticsToken, recognized: rawText,
                                         delivered: formatted, seconds: finalDuration)
                recording?.finish(text: formatted, beforeSpelling: beforeSpelling, spellingPass: secondPass)
                self.recordingDuration = 0
                self.transcript = formatted
                // Exact recording correlation, never whichever archive row happens to be latest.
                self.lastLoggedTranscriptID = recording.flatMap { recording in
                    guard let entry = self.dictationLog?.entry(recording.entryID),
                          entry.status == .finished, entry.finalText?.text == DictationLogText(formatted).text else { return nil }
                    return recording.entryID
                }
                if session.copyToPasteboard && !formatted.isEmpty {
                    UIPasteboard.general.string = formatted
                    self.copied = true
                    self.liveActivity.finishCopied()
                } else {
                    self.liveActivity.endImmediately()
                }

                if keyboardJobID != nil {
                    self.keyboardResultID = UUID().uuidString
                    self.keyboardResult = formatted
                    self.keyboardResultExpiresAt = self.now() + Self.resultDeliveryTTL
                    if let recording, let resultID = self.keyboardResultID, let keyboardJobID {
                        self.keyboardFeedbackOffer = self.dictationLog?.makeKeyboardFeedbackOffer(
                            recording: recording, jobID: keyboardJobID, resultID: resultID,
                            expiresAt: Date(timeIntervalSince1970: self.now() + 600))
                    }
                    self.keyboardMessage = nil
                }
                self.activeKeyboardJobID = nil
                self.refreshWarmExpiry()
                self.phase = .ready
                self.publishKeyboardSnapshot()
            } catch {
                guard !Task.isCancelled, let self, self.jobGeneration == captureGeneration else {
                    return
                }
                recording?.failASR(error, milliseconds: dictationLogMilliseconds(from: asrStarted))
                if !Self.transcriptionFailureKeepsModel(error) {
                    self.modelNeedsReload = true
                }
                self.recordingDuration = 0
                self.activeKeyboardJobID = nil
                self.liveActivity.endImmediately()
                self.keyboardMessage = keyboardJobID == nil ? nil : error.localizedDescription
                self.phase = .failed(error.localizedDescription)
                self.publishKeyboardSnapshot()
            }
        }
        transcriptionTask = task
        Task { [weak self] in
            // Waiting outside the inference body matters: its locals (and model snapshot) must
            // be gone before a different engine may allocate a large model.
            await task.value
            guard let self else { return }
            self.inFlightTranscriptions.remove(inferenceID)
            self.preparePendingAppleLanguageIfIdle()
        }
    }

    private func restoreAudioAfterCapture() {
        if releaseAudioAfterCapture || audio.isOtherAudioPlaying {
            // The writer is already stopped. Release before ASR, including short,
            // cancelled and failed captures; do not let the warm loop restart input.
            endWarmSession()
            return
        }
        if keyboardSessionEnabled, let seconds = warmDuration.seconds, seconds > 0 {
            let remaining = keyboardSessionExpiresAt - now()
            if remaining <= 0 {
                keyboardSessionEnabled = false
                keyboardSessionRemaining = 0
                keyboardSessionExpiresAt = 0
                audio.deactivateSession()
                return
            }
            // An interruption stopped the input; `.interruptionEnded` resumes the session.
            guard !suspendedWarmSessionOnInterruption else { return }
            do {
                // The capture recorded from the keepalive input, so it is normally still
                // running. Restarting it here would fail in the background and end the session.
                try audio.ensureKeepalive(allowBluetooth: allowBluetoothMic)
            } catch {
                keyboardSessionEnabled = false
                keyboardSessionRemaining = 0
                keyboardSessionExpiresAt = 0
                keyboardMessage = Self.audioFailureMessage(for: error)
                audio.deactivateSession()
            }
        } else {
            keyboardSessionEnabled = false
            keyboardSessionRemaining = 0
            keyboardSessionExpiresAt = 0
            audio.deactivateSession()
        }
    }

    private func startMetering(for generation: UInt64) {
        stopMetering()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      let session = self.activeCapture,
                      session.generation == generation else {
                    break
                }

                // Recorder readiness is a sample, not the capture's lifetime. A transient
                // false must not strand the app meter and keyboard heartbeat until Stop.
                // Completion/interruption callbacks and explicit Stop own capture teardown.
                guard session.capture.isRecording else {
                    try? await Task.sleep(for: .milliseconds(33))
                    continue
                }

                let db = session.capture.averagePowerDB()
                self.loudnessDB = db
                if db.isFinite { self.loudestAverageDBFS = max(self.loudestAverageDBFS ?? db, db) }
                self.audioLevel = max(0, min(1, (db + 48) / 48))
                self.recordingDuration = session.capture.currentTime
                self.publishKeyboardSnapshot(minInterval: 0.10)

                if self.recordingDuration >= Self.maxCaptureDuration - 0.25 {
                    self.finishRecording()
                    return
                }

                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    // MARK: - Warm Session Loop & Snapshot Truth

    private func startKeyboardSessionLoop() {
        keyboardSessionTask?.cancel()
        keyboardSessionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.keyboardSessionEnabled || self.activeKeyboardJobID != nil else { return }

                // Never expire an in-flight recording or accepted transcription mid-work.
                if self.keyboardSessionEnabled, self.phase != .recording && self.phase != .transcribing {
                    let remaining = self.keyboardSessionExpiresAt - self.now()
                    if remaining <= 0 {
                        self.endWarmSession()
                        return
                    }
                    self.keyboardSessionRemaining = remaining

                    if self.phase == .ready && self.audio.isOtherAudioPlaying {
                        self.endWarmSession()
                        return
                    }

                    // Verify the keepalive engine is genuinely alive so we never publish a stuck "Ready".
                    if self.phase == .ready && !self.audio.isKeepaliveRunning && !self.suspendedWarmSessionOnInterruption {
                        do {
                            try self.startWarmInput()
                        } catch {
                            self.endWarmSession()
                            return
                        }
                    }
                }

                self.consumeKeyboardCommand()
                if self.phase != .recording {
                    self.publishKeyboardSnapshot(minInterval: 0.60)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func processPendingKeyboardCommandForTesting() {
        consumeKeyboardCommand()
        publishKeyboardSnapshot()
    }

    func updateRecordingDurationForTesting(_ duration: TimeInterval) {
        recordingDuration = duration
    }

    private func consumeKeyboardCommand() {
        dictationLog?.drainKeyboardFeedback()
        guard let command = keyboardBridge.latestCommand(),
              command.id != lastKeyboardCommandID else { return }
        lastKeyboardCommandID = command.id

        // Ignore stale commands left in UserDefaults from >10s ago.
        guard now() - command.sentAt <= KeyboardLaunchRequest.handoffWindow else { return }

        switch command.kind {
        case .start:
            // After a failure the warm input and prepared model can still serve this dictation.
            let canStart = phase == .ready
                || (phase.isFailure && canReusePreparedModel && audio.isKeepaliveRunning)
            guard canStart, activeKeyboardJobID == nil else { return }
            setStyle(command.style)
            startRecording(
                keyboardJobID: command.jobID,
                styleOverride: command.style,
                copyToPasteboard: false,
                keyboardContext: CleanupContext(application: command.host, before: command.context ?? "",
                                                selected: command.selected ?? "", after: command.after ?? "")
            )
        case .stop:
            guard phase == .recording, activeKeyboardJobID == command.jobID else { return }
            finishRecording()
        case .cancel:
            guard (phase == .recording || phase == .transcribing),
                  activeKeyboardJobID == command.jobID else { return }
            cancelCurrentJob()
        }
    }

    private func publishKeyboardSnapshot(minInterval: TimeInterval = 0) {
        let currentTime = now()

        if let expires = keyboardResultExpiresAt, expires <= currentTime {
            keyboardResultID = nil
            keyboardFeedbackOffer = nil
            keyboardResult = nil
            keyboardResultExpiresAt = nil
        }

        let state: KeyboardDictationState
        switch phase {
        case .recording:
            // Hardware truth guard: only claim `.recording` while an active capture is genuinely recording.
            if let session = activeCapture, session.capture.isRecording {
                state = .recording
            } else {
                state = keyboardSessionEnabled ? .ready : .offline
            }
        case .transcribing:
            state = .transcribing
        case .failed:
            state = .failed
        case .modelRequired, .preparingModel, .requestingPermission:
            state = .offline
        case .ready:
            state = (keyboardSessionEnabled && audio.isKeepaliveRunning) ? .ready : .offline
        }

        let failureMessage: String?
        if case .failed(let message) = phase {
            failureMessage = message
        } else {
            failureMessage = keyboardMessage
        }

        let signature = "\(state.rawValue)|\(activeKeyboardJobID ?? "")|\(keyboardResultID ?? "")|\(failureMessage ?? "")"
        if minInterval > 0,
           signature == lastPublishedSnapshotSignature,
           currentTime - lastPublishedSnapshotAt < minInterval {
            return
        }
        lastPublishedSnapshotSignature = signature
        lastPublishedSnapshotAt = currentTime

        let effectiveHeartbeat: TimeInterval
        if state == .recording || state == .transcribing || (keyboardSessionEnabled && audio.isKeepaliveRunning) {
            effectiveHeartbeat = currentTime
        } else {
            effectiveHeartbeat = 0
        }

        keyboardBridge.publish(
            KeyboardSnapshot(
                state: state,
                heartbeat: effectiveHeartbeat,
                expiresAt: keyboardSessionEnabled ? keyboardSessionExpiresAt : 0,
                recordingStartedAt: activeCapture?.startedAt,
                audioLevel: state == .recording ? audioLevel : 0,
                loudnessDB: state == .recording ? loudnessDB : nil,
                jobID: activeKeyboardJobID,
                resultID: keyboardResultID,
                resultExpiresAt: keyboardResultExpiresAt,
                transcript: keyboardResult,
                message: failureMessage,
                feedbackOffer: keyboardFeedbackOffer?.resultID == keyboardResultID ? keyboardFeedbackOffer : nil
            )
        )
    }

    // MARK: - Audio Interruptions, Route Changes, & System Intents

    private func wireAudioCallbacks() {
        audio.onUnexpectedCaptureEnd = { [weak self] finishedURL, succeeded in
            guard let self,
                  let session = self.activeCapture,
                  session.capture.url == finishedURL else {
                return
            }
            if succeeded {
                self.finishRecording()
            } else {
                self.cancelCurrentJob()
                self.phase = .failed("Recording stopped unexpectedly.")
                self.publishKeyboardSnapshot()
            }
        }

        audio.onSystemEvent = { [weak self] event in
            self?.handleAudioSystemEvent(event)
        }
    }

    func handleAudioSystemEvent(_ event: AudioSystemEvent) {
        switch event {
        case .interruptionBegan:
            interruptionInProgress = true
            interruptionResumeTask?.cancel()
            interruptionResumeTask = nil
            suspendedWarmSessionOnInterruption = keyboardSessionEnabled
            if audio.isOtherAudioPlaying {
                if activeCapture == nil {
                    endWarmSession()
                    return
                }
                releaseAudioAfterCapture = true
            }
            if phase == .recording {
                // Save spoken audio if >= 300ms; otherwise cancel cleanly so "Listening" never sticks during a call.
                if let session = activeCapture, max(recordingDuration, session.capture.currentTime) >= Self.minCaptureDuration {
                    audio.stopKeepalive()
                    finishRecording()
                } else {
                    cancelCurrentJob()
                    keyboardMessage = "Interrupted"
                }
            } else {
                audio.stopKeepalive()
            }
            publishKeyboardSnapshot()

        case .interruptionEnded(let shouldResume):
            interruptionInProgress = false
            guard suspendedWarmSessionOnInterruption else { return }
            if audio.isOtherAudioPlaying {
                endWarmSession()
                return
            }
            guard keyboardSessionEnabled, keyboardSessionExpiresAt > now() else {
                suspendedWarmSessionOnInterruption = false
                endWarmSession()
                return
            }
            if shouldResume || UIApplication.shared.applicationState == .active {
                resumeWarmSessionAfterInterruption()
            } else {
                suspendedWarmSessionOnInterruption = false
                endWarmSession()
            }

        case .routeOldDeviceUnavailable:
            // e.g. AirPods placed in case: finish active speech >= 300ms or rebind keepalive tap to built-in mic.
            if phase == .recording {
                if let session = activeCapture, max(recordingDuration, session.capture.currentTime) >= Self.minCaptureDuration {
                    finishRecording()
                } else {
                    cancelCurrentJob()
                }
            } else if keyboardSessionEnabled && phase == .ready {
                do {
                    try startWarmInput()
                    publishKeyboardSnapshot()
                } catch {
                    endWarmSession()
                }
            }

        case .routeNewDeviceAvailable:
            if keyboardSessionEnabled && phase == .ready && allowBluetoothMic {
                do { try startWarmInput() }
                catch { endWarmSession() }
                publishKeyboardSnapshot()
            }

        case .mediaServicesReset:
            if phase == .recording {
                cancelCurrentJob()
            }
            if keyboardSessionEnabled {
                do {
                    try startWarmInput()
                    publishKeyboardSnapshot()
                } catch {
                    endWarmSession()
                }
            }
        }
    }

    /// A keyboard activation or capture now owns the input: stop a pending resume. While the
    /// interruption itself is still running (a call), the session stays suspended so a failed
    /// attempt does not end it and `.interruptionEnded` still resumes it.
    /// Typr's input runs again, so any interruption is over for Typr. iOS does not always send
    /// `.interruptionEnded`; a later one must neither restart this input nor end the session.
    private func noteAudioActivated() {
        interruptionInProgress = false
        suspendedWarmSessionOnInterruption = false
    }

    private func takeOverInterruptionResume() {
        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        if !interruptionInProgress {
            suspendedWarmSessionOnInterruption = false
        }
    }

    /// Resumes the warm input after an interruption. The input stays marked as suspended while
    /// iOS still refuses activation, so the session loop does not end the session meanwhile.
    private func resumeWarmSessionAfterInterruption() {
        interruptionResumeTask?.cancel()
        interruptionResumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.activateAudio(isCurrent: {
                    self.suspendedWarmSessionOnInterruption && self.keyboardSessionEnabled
                        && self.keyboardSessionExpiresAt > self.now()
                        && self.activeCapture == nil
                        && self.phase != .requestingPermission && self.phase != .recording
                }) {
                    try self.startWarmInput()
                }
                self.suspendedWarmSessionOnInterruption = false
                self.interruptionResumeTask = nil
                self.publishKeyboardSnapshot()
            } catch {
                // Cancelled by a new interruption, a keyboard activation or capture, or the
                // session ending. A capture owns the input now; never end its session here.
                guard !Task.isCancelled, self.suspendedWarmSessionOnInterruption,
                      self.activeCapture == nil,
                      self.phase != .requestingPermission, self.phase != .recording else { return }
                self.suspendedWarmSessionOnInterruption = false
                self.interruptionResumeTask = nil
                self.endWarmSession()
            }
        }
    }

    /// Runs one microphone activation, trying again while iOS briefly refuses it after another
    /// app's audio. Stops with `CancellationError` once `isCurrent` turns false.
    private func activateAudio<T>(isCurrent: () -> Bool, _ attempt: () throws -> T) async throws -> T {
        var lastError: (any Error)?
        for delay in [Duration.zero] + audioRetryDelays {
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            guard isCurrent() else { throw CancellationError() }
            do {
                return try attempt()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    /// AVAudioSession refusals while another app holds audio: cannot start playing ('!pla'),
    /// insufficient priority ('!pri'), cannot interrupt others ('!int').
    nonisolated static func isAudioBusy(_ error: any Error) -> Bool {
        [0x2170_6C61, 0x2170_7269, 0x2169_6E74].contains((error as NSError).code)
    }

    nonisolated static func audioFailureMessage(for error: any Error) -> String {
        isAudioBusy(error) ? audioBusyMessage : error.localizedDescription
    }

    /// Silence and cancellation say nothing about the engine; other failures reload it.
    nonisolated static func transcriptionFailureKeepsModel(_ error: any Error) -> Bool {
        switch DictationLogASRFailure.classify(error) {
        case .noSpeech, .cancelled:
            true
        case .modelNotReady, .other:
            (error as? WhisperTranscriber.TranscriberError) == .emptyTranscript
        }
    }

    private var canReusePreparedModel: Bool {
        isModelReady && !modelNeedsReload && !pendingAppleLanguageChange
    }

    private func wireSystemIntentBus() {
        Task {
            await TyprSystemCommandBus.shared.register { [weak self] command in
                guard let self else { return nil }
                return await self.performSystemCommand(command)
            }
        }
    }

    private func performSystemCommand(_ command: TyprSystemCommand) async -> String? {
        switch command {
        case .toggleDictation:
            if phase == .recording {
                finishRecording()
                if let task = transcriptionTask {
                    await task.value
                }
                return transcript
            }
            if phase == .modelRequired || isFailedPhase {
                prepareModel()
                try? await waitUntilReady(timeoutSeconds: 10)
            }
            guard phase == .ready else { return nil }
            startRecording(copyToPasteboard: true)
            return ""

        case .stopDictation:
            guard phase == .recording else { return transcript }
            finishRecording()
            if let task = transcriptionTask {
                await task.value
            }
            return transcript

        case .cancelDictation:
            cancelCurrentJob()
            return nil

        case .warmSession:
            if !keyboardSessionEnabled {
                if warmDuration == .off {
                    setWarmDuration(.fifteenMinutes)
                }
                requestWarmSession(attemptAutoReturn: false)
            }
            return nil
        }
    }

    private var isFailedPhase: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func waitUntilReady(timeoutSeconds: TimeInterval) async throws {
        let deadline = now() + timeoutSeconds
        while phase == .preparingModel && now() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Launch Fixtures for Simulator Verification (`--snap-state <name>`)

    private static func applyLaunchFixtureIfPresent(to controller: DictationController) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "--snap-state"),
              flagIndex + 1 < args.count else {
            return false
        }
        let scene = args[flagIndex + 1]
        controller.engineName = "Apple Speech"
        controller.currentEngine = .appleSpeech
        controller.transcriptionLanguage = "English"
        controller.keyboardBridge.setModelInstalled(true)
        controller.isModelReady = true

        switch scene {
        case "setup":
            controller.phase = .ready
            controller.warmDuration = .fifteenMinutes
            controller.keyboardSessionEnabled = false

        case "settings-overview", "settings-keyboard", "settings-writing", "settings-history", "settings-history-sample", "settings-history-sample-detail", "settings-speech-engine",
             "settings-style", "settings-language", "settings-keyboard-learned-words",
             "settings-keyboard-words-privacy", "settings-autocorrect-languages",
             "settings-statistics", "settings-statistics-empty", "settings-statistics-sparse",
             "settings-statistics-populated", "settings-statistics-unavailable":
            controller.phase = .ready
            controller.warmDuration = .off
            controller.keyboardSessionEnabled = false

        case "settings-keyboard-typing", "settings-keyboard-off":
            #if targetEnvironment(simulator)
            FullKeyboardSettings().isEnabled = scene == "settings-keyboard-typing"
            FullKeyboardSettings().autocorrect = true
            TyprSettings().autocorrectGerman = true
            TyprSettings().autocorrectEnglish = true
            #endif
            controller.phase = .ready
            controller.warmDuration = .off
            controller.keyboardSessionEnabled = false

        case "ready":
            controller.phase = .ready
            controller.warmDuration = .off
            controller.keyboardSessionEnabled = false
            controller.transcript = "Meet at ten on Thursday and bring the updated design notes."

        case "warm":
            controller.phase = .ready
            controller.warmDuration = .fifteenMinutes
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 42
            controller.keyboardSessionExpiresAt = Date().timeIntervalSince1970 + 14 * 60 + 42
            controller.transcript = "Meet at ten on Thursday and bring the updated design notes."

        case "recording":
            controller.phase = .recording
            controller.warmDuration = .fifteenMinutes
            controller.audioLevel = 0.74
            controller.loudnessDB = -31.0
            controller.recordingDuration = 6.4
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 54

        case "transcribing":
            controller.phase = .transcribing
            controller.warmDuration = .fifteenMinutes
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 52

        case "handoff-listening", "handoff-no-home-bar":
            controller.phase = .recording
            controller.audioLevel = 0.68
            controller.loudnessDB = -32.5
            controller.recordingDuration = 3.2
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 57
            controller.autoReturnState = .swipeFallback
            Task { @MainActor in
                let start = Date().timeIntervalSince1970 - 3.0
                var simTime: Float = 0.0
                while !Task.isCancelled {
                    controller.loudnessDB = DotScopeSimulation.demoLoudness(at: simTime) + 4.5
                    controller.recordingDuration = Date().timeIntervalSince1970 - start
                    simTime += 0.033
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }

        case "handoff-tour":
            controller.phase = .recording
            controller.audioLevel = 0.68
            controller.loudnessDB = -32.0
            controller.recordingDuration = 0.0
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 58
            controller.autoReturnState = .swipeFallback
            Task { @MainActor in
                let boot = Date().timeIntervalSince1970
                var simTime: Float = 0.0
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince1970 - boot
                    if elapsed < 3.4 {
                        if controller.phase != .recording {
                            withAnimation(TyprMotion.stage) {
                                controller.phase = .recording
                            }
                        }
                        controller.loudnessDB = DotScopeSimulation.demoLoudness(at: simTime) + 4.5
                        controller.recordingDuration = elapsed
                        simTime += 0.033
                    } else if elapsed < 4.7 {
                        if controller.phase != .transcribing {
                            withAnimation(TyprMotion.stage) {
                                controller.phase = .transcribing
                            }
                        }
                        controller.loudnessDB = -120.0
                    } else {
                        if controller.phase != .ready {
                            withAnimation(TyprMotion.stage) {
                                controller.phase = .ready
                            }
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }

        case "handoff-returning":
            controller.phase = .recording
            controller.audioLevel = 0.62
            controller.recordingDuration = 1.1
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 59
            controller.autoReturnState = .attempting

        case "hosted-keyboard-warm":
            controller.phase = .ready
            controller.warmDuration = .fifteenMinutes
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 42
            controller.keyboardSessionExpiresAt = Date().timeIntervalSince1970 + 14 * 60 + 42
            Task { @MainActor in
                while !Task.isCancelled {
                    let t = Date().timeIntervalSince1970
                    controller.keyboardBridge.publish(
                        KeyboardSnapshot(
                            state: .ready,
                            heartbeat: t,
                            expiresAt: t + 14 * 60 + 42
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }

        case "hosted-keyboard-recording", "hosted-keyboard-light":
            controller.phase = .ready
            controller.warmDuration = .fifteenMinutes
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 55
            let startWall = Date().timeIntervalSince1970 - 4.0
            Task { @MainActor in
                var simTime: Float = 0.4
                while !Task.isCancelled {
                    let t = Date().timeIntervalSince1970
                    let db = -28.5 + 5.2 * sin(simTime * 19.0) + 2.4 * cos(simTime * 7.3)
                    controller.keyboardBridge.publish(
                        KeyboardSnapshot(
                            state: .recording,
                            heartbeat: t,
                            expiresAt: t + 15 * 60,
                            recordingStartedAt: startWall,
                            audioLevel: 0.78,
                            loudnessDB: db,
                            jobID: "hosted-demo-job"
                        )
                    )
                    simTime += 0.033
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }

        case "hosted-keyboard-tour":
            controller.phase = .ready
            controller.warmDuration = .fifteenMinutes
            controller.keyboardSessionEnabled = true
            controller.keyboardSessionRemaining = 14 * 60 + 58
            Task { @MainActor in
                let boot = Date().timeIntervalSince1970
                let freshResultID = "hosted-tour-\(UUID().uuidString)"
                var simTime: Float = 0.0
                while !Task.isCancelled {
                    let t = Date().timeIntervalSince1970
                    let elapsed = t - boot
                    if elapsed < 2.5 {
                        controller.keyboardBridge.publish(
                            KeyboardSnapshot(
                                state: .ready,
                                heartbeat: t,
                                expiresAt: t + 15 * 60
                            )
                        )
                    } else if elapsed < 5.2 {
                        let db = DotScopeSimulation.demoLoudness(at: simTime) + 4.5
                        controller.keyboardBridge.publish(
                            KeyboardSnapshot(
                                state: .recording,
                                heartbeat: t,
                                expiresAt: t + 15 * 60,
                                recordingStartedAt: boot + 2.5,
                                audioLevel: 0.78,
                                loudnessDB: db,
                                jobID: "hosted-tour-job"
                            )
                        )
                        simTime += 0.033
                    } else if elapsed < 6.4 {
                        controller.keyboardBridge.publish(
                            KeyboardSnapshot(
                                state: .transcribing,
                                heartbeat: t,
                                expiresAt: t + 15 * 60,
                                jobID: "hosted-tour-job"
                            )
                        )
                    } else {
                        controller.keyboardBridge.publish(
                            KeyboardSnapshot(
                                state: .ready,
                                heartbeat: t,
                                expiresAt: t + 14 * 60 + 54,
                                resultID: freshResultID,
                                resultExpiresAt: boot + 30,
                                transcript: "See you at ten."
                            )
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }

        default:
            return false
        }
        return true
    }
}
