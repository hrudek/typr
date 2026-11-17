import SwiftUI

/// Unknown Core ML progress animates only while visible, without implying a percentage.
struct ModelPreparationIndicator: View {
    @Environment(\.scenePhase) private var scenePhase
    let progress: ModelPreparationProgress

    var body: some View {
        Group {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
            } else if scenePhase == .active {
                ProgressView()
            } else {
                // A continued processing assertion keeps the process alive, not permission
                // to render Metal frames. Remove the spinner while inactive/backgrounded.
                Image(systemName: "hourglass")
            }
        }
        .accessibilityLabel(progress.detail)
    }
}

/// What one engine row shows, computed from plain values so it is testable without views.
nonisolated struct SpeechEngineRowState: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        /// Choose the engine (prepares it; Parakeet may download through FluidAudio).
        case use
        /// Prepare the chosen engine again after a failure or at launch.
        case prepare
        /// Downloaded engines only: the explicit download.
        case download
        case cancelDownload
        case retryDownload
    }

    let engine: SpeechEngineChoice
    /// "In use", "In use · automatic" or "Chosen" (chosen but not ready yet).
    let badge: String?
    let status: String
    /// Measured fraction, when available. Indeterminate preparation has no percentage.
    let progress: Double?
    let isIndeterminate: Bool
    let action: Action
    let actionTitle: String?
    /// False for choosing/preparing while a dictation runs; downloads are always allowed.
    let actionEnabled: Bool
    let warning: String?
    let note: String?
    /// The model is on this iPhone and can be deleted (never Apple Speech).
    let offersDelete: Bool
    /// False while a dictation runs or another deletion is in progress.
    let deleteEnabled: Bool

    static func languageWarning(engine: SpeechEngineChoice?, language: DictationLanguage) -> String? {
        engine == .parakeetV2 && language != .english
            ? "Not suitable for German dictation. Typr keeps your chosen engine."
            : nil
    }

    static func make(
        engine: SpeechEngineChoice,
        preferred: SpeechEngineChoice?,
        current: SpeechEngineChoice?,
        availability: SpeechEngineAvailability?,
        /// The engine's own download; ignored for engines without a Download button.
        install: ModelInstallState,
        language: DictationLanguage,
        preparation: ModelPreparationProgress?,
        failure: String?,
        canChangeEngine: Bool
    ) -> SpeechEngineRowState {
        let downloadSizeLabel = DownloadableModels.downloadSizeLabel(for: engine)
        let offersDelete = engine.hasDeletableModel
            && (downloadSizeLabel == nil ? availability == .installed : install == .installed)
        let isChosen = preferred == engine
        let badge: String? = current == engine
            ? (preferred == nil ? "In use · automatic" : "In use")
            : (isChosen ? "Chosen" : nil)
        let warning = languageWarning(engine: engine, language: language)
        let preparationNote = "Opening Typr prepares the installed, chosen model automatically. First optimization can take several minutes. iOS may continue it in the background, but can pause or stop it; reopen Typr to retry. Vocabulary and the tech glossary apply after recognition"
        let note: String? = switch engine {
        case .whisperLargeV3Turbo: preparationNote + ", not as Whisper hints."
        case .parakeetV3, .orukeet, .cohereTranscribe: preparationNote + "."
        case .appleSpeech, .parakeetV2: nil
        }

        func row(_ status: String, progress: Double? = nil, isIndeterminate: Bool = false, action: Action = .none, title: String? = nil) -> SpeechEngineRowState {
            let enabled: Bool
            switch action {
            case .use, .prepare: enabled = canChangeEngine
            default: enabled = true
            }
            return SpeechEngineRowState(engine: engine, badge: badge, status: status, progress: progress,
                                        isIndeterminate: isIndeterminate,
                                        action: action, actionTitle: title, actionEnabled: enabled,
                                        warning: warning, note: note,
                                        offersDelete: offersDelete, deleteEnabled: canChangeEngine)
        }

        if downloadSizeLabel != nil {
            switch install {
            case .downloading(let progress):
                let done = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                return row("Downloading \(done) of \(total) (\(Int(progress.fraction * 100))%)",
                           progress: progress.fraction, action: .cancelDownload, title: "Cancel")
            case .verifying:
                return row("Checking the downloaded files")
            default:
                break
            }
        }
        if isChosen, current != engine, let preparation {
            return row(preparation.detail, progress: preparation.fractionCompleted,
                       isIndeterminate: preparation.fractionCompleted == nil)
        }
        if isChosen, current != engine, let failure {
            if downloadSizeLabel != nil, install != .installed {
                return row(failure, action: .retryDownload, title: "Retry")
            }
            return row(failure, action: .prepare, title: "Try again")
        }
        if downloadSizeLabel != nil {
            switch install {
            case .cancelled:
                return row("Download cancelled. Retry starts the download again; files already downloaded are kept.",
                           action: .retryDownload, title: "Retry")
            case .failed(let message):
                return row(message, action: .retryDownload, title: "Retry")
            default:
                break
            }
        }
        guard let availability else { return row("Checking this iPhone…") }
        guard availability.isSupported else { return row(availability.detail) }
        if current == engine {
            return isChosen
                ? row("Ready on this iPhone")
                : row("Ready on this iPhone", action: .use, title: "Use")
        }
        if let downloadSizeLabel, install != .installed {
            return row(availability.detail, action: .download, title: "Download (\(downloadSizeLabel))")
        }
        if isChosen {
            return row(availability.detail, action: .prepare, title: "Prepare")
        }
        let title = engine == .parakeetV2 && availability != .installed ? "Download and use" : "Use"
        return row(availability.detail, action: .use, title: title)
    }
}

