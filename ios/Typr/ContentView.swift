import SwiftUI
import UIKit

private struct AppRecordingClockLabel: View {
    let dictation: DictationController

    var body: some View {
        Text(TyprTheme.formatClock(TimeInterval(dictation.recordingWholeSeconds)))
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(TyprTheme.textBase)
    }
}

private struct AppWarmRemainingLabel: View {
    let dictation: DictationController

    var body: some View {
        Text(dictation.keyboardSessionDisplayRemaining)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(TyprTheme.textMuted)
    }
}

struct ContentView: View {
    /// Shared by the actual navigation path and tests; ordinary launches keep the existing store-backed page.
    nonisolated static func learnedWordsUsesFixture(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == "settings-keyboard-learned-words"
    }

    private enum AppStageMode: Equatable {
        case idle
        case recording
        case transcribing
        case preparing
        case permission
        case failed
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var dictation: DictationController
    @Binding var openedFromKeyboard: Bool
    @Binding var showSetup: Bool
    var setupRequestID: UUID? = nil
    @State private var setupMonitor = KeyboardSetupMonitor()
    @State private var feedbackRouter = TyprFeedbackRouter.shared
    @State private var historyStore: DictationLogStore = {
        #if targetEnvironment(simulator)
        if DictationHistoryFixture.isRequested(arguments: ProcessInfo.processInfo.arguments) { return DictationHistoryFixture.store() }
        #endif
        return DictationLogStore.shared
    }()
    @State private var practiceText = ""
    @State private var settingsPath: [SettingsDestination] = {
        #if targetEnvironment(simulator)
        SettingsDestination.snapshotDestination(arguments: ProcessInfo.processInfo.arguments).map { [$0] } ?? []
        #else
        []
        #endif
    }()
    @FocusState private var practiceFocused: Bool

    private static let stageWellHeight: CGFloat = 48
    private static let stageControlHeight: CGFloat = 36
    private static let stageInset: CGFloat = 6
    private static let stageCancelWidth: CGFloat = 36
    private static let stageDoneWidth: CGFloat = 70

    private static var autoFocusPracticeField: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--snap-state"), idx + 1 < args.count else { return false }
        return args[idx + 1].hasPrefix("hosted-keyboard")
    }

