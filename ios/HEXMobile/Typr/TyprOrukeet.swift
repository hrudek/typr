import Foundation
import os
import UIKit

/// Settings › Typr › Orukeet, on unless turned off. While it's on, Orukeet takes the dictation
/// languages it knows (Parakeet Ultra's 25) on an iPhone with Parakeet Ultra's memory, the way
/// Settings › Dictation › Model: Multilingual brings in Parakeet Ultra: it downloads, unpacks
/// and loads beside the engine Hex dictates with, which keeps dictating until Orukeet is ready.
/// Until then, wherever it can't load, and while it's off, Hex picks its engine as upstream does.
nonisolated enum TyprOrukeetChoice {
    /// `ParakeetLoadGuard.noteLaunch` for Orukeet, once per launch before its first load.
    static let launchNoted: Void = ParakeetLoadGuard(model: TyprOrukeetTranscriber.loadGuardModel).noteLaunch()

    static var isSetAside: Bool {
        _ = launchNoted
        return ParakeetLoadGuard(model: TyprOrukeetTranscriber.loadGuardModel).lastLoadWasInterrupted
    }

    /// The language Orukeet dictates in, or nil for upstream's engine. `availableMemory` 0
    /// means iOS sets no limit (the simulator), and is what a download passes.
    static func language(
        enabled: Bool = TyprSettings().orukeet,
        wanted: String? = LanguageSettings().dictationLanguage
            ?? LanguageSettings().keyboardDictationLanguage()
            ?? Locale.preferredLanguages.first,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableMemory: UInt64 = UInt64(max(0, os_proc_available_memory())),
        setAside: Bool = isSetAside
    ) -> String? {
        guard enabled, MultilingualParakeetSettings.fits(physicalMemory: physicalMemory), !setAside,
              ParakeetUltraTranscriber.hasRoomToLoad(available: availableMemory),
              let wanted, MultilingualParakeetSettings.supports(wanted) else { return nil }
        return wanted
    }

    /// As `DictationController.multilingualStep`, with an unpack step between the download and
    /// the first load.
    enum Step: Equatable {
        case none
        case download
        case install
        case loadBeside
        case dictate
    }

    static func step(language: String?, downloaded: Bool, installed: Bool, compiled: Bool) -> Step {
        guard language != nil else { return .none }
        guard installed else { return downloaded ? .install : .download }
        return compiled ? .dictate : .loadBeside
    }

    /// `DictationController.defaultTranscriber`'s first pick: Orukeet once it is installed and
    /// has loaded on this iOS before, nil for upstream's engine.
    static func transcriber(
        language: String? = Self.language(),
        installed: Bool = TyprOrukeetModel.isInstalled(),
        compiled: Bool = TyprOrukeetTranscriber.isCompiled
    ) -> (any LocalTranscribing)? {
        guard let language,
              step(language: language, downloaded: false, installed: installed, compiled: compiled) == .dictate
        else { return nil }
        return TyprOrukeetTranscriber(language: language)
    }

    /// Home's notice when Orukeet's preparation failed: Hex prepares upstream's engine instead.
    static func switchNotice(for error: Error) -> String? {
        switch error as? TyprOrukeetTranscriber.TranscriberError {
        case .notEnoughMemory:
            String(localized: "Not enough memory for Orukeet. Hex is using its usual model.")
        case .notInstalled, .loadFailed:
            String(localized: "Orukeet didn't load. Hex is using its usual model.")
        case .notPrepared, .emptyTranscript, nil:
            nil
        }
    }
}

/// Orukeet's download, unpacking and first load beside the engine Hex dictates with, shown with
/// upstream's `MultilingualModelStatus` under Settings › Typr.
@MainActor
final class TyprOrukeet {
    static let shared = TyprOrukeet()

    let download: ParakeetUltraDownload
    private var installTask: Task<Void, Never>?
    private weak var dictation: DictationController?
    private var observers: [NSObjectProtocol] = []