/// The Speech engine section: every engine with its languages and live status. Choosing applies to the next dictation and never falls back.
@MainActor
struct SpeechEngineCard: View {
    let dictation: DictationController
    @State private var availability: [SpeechEngineChoice: SpeechEngineAvailability] = [:]
    @State private var availabilityGeneration: UInt64 = 0
    @State private var pendingDeletion: SpeechEngineChoice?
    @State private var deletionFailure: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(SpeechEngineChoice.allCases, id: \.self) { engine in
                SettingsSection {
                    engineRow(state(for: engine))
                }
            }
            Label(footer, systemImage: "lock.shield")
                .font(.subheadline)
                .foregroundStyle(TyprTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { engine in
            Button("Delete", role: .destructive) { delete(engine) }
            Button("Cancel", role: .cancel) {}
        } message: { engine in
            Text(Self.deletionMessage(for: engine))
        }
        .alert("The model could not be deleted", isPresented: Binding(
            get: { deletionFailure != nil }, set: { if !$0 { deletionFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionFailure ?? "")
        }
        .task(id: refreshKey) {
            refreshInstallers()
            await refreshAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshInstallers()
                Task { await refreshAvailability() }
            }
        }
    }

    /// Re-read availability when the language, the ready engine or a download's install changes.
    private var refreshKey: String {
        let failed: Bool
        if case .failed = dictation.phase { failed = true } else { failed = false }
        let installed = SpeechEngineChoice.allCases.map { DownloadableModels.installer(for: $0)?.state == .installed }
        return "\(dictation.dictationLanguage.rawValue)|\(dictation.currentEngine?.rawValue ?? "-")|\(installed)|\(failed)"
    }

    private func refreshInstallers() {
        for engine in SpeechEngineChoice.allCases {
            DownloadableModels.installer(for: engine)?.refresh()
        }
    }

    private func refreshAvailability() async {
        let key = refreshKey
        availabilityGeneration &+= 1
        let generation = availabilityGeneration
        for engine in SpeechEngineChoice.allCases {
            let result = await dictation.engineAvailability(engine)
            guard !Task.isCancelled, refreshKey == key, availabilityGeneration == generation else { return }
            availability[engine] = result
        }
    }

    private var footer: String {
        var lines: [String] = []
        if let preferred = dictation.preferredEngine {
            lines.append("Chosen: \(preferred.displayName). No automatic switching.")
        } else {
            lines.append("Automatic: Apple Speech when available, otherwise Parakeet V2.")
        }
        if !dictation.canChangeEngine {
            lines.append("Finish the current dictation to change the engine.")
        }
        lines.append("All engines run on this iPhone; audio never leaves it.")
        return lines.joined(separator: "\n")
    }

    private func state(for engine: SpeechEngineChoice) -> SpeechEngineRowState {
        var preparation: ModelPreparationProgress?
        var failure: String?
        if dictation.preferredEngine == engine {
            switch dictation.phase {
            case .preparingModel: preparation = dictation.modelPreparation
            case .failed(let message) where dictation.currentEngine == nil: failure = message
            default: break
            }
        }
        return SpeechEngineRowState.make(
            engine: engine,
            preferred: dictation.preferredEngine,
            current: dictation.currentEngine,
            availability: availability[engine],
            install: DownloadableModels.installer(for: engine)?.state ?? .notInstalled,
            language: dictation.dictationLanguage,
            preparation: preparation,
            failure: failure,
            canChangeEngine: dictation.canChangeEngine
        )
    }

    static func deletionMessage(for engine: SpeechEngineChoice) -> String {
        engine == .parakeetV2
            ? "Removes the downloaded model from this iPhone. Typr downloads it again the next time you use it."
            : "Removes the downloaded model from this iPhone. Download it again to use it. Your engine choice stays."
    }

    private func delete(_ engine: SpeechEngineChoice) {
        Task {
            if case .failed(let message) = await dictation.deleteModel(engine) {
                deletionFailure = message
            }
            DownloadableModels.installer(for: engine)?.refresh()
            await refreshAvailability()
        }
    }

    private func perform(_ state: SpeechEngineRowState) {
        switch state.action {
        case .none: break
        case .use: dictation.selectEngine(state.engine)
        case .prepare: dictation.prepareModel()
        case .download, .retryDownload: DownloadableModels.installer(for: state.engine)?.install()
        case .cancelDownload: DownloadableModels.installer(for: state.engine)?.cancel()
        }
    }

    private func engineRow(_ state: SpeechEngineRowState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.engine.displayName)
                    .font(.headline).foregroundStyle(TyprTheme.textBase)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let badge = state.badge {
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(badge.hasPrefix("In use") ? TyprTheme.success : TyprTheme.textMuted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(TyprTheme.layer01, in: Capsule())
                }
            }
            Text("Languages: \(state.engine.languageSummary)")
                .font(.subheadline)
                .foregroundStyle(TyprTheme.textMuted)
            Text(state.status)
                .font(.subheadline)
                .foregroundStyle(TyprTheme.textMuted)
            if let progress = state.progress {
                ProgressView(value: progress).tint(TyprTheme.textBase)
            } else if state.isIndeterminate {
                ModelPreparationIndicator(progress: ModelPreparationProgress(
                    fractionCompleted: nil, detail: state.status))
                    .tint(TyprTheme.textBase)
            }
            if let warning = state.warning {
                Text(warning)
                    .font(.subheadline)
                    .foregroundStyle(TyprTheme.warmMic)
            }
            if state.engine.requiresExplicitDownload {
                Text("First preparation can take several minutes.")
                    .font(.subheadline)
                    .foregroundStyle(TyprTheme.textMuted)
            }
            if let title = state.actionTitle {
                Button { perform(state) } label: {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(TyprTheme.textBase)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(TyprTheme.layer02, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(!state.actionEnabled)
                    .opacity(state.actionEnabled ? 1 : 0.4)
            }
            if state.offersDelete {
                Button(role: .destructive) { pendingDeletion = state.engine } label: {
                    Text("Delete")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(TyprTheme.warmMic)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(!state.deleteEnabled)
                    .opacity(state.deleteEnabled ? 1 : 0.4)
            }
            Divider().overlay(TyprTheme.borderWeak)
            DisclosureGroup("Engine details") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(state.engine.summary)
                    if let note = state.note { Text(note) }
                }
                .font(.subheadline)
                .foregroundStyle(TyprTheme.textMuted)
                .padding(.top, 8)
            }
            .disclosureGroupStyle(SettingsDisclosureStyle())
        }
        .padding(16)
    }
}