    private static var simulatesHomeButtonDevice: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--snap-state"), idx + 1 < args.count else { return false }
        return args[idx + 1] == "handoff-no-home-bar"
    }

    var body: some View {
        ZStack {
            TyprTheme.bgDeep
                .ignoresSafeArea()

            if openedFromKeyboard {
                keyboardHandoffView
                    .transition(.opacity)
            } else {
                standaloneView
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(TyprMotion.reducedFade, value: openedFromKeyboard)
    }

    private var appStageMode: AppStageMode {
        switch dictation.phase {
        case .recording:
            .recording
        case .transcribing:
            .transcribing
        case .preparingModel:
            .preparing
        case .requestingPermission:
            .permission
        case .failed:
            .failed
        case .modelRequired, .ready:
            .idle
        }
    }

    private var handoffScopePhase: DotScopePhase {
        switch dictation.phase {
        case .recording:
            .recording
        case .transcribing:
            .processing
        default:
            .hidden
        }
    }

    private var stageScopePhase: DotScopePhase {
        switch dictation.phase {
        case .recording:
            .recording
        case .transcribing:
            .processing
        case .preparingModel, .requestingPermission:
            .hidden
        case .failed:
            .failed
        case .modelRequired, .ready:
            .idle
        }
    }

    private var setupComplete: Bool {
        setupMonitor.keyboardReady
            && setupMonitor.microphone == .granted
            && dictation.isModelReady
    }

    private var hasTranscript: Bool {
        !dictation.transcript.isEmpty
    }

    // MARK: - Standalone App

    private var standaloneView: some View {
        NavigationStack(path: $settingsPath) {
            settingsOverview
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SettingsDestination.self) { destination in
                    if destination == .statistics {
                        #if targetEnvironment(simulator)
                        StatisticsView(fixture: StatisticsFixture.launchFixture(arguments: ProcessInfo.processInfo.arguments))
                        #else
                        StatisticsView()
                        #endif
                    } else if destination == .history {
                        DictationHistoryView(store: historyStore, router: feedbackRouter)
                    } else if destination == .keyboardLearnedWords {
                        KeyboardLearnedWordsView(
                            fixture: Self.learnedWordsUsesFixture(arguments: ProcessInfo.processInfo.arguments))
                    } else {
                        SettingsPage(title: destination.title, subtitle: destination.subtitle) {
                            switch destination {
                            case .keyboard: KeyboardSettingsCard()
                            case .autocorrectLanguages: AutocorrectLanguageSettingsCard()
                            case .keyboardLearnedWords, .statistics, .history:
                                EmptyView() // Handled above.
                            case .textProcessing: TextProcessingSettingsCard()
                            case .speechEngine: SpeechEngineCard(dictation: dictation)
                            case .style: DictationStyleSettingsCard(dictation: dictation)
                            case .language: DictationLanguageSettingsCard(dictation: dictation)
                            }
                        }
                    }
                }
        }
        .onChange(of: feedbackRouter.requestedEntry) { _, id in
            if id != nil { openHistory() }
        }
        .onChange(of: setupRequestID) { _, _ in
            // Each explicit setup URL is a new request, even when showSetup was already true.
            settingsPath = []
        }
        .onAppear {
            if showSetup { settingsPath = [] }
            if feedbackRouter.requestedEntry != nil { openHistory() }
            DictationLogStore.shared.drainKeyboardFeedback(force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { DictationLogStore.shared.drainKeyboardFeedback(force: true) }
        }
        .tint(TyprTheme.agentBlue)
    }

    private func openHistory() {
        if settingsPath.last != .history { settingsPath = [.history] }
    }

    private var settingsOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerRow

                if showSetup || !setupComplete {
                    KeyboardSetupCard(dictation: dictation, monitor: setupMonitor)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                stageBar

                if hasTranscript {
                    transcriptCard
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if case .failed(let message) = dictation.phase {
                    errorBanner(message)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SettingsSection(title: "Dictation") {
                        settingsCard
                    }
                    if let warning = SpeechEngineRowState.languageWarning(
                        engine: dictation.preferredEngine ?? dictation.currentEngine,
                        language: dictation.dictationLanguage
                    ) {
                        Label("Parakeet V2 is English only. \(warning)", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(TyprTheme.warmMic)
                            .padding(.horizontal, 16)
                    }
                }
                SettingsSection(title: "Statistics") {
                    NavigationLink(value: SettingsDestination.statistics) {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.tap").foregroundStyle(TyprTheme.agentBlue)
                            Text("Statistics").foregroundStyle(TyprTheme.textBase)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(TyprTheme.textMuted)
                        }
                        .padding(16).frame(minHeight: 44)
                    }
                }
                SettingsPreferences()

                SettingsSection(title: "Try your keyboard", subtitle: "Tap below to test typing and dictation.") {
                    practiceField
                }
                Label("Your voice stays on your iPhone", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(TyprTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .animation(TyprMotion.stageAnimation(reduceMotion: reduceMotion), value: appStageMode)
            .animation(TyprMotion.settleAnimation(reduceMotion: reduceMotion), value: dictation.keyboardSessionEnabled)
            .animation(TyprMotion.settleAnimation(reduceMotion: reduceMotion), value: hasTranscript)
            .animation(TyprMotion.settleAnimation(reduceMotion: reduceMotion), value: setupComplete)
        }
        .background(TyprTheme.bgDeep.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .task {
            while !Task.isCancelled {
                setupMonitor.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                setupMonitor.refresh()
            }
        }
    }

    private var headerRow: some View {
        let showRecordingPill = appStageMode == .recording
        let showWarmPill = appStageMode != .recording
            && appStageMode != .transcribing
            && dictation.keyboardSessionEnabled

        return HStack(alignment: .center, spacing: 9) {
            TyprMarkView(
                size: 20,
                color: showRecordingPill ? TyprTheme.warmPearl : TyprTheme.textBase
            )

            Spacer()

            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    TyprStatusDot(color: TyprTheme.danger, size: 6.5)
                    AppRecordingClockLabel(dictation: dictation)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.07), in: Capsule())
                .typrTrayReveal(showRecordingPill, reduceMotion: reduceMotion, offsetY: 2)

                Button {
                    withAnimation(TyprMotion.settleAnimation(reduceMotion: reduceMotion)) {
                        dictation.endWarmSession()
                    }
                } label: {
                    HStack(spacing: 6) {
                        TyprStatusDot(color: TyprTheme.warmMic, size: 6)
                        AppWarmRemainingLabel(dictation: dictation)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End warm microphone session")
                .typrTrayReveal(showWarmPill, reduceMotion: reduceMotion, offsetY: 2)
            }
        }
        .frame(height: 30)
    }

    private var stageBar: some View {
        let mode = appStageMode
        let showScope = stageScopePhase != .hidden
        let showRecordingControls = mode == .recording
        let showIdleTrigger = mode == .idle || mode == .failed
        let showPreparing = mode == .preparing
        let showPermission = mode == .permission
        let idleWidth: CGFloat = (dictation.phase == .modelRequired || mode == .failed) ? 90 : 96

        let leadInset: Float = showRecordingControls
            ? Float(Self.stageInset + Self.stageCancelWidth + 6)
            : 0.0
        let trailInset: Float = if showRecordingControls {
            Float(Self.stageInset + Self.stageDoneWidth + 6)
        } else if showIdleTrigger {
            Float(Self.stageInset + idleWidth + 6)
        } else {
            0.0
        }

        return ZStack {
            TyprRecessedWell(isDark: true)

            // Permanently mounted so phosphor trails and inset springs never reset mid-session.
            DotScopeView(
                phase: stageScopePhase,
                tuning: .bar(leadingInset: leadInset, trailingInset: trailInset, fade: 28.0, spacing: 3.5),
                drawPlate: false,
                loudnessProvider: { [weak dictation] in dictation?.loudnessDB ?? -120.0 }
            )
            .clipShape(Capsule())
            .opacity(showScope ? 1.0 : 0.0)
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button {
                    withAnimation(TyprMotion.stageAnimation(reduceMotion: reduceMotion)) {
                        dictation.cancelCurrentJob()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TyprTheme.textMuted)
                        .frame(width: Self.stageCancelWidth, height: Self.stageControlHeight)
                        .background(Color.white.opacity(0.085), in: Circle())
                        .frame(minWidth: 44, minHeight: Self.stageWellHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .typrControlReveal(
                    showRecordingControls,
                    reduceMotion: reduceMotion,
                    scale: 0.90,
                    blur: 2.5,
                    anchor: .leading
                )

                Spacer(minLength: 0)

                Button {
                    withAnimation(TyprMotion.stageAnimation(reduceMotion: reduceMotion)) {
                        dictation.finishRecording()
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TyprTheme.textBase)
                        .frame(width: Self.stageDoneWidth, height: Self.stageControlHeight)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .frame(minHeight: Self.stageWellHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .typrControlReveal(
                    showRecordingControls,
                    reduceMotion: reduceMotion,
                    scale: 0.90,
                    blur: 2.5,
                    anchor: .trailing
                )
            }
            .padding(.horizontal, Self.stageInset)

            HStack(spacing: 12) {
                Text(dictation.modelPreparation.detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TyprTheme.textMuted)
                ModelPreparationIndicator(progress: dictation.modelPreparation)
                    .tint(TyprTheme.textBase)
            }
            .padding(.horizontal, 18)
            .typrControlReveal(showPreparing, reduceMotion: reduceMotion, scale: 0.96, blur: 2.0)

            Text("Allow microphone access…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TyprTheme.textMuted)
                .typrControlReveal(showPermission, reduceMotion: reduceMotion, scale: 0.96, blur: 2.0)

            Button {
                withAnimation(TyprMotion.stageAnimation(reduceMotion: reduceMotion)) {
                    dictation.performPrimaryAction()
                }
            } label: {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: primaryActionIcon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TyprTheme.textMuted)
                        Text(primaryActionLabel)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(TyprTheme.textBase)
                    }
                    .frame(width: idleWidth, height: Self.stageControlHeight)
                    .background(Color.white.opacity(0.09), in: Capsule())
                }
                .padding(.horizontal, Self.stageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .typrControlReveal(
                showIdleTrigger,
                reduceMotion: reduceMotion,
                scale: 0.92,
                blur: 2.5,
                anchor: .trailing
            )
        }
        .frame(height: Self.stageWellHeight)
        .clipShape(Capsule())
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = dictation.lastLoggedTranscriptID,
               let entry = DictationLogStore.shared.entry(id), entry.status == .finished {
                HStack {
                    Button("Good", systemImage: entry.rating == "good" ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        DictationLogStore.shared.rate(id, rating: "good")
                    }
                    Button("Problem", systemImage: entry.rating == "bad" ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                        DictationLogStore.shared.rate(id, rating: "bad")
                    }
                }.buttonStyle(.bordered).frame(minHeight: 44)
                if entry.rating == "bad" {
                    Text("Add categories and a note in History & feedback.")
                        .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                }
            }
            Text(dictation.transcript)
                .font(.system(size: 17))
                .lineSpacing(3)
                .foregroundStyle(TyprTheme.textBase)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Spacer()

                Button(dictation.copied ? "Copied" : "Copy") {
                    dictation.copyTranscript()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(dictation.copied ? TyprTheme.success : TyprTheme.textBase)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.white.opacity(0.09), in: Capsule())

                Button("Clear") {
                    withAnimation(TyprMotion.settleAnimation(reduceMotion: reduceMotion)) {
                        dictation.clearTranscript()
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TyprTheme.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.white.opacity(0.055), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            TyprTheme.bgBase,
            in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius, style: .continuous)
        )
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            SettingsWarmDurationRow(selected: dictation.warmDuration) { duration in
                withAnimation(TyprMotion.settleAnimation(reduceMotion: reduceMotion)) {
                    dictation.selectWarmDuration(duration)
                }
            }

            rowDivider

            NavigationLink(value: SettingsDestination.speechEngine) {
                SettingsLink(title: "Speech engine", detail: "On-device recognition and downloads",
                             value: dictation.preferredEngine?.shortName ?? "Automatic")
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink(value: SettingsDestination.language) {
                SettingsLink(title: "Language", detail: "Recognition language and engine compatibility",
                             value: dictation.dictationLanguage.label)
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink(value: SettingsDestination.style) {
                SettingsLink(title: "Style", detail: "How your dictation is formatted",
                             value: dictation.style.label)
            }
            .buttonStyle(.plain)

            rowDivider

            Toggle(
                isOn: Binding(
                    get: { dictation.allowBluetoothMic },
                    set: { dictation.setAllowBluetoothMic($0) }
                )
            ) {
                rowTitle("Bluetooth microphone")
            }
            .tint(TyprTheme.success)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
        }
        .background(
            TyprTheme.bgBase,
            in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius, style: .continuous)
        )
    }

    private var practiceField: some View {
        TextField("Write something…", text: $practiceText, axis: .vertical)
            .font(.body)
            .foregroundStyle(TyprTheme.textBase)
            .focused($practiceFocused)
            .lineLimit(1...4)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                TyprTheme.bgBase,
                in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius, style: .continuous)
            )
            .onAppear {
                if Self.autoFocusPracticeField {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        practiceFocused = true
                    }
                }
            }
    }

    // MARK: - Cold-Start Handoff Screen (unified bar + home-indicator swipe cue)

    private var keyboardHandoffView: some View {
        GeometryReader { geo in
            let bottomInset: CGFloat = Self.simulatesHomeButtonDevice ? 0 : geo.safeAreaInsets.bottom
            let hasHomeIndicator = bottomInset > 0

            let mode = appStageMode
            let showScope = handoffScopePhase != .hidden
            let showRecordingControls = mode == .recording
            let showFailedRetry = mode == .failed
            let showPreparing = mode == .preparing
            let status = handoffStatusLine
            let isAutoReturning: Bool = {
                switch dictation.autoReturnState {
                case .attempting, .succeeded:
                    return true
                case .idle, .swipeFallback:
                    return false
                }
            }()
            let showSwipeBack = (showRecordingControls || dictation.keyboardSessionEnabled) && !isAutoReturning
            let showHomeSwipeCue = hasHomeIndicator && showSwipeBack

            let handoffWellHeight: CGFloat = 52
            let handoffControlHeight: CGFloat = 38
            let handoffInset: CGFloat = 7
            let handoffCancelWidth: CGFloat = 38
            let handoffDoneWidth: CGFloat = 74
            let leadInset: Float = showRecordingControls
                ? Float(handoffInset + handoffCancelWidth + 6)
                : 0.0
            let trailInset: Float = showRecordingControls
                ? Float(handoffInset + handoffDoneWidth + 6)
                : 0.0

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 9) {
                        TyprMarkView(
                            size: 20,
                            color: showRecordingControls ? TyprTheme.warmPearl : TyprTheme.textBase
                        )

                        Text("Typr")
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(TyprTheme.textBase)

                        Spacer()

                        Button("Settings") {
                            openedFromKeyboard = false
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TyprTheme.textMuted)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Centered unified dictation stage platter
                    VStack(spacing: 14) {
                        ZStack {
                            HStack(spacing: 6) {
                                TyprStatusDot(color: TyprTheme.danger, size: 6.5)
                                AppRecordingClockLabel(dictation: dictation)
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .typrTrayReveal(showRecordingControls, reduceMotion: reduceMotion, offsetY: 2)

                            Text(status ?? " ")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(TyprTheme.textMuted)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .typrTrayReveal(!showRecordingControls && status != nil, reduceMotion: reduceMotion, offsetY: 2)
                        }
                        .frame(minHeight: 28)

                        ZStack {
                            ZStack {
                                TyprRecessedWell(isDark: true)

                                DotScopeView(
                                    phase: handoffScopePhase,
                                    tuning: .bar(leadingInset: leadInset, trailingInset: trailInset, fade: 30.0, spacing: 3.5),
                                    drawPlate: false,
                                    loudnessProvider: { [weak dictation] in dictation?.loudnessDB ?? -120.0 }
                                )
                                .clipShape(Capsule())
                                .allowsHitTesting(false)

                                HStack(spacing: 10) {
                                    Button {
                                        withAnimation(TyprMotion.stageAnimation(reduceMotion: reduceMotion)) {
                                            dictation.cancelCurrentJob()
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(TyprTheme.textMuted)
                                            .frame(width: handoffCancelWidth, height: handoffControlHeight)
                                            .background(Color.white.opacity(0.085), in: Circle())
                                            .frame(minWidth: 44, minHeight: handoffWellHeight, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Cancel")
                                    .typrControlReveal(
                                        showRecordingControls,
                                        reduceMotion: reduceMotion,
                                        scale: 0.90,
                                        blur: 2.5,
                                        anchor: .leading
                                    )

                                    Spacer(minLength: 0)

                                    Button {
                                        withAnimation(TyprMotion.stageAnimation(reduceMotion: reduceMotion)) {
                                            dictation.finishRecording()
                                        }
                                    } label: {
                                        Text("Done")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(TyprTheme.textBase)
                                            .frame(width: handoffDoneWidth, height: handoffControlHeight)
                                            .background(Color.white.opacity(0.15), in: Capsule())
                                            .frame(minHeight: handoffWellHeight, alignment: .trailing)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .typrControlReveal(
                                        showRecordingControls,
                                        reduceMotion: reduceMotion,
                                        scale: 0.90,
                                        blur: 2.5,
                                        anchor: .trailing
                                    )
                                }
                                .padding(.horizontal, handoffInset)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: handoffWellHeight)
                            .clipShape(Capsule())
                            .typrControlReveal(showScope, reduceMotion: reduceMotion, scale: 0.96, blur: 0.0)

                            VStack(spacing: 12) {
                                ModelPreparationIndicator(progress: dictation.modelPreparation)
                                    .tint(TyprTheme.textBase)
                                    .frame(maxWidth: 200)
                                    .typrControlReveal(showPreparing, reduceMotion: reduceMotion, scale: 0.96, blur: 2.0)

                                Button("Try again") {
                                    withAnimation(TyprMotion.stageAnimation(reduceMotion: reduceMotion)) {
                                        dictation.prepareModel()
                                    }
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(TyprTheme.textBase)
                                .padding(.horizontal, 18)
                                .frame(height: 36)
                                .background(Color.white.opacity(0.15), in: Capsule())
                                .buttonStyle(.plain)
                                .typrControlReveal(showFailedRetry, reduceMotion: reduceMotion, scale: 0.94, blur: 2.5)
                            }
                            .typrControlReveal(showPreparing || showFailedRetry, reduceMotion: reduceMotion, scale: 0.96, blur: 2.5)
                        }
                        .frame(minHeight: handoffWellHeight)
                    }
                    .frame(maxWidth: .infinity)

                    Spacer()

                    // Keeps the stage clear of the home-indicator swipe cue.
                    Color.clear
                        .frame(height: hasHomeIndicator ? 60 : 44)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Full-bottom-width Home-Indicator return cue (21 pt flush with screen bottom => center 10.5 pt
                // above bottom edge, aligned dead-on the iOS Home Indicator pill across the full screen width).
                if hasHomeIndicator {
                    VStack(spacing: 3) {
                        Text("Swipe bar to return")
                            .font(.system(size: 11.5, weight: .medium))
                            .tracking(0.1)
                            .foregroundStyle(TyprTheme.textFaint)
                            .opacity(showHomeSwipeCue ? 1 : 0)

                        DotSwipeCueView(isActive: showHomeSwipeCue)
                            .frame(width: geo.size.width, height: 21)
                    }
                    .allowsHitTesting(false)
                    .offset(y: bottomInset)
                }
            }
            .animation(TyprMotion.stageAnimation(reduceMotion: reduceMotion), value: mode)
            .animation(TyprMotion.settleAnimation(reduceMotion: reduceMotion), value: showHomeSwipeCue)
        }
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Pieces

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(TyprTheme.textBase)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(TyprTheme.borderWeak)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(TyprTheme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(TyprTheme.textBase)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            TyprTheme.dangerSurface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var primaryActionLabel: String {
        switch dictation.phase {
        case .modelRequired, .failed:
            "Set up"
        default:
            "Dictate"
        }
    }

    private var primaryActionIcon: String {
        switch dictation.phase {
        case .modelRequired, .failed:
            "arrow.down"
        default:
            "mic.fill"
        }
    }

    private var handoffStatusLine: String? {
        if let notice = dictation.handoffNotice {
            return notice
        }
        if case .attempting = dictation.autoReturnState {
            return "Returning…"
        }
        switch dictation.phase {
        case .failed(let message):
            return message
        case .requestingPermission:
            return "Allow microphone access"
        case .preparingModel:
            return dictation.modelPreparation.detail
        case .transcribing:
            return "Transcribing…"
        case .ready where dictation.keyboardSessionEnabled:
            return "Ready"
        default:
            return nil
        }
    }
}

#Preview {
    ContentView(
        dictation: DictationController.shared,
        openedFromKeyboard: .constant(false),
        showSetup: .constant(false)
    )
}