    init() {
        let network = SpeechModelDownloadNetwork.shared
        download = ParakeetUltraDownload(
            directory: TyprOrukeetModel.directory,
            files: [TyprOrukeetModel.archive],
            base: TyprOrukeetModel.baseURL
        )
        download.mayDownload = { network.mayDownload(.multilingual) }
        download.onDownloaded = { [weak self] in
            network.forgetMobileData(for: .multilingual)
            self?.install()
        }
        network.observe { [weak self] _ in self?.download.connectionChanged() }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.download.appMovedToBackground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.download.appBecameActive() }
            },
        ]
    }

    /// From `syncMultilingualParakeet`, once an engine is ready or failed: downloads, unpacks or
    /// loads Orukeet beside it. True when Orukeet dictates or is taking over, so Parakeet Ultra
    /// stays out of the way.
    func sync(_ dictation: DictationController) -> Bool {
        self.dictation = dictation
        guard TyprSettings().orukeet else {
            download.settle()
            return false
        }
        let language = TyprOrukeetChoice.language()
        let wanted = TyprOrukeetChoice.language(availableMemory: 0)
        switch TyprOrukeetChoice.step(
            language: wanted,
            downloaded: TyprOrukeetModel.isArchiveDownloaded(),
            installed: TyprOrukeetModel.isInstalled(),
            compiled: true
        ) {
        case .none:
            if !download.isFailed { download.settle() }
            return false
        case .download:
            startDownload()
            return false
        case .install:
            install()
            return false
        case .loadBeside, .dictate:
            if dictation.engine == .typrOrukeet, dictation.isModelReady {
                download.settle()
            } else if let language {
                dictation.loadTyprOrukeetBeside(language: language)
            } else if let wanted, dictation.replaceParakeetWithTyprOrukeet(language: wanted) {
                download.loading()
            } else {
                download.fail(String(localized: "Not enough memory for Orukeet. Hex is using its usual model."))
                return false
            }
            return true
        }
    }

    /// Settings › Typr › Orukeet switched. On: as a first launch with it on. Off: the download
    /// stops (deleted unless installed, so a switch back needs none) and Hex prepares upstream's
    /// engine if Orukeet dictated or was loading.
    func changed(_ dictation: DictationController = .shared) {
        self.dictation = dictation
        if TyprSettings().orukeet {
            ParakeetLoadGuard(model: TyprOrukeetTranscriber.loadGuardModel).forget()
            download.settle()
            if dictation.isModelReady || dictation.phase == .preparingModel {
                _ = sync(dictation)
                return
            }
        } else {
            let download = download
            let installing = installTask
            installTask = nil
            installing?.cancel()
            Task {
                await download.stop()
                await installing?.value
                TyprOrukeetModel.removeUnlessInstalled()
            }
            if dictation.engine != .typrOrukeet, dictation.isModelReady, dictation.phase != .preparingModel {
                dictation.modelPrepGeneration &+= 1
                return
            }
        }
        switch dictation.phase {
        case .recording, .transcribing, .requestingPermission:
            dictation.pendingLanguagePreparation = true
        case .modelRequired, .preparingModel, .ready, .failed:
            dictation.prepareModel()
        }
    }

    /// Try again beside Orukeet's status.
    func retry() {
        ParakeetLoadGuard(model: TyprOrukeetTranscriber.loadGuardModel).forget()
        download.settle()
        if TyprOrukeetModel.isInstalled() || TyprOrukeetModel.isArchiveDownloaded() {
            if let dictation { _ = sync(dictation) }
        } else if TyprOrukeetChoice.language(availableMemory: 0) != nil {
            download.restart()
        }
    }

    func useMobileData() {
        SpeechModelDownloadNetwork.shared.allowMobileData(for: .multilingual)
        startDownload()
    }

    /// Use English beside Orukeet's status on home.
    func turnOff() {
        TyprSettings().orukeet = false
        changed()
    }

    func loaded() {
        download.settle()
    }

    /// A load that failed, said with Try again; the transcriber set it aside.
    func failedToLoad(_ error: Error) {
        guard TyprSettings().orukeet, !(error is CancellationError) else {
            download.settle()
            return
        }
        download.fail(TyprOrukeetChoice.switchNotice(for: error) ?? UserFacingError.message(for: error, context: .model))
    }

    private func startDownload() {
        guard TyprOrukeetChoice.language(availableMemory: 0) != nil,
              !TyprOrukeetModel.isInstalled(), !TyprOrukeetModel.isArchiveDownloaded() else { return }
        SpeechModelDownloadNetwork.shared.watch()
        download.start()
    }

    private func install() {
        guard installTask == nil, !TyprOrukeetModel.isInstalled() else { return }
        download.loading()
        let backgroundTime = BackgroundTime("Prepare Orukeet")
        installTask = Task { [weak self] in
            defer { backgroundTime.end() }
            let unpacking = Task.detached(priority: .utility) { try await TyprOrukeetModel.install() }
            do {
                try await withTaskCancellationHandler {
                    try await unpacking.value
                } onCancel: {
                    unpacking.cancel()
                }
                guard let self, !Task.isCancelled else { return }
                self.installTask = nil
                _ = self.sync(self.dictation ?? .shared)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installTask = nil
                print("typr orukeet: unpacking failed: \(error)")
                self.download.fail(String(localized: "Orukeet couldn't be unpacked. Try again."))
            }
        }
    }
}

extension DictationController {
    /// Hooked into `syncMultilingualParakeet`, for the app's controller only: one a test builds
    /// keeps upstream's behaviour.
    func syncTyprOrukeet() -> Bool {
        guard self === Self.shared else { return false }
        return TyprOrukeet.shared.sync(self)
    }

    /// As `loadMultilingualParakeetBeside`, for Orukeet.
    func loadTyprOrukeetBeside(language: String) {
        guard phase != .preparingModel else { return }
        modelPrepGeneration &+= 1
        let prepGen = modelPrepGeneration
        let orukeet = TyprOrukeet.shared
        orukeet.download.loading()
        let backgroundTime = BackgroundTime("Prepare Orukeet")
        Task {
            defer { backgroundTime.end() }
            let candidate = TyprOrukeetTranscriber(language: language)
            do {
                try await candidate.prepare { _ in }
                guard self.modelPrepGeneration == prepGen else { return }
                self.transcriber = candidate
                self.engine = candidate.engine
                self.transcriptionLanguage = await candidate.languageName
                self.transcriptionLanguageID = await candidate.languageIdentifier
                self.languageOffer = nil
                self.isModelReady = true
                self.keyboardBridge.setModelInstalled(true)
                self.transition(model: .ready)
                orukeet.loaded()
                self.publishKeyboardSnapshot()
            } catch {
                guard self.modelPrepGeneration == prepGen else { return }
                orukeet.failedToLoad(error)
            }
        }
    }

    /// As `replaceParakeetWithMultilingual`: Parakeet V2 leaves no room to load Orukeet beside it.
    func replaceParakeetWithTyprOrukeet(language: String) -> Bool {
        guard transcriber is ParakeetTranscriber, phase != .preparingModel else { return false }
        transcriber = ParakeetTranscriber()
        isModelReady = false
        prepareModel(candidate: TyprOrukeetTranscriber(language: language))
        return true
    }
}
