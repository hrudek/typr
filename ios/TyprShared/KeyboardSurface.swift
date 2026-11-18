import Combine
import SwiftUI
import UIKit

@MainActor
final class KeyboardClockModel: ObservableObject {
    @Published private(set) var recordingText: String = "0:00"
    @Published private(set) var warmRemainingText: String = "15m"

    func update(recordingElapsed: TimeInterval?, warmRemaining: TimeInterval?) {
        if let recordingElapsed {
            let formatted = TyprTheme.formatClock(recordingElapsed)
            if formatted != recordingText {
                recordingText = formatted
            }
        }
        if let warmRemaining, warmRemaining > 0 {
            let formatted = TyprTheme.formatRemaining(warmRemaining)
            if formatted != warmRemainingText {
                warmRemainingText = formatted
            }
        }
    }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    enum PickerTray: Equatable {
        case none
        case style
    }

    enum StagePhase: Equatable {
        case idle
        case recording
        case transcribing
        case failed
    }

    struct PendingCommand: Equatable {
        let kind: KeyboardCommandKind
        let jobID: String
        let sentAt: TimeInterval
    }

    static let commandAckTimeout: TimeInterval = 1.6

    let clock = KeyboardClockModel()

    @Published var hasFullAccess = true
    @Published var needsGlobeKey = true
    @Published var globeKey = GlobeKey.switches
    @Published var bottomRow = BottomRow()
    @Published var returnKeyLabel = "Return"
    @Published var isModelInstalled = false
    @Published private(set) var isWarmAvailable = false
    @Published private(set) var stagePhase: StagePhase = .idle
    @Published private(set) var statusMessage: String?
    @Published var style: DictationStyle = .polished
    /// Why a cold start did not open Typr here (a share sheet or other surface Typr cannot return to).
    @Published var hostNotice: String?
    @Published var activeTray: PickerTray = .none
    /// Typr: the utility row starts with a key that shows the full keyboard.
    @Published var showsFullKeyboardSwitch = false
    var problemPanelDuration: TimeInterval = 6
    private var problemCloseWork: DispatchWorkItem?
    @Published var feedback: DictationFeedbackPresentation? {
        didSet {
            guard feedback?.offer != oldValue?.offer || feedback?.panelContent != oldValue?.panelContent else { return }
            problemCloseWork?.cancel()
            guard let feedback, feedback.panelContent == .problem else { return }
            let offer = feedback.offer
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.feedback?.offer == offer,
                      self.feedback?.panelContent == .problem else { return }
                self.dismissFeedback()
            }
            problemCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + problemPanelDuration, execute: work)
        }
    }
    var onFeedbackRating: ((String, [String]?) -> Void)?
    func dismissFeedback() { feedback = nil }

    /// Shared rating behavior; queue failures restore a retry panel on either surface.
    func rateFeedback(_ rating: String, issues: [String]? = nil) {
        onFeedbackRating?(rating, issues)
        if rating == "bad" { feedback?.rating = "bad" }
        else { dismissFeedback() }
    }

    // Non-published live telemetry read directly by `DotScopeHostView` / button tap handlers
    // so 25–30 Hz polling never invalidates SwiftUI views mid-spring.
    var liveLoudnessDB: Float = -62.0
    var currentTimestamp: TimeInterval = Date().timeIntervalSince1970
    private(set) var currentSnapshot: KeyboardSnapshot = .offline
    private(set) var pendingCommand: PendingCommand?

    var onDictateTap: (() -> Void)?
    var onStopTap: (() -> Void)?
    var onCancelTap: (() -> Void)?
    var onStyleSelected: ((DictationStyle) -> Void)?
    /// Opens Typr to start the microphone, then returns to this app (`KeyboardViewController.coldStart`).
    var onColdStart: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    /// Typr: the full-keyboard key was tapped.
    var onShowFullKeyboard: (() -> Void)?
    var onNextKeyboard: (() -> Void)?
    weak var inputViewController: UIInputViewController?

    var dotScopePhase: DotScopePhase {
        switch stagePhase {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .transcribing:
            return .processing
        case .failed:
            return .failed
        }
    }

    func setActiveTray(_ tray: PickerTray, reduceMotion: Bool) {
        guard activeTray != tray else { return }
        withAnimation(TyprMotion.trayAnimation(reduceMotion: reduceMotion)) {
            activeTray = tray
        }
    }

    func setPendingCommand(_ command: PendingCommand?, now: TimeInterval, animated: Bool) {
        currentTimestamp = now
        pendingCommand = command
        reconcileVisualState(
            hasFullAccess: hasFullAccess,
            snapshot: currentSnapshot,
            isModelInstalled: isModelInstalled,
            style: style,
            now: now,
            animated: animated
        )
    }

    func applyBridgeState(
        hasFullAccess newFullAccess: Bool,
        snapshot storedSnapshot: KeyboardSnapshot,
        isModelInstalled newModelInstalled: Bool,
        style newStyle: DictationStyle,
        now: TimeInterval,
        clearPending: Bool = false,
        animated: Bool
    ) {
        let newSnapshot = storedSnapshot.live(at: now)
        currentTimestamp = now
        currentSnapshot = newSnapshot
        liveLoudnessDB = newSnapshot.state == .recording ? newSnapshot.effectiveLoudnessDB : -62.0

        if clearPending {
            pendingCommand = nil
        } else if let pending = pendingCommand {
            let expired = now - pending.sentAt >= Self.commandAckTimeout
            let acknowledged = (pending.kind == .start && newSnapshot.state == .recording)
                || (pending.kind == .stop && newSnapshot.state != .recording)
                || (pending.kind == .cancel && newSnapshot.state != .recording)
            if expired || acknowledged {
                pendingCommand = nil
            }
        }

        let recordingElapsed: TimeInterval? = if newSnapshot.state == .recording {
            newSnapshot.recordingElapsed(at: now)
        } else if let pending = pendingCommand, pending.kind == .start {
            max(0, now - pending.sentAt)
        } else {
            nil
        }
        let warmRemaining: TimeInterval? = newSnapshot.isAvailable(at: now)
            ? max(0, newSnapshot.expiresAt - now)
            : nil
        clock.update(recordingElapsed: recordingElapsed, warmRemaining: warmRemaining)

        reconcileVisualState(
            hasFullAccess: newFullAccess,
            snapshot: newSnapshot,
            isModelInstalled: newModelInstalled,
            style: newStyle,
            now: now,
            animated: animated
        )
    }

    /// Convenience for deterministic preview/snapshot fixtures (`KeyboardPreviewHost`).
    func configureFixture(
        snapshot: KeyboardSnapshot,
        now: TimeInterval,
        hasFullAccess: Bool = true,
        isModelInstalled: Bool = true,
        style: DictationStyle = .polished,
        activeTray: PickerTray = .none
    ) {
        self.activeTray = activeTray
        applyBridgeState(
            hasFullAccess: hasFullAccess,
            snapshot: snapshot,
            isModelInstalled: isModelInstalled,
            style: style,
            now: now,
            clearPending: true,
            animated: false
        )
    }

    private func reconcileVisualState(
        hasFullAccess newFullAccess: Bool,
        snapshot snap: KeyboardSnapshot,
        isModelInstalled newModelInstalled: Bool,
        style newStyle: DictationStyle,
        now: TimeInterval,
        animated: Bool
    ) {
        let nextWarm = newFullAccess && snap.isAvailable(at: now)
        let nextStage = computeStagePhase(snapshot: snap, now: now, hasFullAccess: newFullAccess)
        let trimmedMsg = snap.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextMessage = (trimmedMsg?.isEmpty == false) ? trimmedMsg : nil

        let changed = hasFullAccess != newFullAccess
            || isWarmAvailable != nextWarm
            || isModelInstalled != newModelInstalled
            || stagePhase != nextStage
            || statusMessage != nextMessage
            || style != newStyle

        guard changed else { return }

        let commit = {
            self.hasFullAccess = newFullAccess
            self.isWarmAvailable = nextWarm
            self.isModelInstalled = newModelInstalled
            self.stagePhase = nextStage
            self.statusMessage = nextMessage
            self.style = newStyle
        }

        if animated {
            withAnimation(TyprMotion.stageAnimation(reduceMotion: UIAccessibility.isReduceMotionEnabled)) {
                commit()
            }
        } else {
            commit()
        }
    }

    private func computeStagePhase(
        snapshot snap: KeyboardSnapshot,
        now: TimeInterval,
        hasFullAccess: Bool
    ) -> StagePhase {
        guard hasFullAccess else { return .idle }

        if let pending = pendingCommand, now - pending.sentAt < Self.commandAckTimeout {
            switch pending.kind {
            case .cancel:
                return .idle
            case .stop where snap.state == .recording:
                return .transcribing
            case .start where snap.state != .recording:
                return .recording
            default:
                break
            }
        }

        switch snap.state {
        case .recording:
            return .recording
        case .transcribing:
            return .transcribing
        case .failed:
            return .failed
        case .offline, .ready:
            return .idle
        }
    }
}

private struct GlobeKeyRepresentable: UIViewRepresentable {
    weak var controller: UIInputViewController?
    let isDark: Bool

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        config.baseForegroundColor = isDark
            ? UIColor(white: 0.92, alpha: 1)
            : UIColor(red: 0x14 / 255.0, green: 0x16 / 255.0, blue: 0x1B / 255.0, alpha: 1)
        button.configuration = config
        button.accessibilityLabel = "Next keyboard"
        if let controller {
            button.addTarget(
                controller,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        uiView.configuration?.baseForegroundColor = isDark
            ? UIColor(white: 0.92, alpha: 1)
            : UIColor(red: 0x14 / 255.0, green: 0x16 / 255.0, blue: 0x1B / 255.0, alpha: 1)
    }
}

private struct KeyboardChromePalette {
    let isDark: Bool
    let isHosted: Bool

    var textBase: Color {
        isDark
            ? TyprTheme.textBase
            : Color(red: 0x14 / 255.0, green: 0x16 / 255.0, blue: 0x1B / 255.0)
    }

    var textMuted: Color {
        isDark
            ? TyprTheme.textMuted
            : Color(red: 0x4E / 255.0, green: 0x54 / 255.0, blue: 0x61 / 255.0)
    }

    var chipIdleFill: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
    }

    var chipActiveFill: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    var topBarPressedFill: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }

    var controlSubtleFill: Color {
        isDark ? Color.white.opacity(0.085) : Color.black.opacity(0.065)
    }

    var controlProminentFill: Color {
        isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.11)
    }

    var idleTriggerFill: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }

    var keyFill: Color {
        if !isHosted { return Color.white.opacity(0.085) }
        return isDark ? Color.white.opacity(0.105) : Color.white
    }

    var keyPressedFill: Color {
        if !isHosted { return Color.white.opacity(0.16) }
        return isDark ? Color.white.opacity(0.19) : Color(white: 0.88)
    }

    var keyShadow: Color {
        Color.black.opacity(isDark ? 0.24 : 0.14)
    }
}

private struct KeyboardKeyButtonStyle: ButtonStyle {
    let palette: KeyboardChromePalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? palette.keyPressedFill : palette.keyFill,
                in: RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous)
            )
            .shadow(color: palette.keyShadow, radius: 0.5, x: 0, y: 1)
    }
}

private struct TopBarTriggerButtonStyle: ButtonStyle {
    let palette: KeyboardChromePalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? palette.topBarPressedFill : Color.clear,
                in: Capsule()
            )
    }
}

private struct RepeatDeleteKey: View {
    let palette: KeyboardChromePalette
    let onDelete: () -> Void
    @State private var isPressing = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(palette.textBase)
            .frame(width: 52, height: 42)
            .background(
                isPressing ? palette.keyPressedFill : palette.keyFill,
                in: RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous)
            )
            .shadow(color: palette.keyShadow, radius: 0.5, x: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressing else { return }
                        isPressing = true
                        onDelete()
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(360))
                            while !Task.isCancelled {
                                onDelete()
                                try? await Task.sleep(for: .milliseconds(75))
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressing = false
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
            )
            .accessibilityLabel("Delete")
    }
}

private struct KeyboardRecordingClockText: View {
    @ObservedObject var clock: KeyboardClockModel
    let color: Color

    var body: some View {
        Text(clock.recordingText)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(color)
            .animation(.easeOut(duration: 0.16), value: clock.recordingText)
    }
}

private struct KeyboardWarmRemainingText: View {
    @ObservedObject var clock: KeyboardClockModel
    let color: Color

    var body: some View {
        Text(clock.warmRemainingText)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(color)
    }
}

extension View {
    /// iOS 26's soft scroll-edge effect blurs the whole content of a short
    /// scroll view (the 26 pt return-app tray), so turn it off there.
    /// Earlier versions have no edge effect and are left unchanged.
    @ViewBuilder
    func typrScrollEdgeEffectHidden() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

enum KeyboardSetupCopy {
    static let fullAccessPath = "Allow Full Access: Settings › Apps › Typr › Keyboards"
}

struct KeyboardSurfaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: KeyboardViewModel
    @State private var spaceHeldForNextKeyboard = false

    private static let wellHeight: CGFloat = 44
    private static let controlHeight: CGFloat = 34
    private static let wellInset: CGFloat = 5
    private static let cancelWidth: CGFloat = 34
    private static let doneWidth: CGFloat = 66

    private var isHostedExtension: Bool {
        model.inputViewController != nil
    }

    private var palette: KeyboardChromePalette {
        KeyboardChromePalette(
            isDark: !isHostedExtension || colorScheme == .dark,
            isHosted: isHostedExtension
        )
    }

    private var isStageActive: Bool {
        model.stagePhase == .recording || model.stagePhase == .transcribing
    }

    var body: some View {
        VStack(spacing: 8) {
            topBar
            primaryStage
            utilityRow
        }
        .padding(.horizontal, 10)
        .padding(.top, isHostedExtension ? 4 : 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isHostedExtension ? Color.clear : TyprTheme.bgDeep)
        .accessibilityHidden(model.hasFullAccess && model.feedback != nil && !isStageActive)
        .overlay {
            if model.hasFullAccess, model.feedback != nil, !isStageActive {
                TyprFeedbackTray(model: model)
                    .background(Color(uiColor: FullKeyboardPalette(isDark: palette.isDark).backdrop))
            }
        }
        .preferredColorScheme(isHostedExtension ? nil : .dark)
    }

    // MARK: - Top Bar (26 pt, permanently mounted ZStack)

    private var topBar: some View {
        let p = palette
        return ZStack {
            Group {
                defaultTopBar(palette: p)
            }
                .typrTrayReveal(model.activeTray == .none, reduceMotion: reduceMotion, offsetY: -3)

            styleTrayBar(palette: p)
                .typrTrayReveal(model.activeTray == .style, reduceMotion: reduceMotion, offsetY: 3.5)
        }
        .frame(height: 26)
    }

    private func defaultTopBar(palette p: KeyboardChromePalette) -> some View {
        HStack(spacing: 8) {
            Button {
                if model.hasFullAccess {
                    model.onColdStart?()
                } else {
                    model.onOpenURL?(KeyboardLaunchRequest.setup.url)
                }
            } label: {
                TyprMarkView(
                    size: 16,
                    color: isStageActive && p.isDark ? TyprTheme.warmPearl : p.textBase
                )
                .frame(width: 22, height: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Typr")

            leadingAccessory(palette: p)

            Spacer(minLength: 4)

            styleTrigger(palette: p)
                .typrTrayReveal(model.hasFullAccess, reduceMotion: reduceMotion, offsetY: 0)
        }
        .frame(height: 26)
    }

    private func styleTrayBar(palette p: KeyboardChromePalette) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(DictationStyle.allCases, id: \.self) { candidate in
                        let active = candidate == model.style
                        Button {
                            model.onStyleSelected?(candidate)
                            model.setActiveTray(.none, reduceMotion: reduceMotion)
                        } label: {
                            Text(candidate.label)
                                .font(.system(size: 13, weight: .medium))
                                .fixedSize()
                                .foregroundStyle(active ? p.textBase : p.textMuted)
                                .padding(.horizontal, 11)
                                .frame(height: 26)
                                .background(active ? p.chipActiveFill : p.chipIdleFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            closeTrayButton(palette: p)
        }
        .frame(height: 26)
    }

    private func leadingAccessory(palette p: KeyboardChromePalette) -> some View {
        let showNoAccess = !model.hasFullAccess
        let showRecordingClock = model.hasFullAccess && model.stagePhase == .recording
        let showWarmStatus = model.hasFullAccess
            && model.isWarmAvailable
            && model.stagePhase != .recording
            && model.stagePhase != .transcribing
        let showHostNotice = model.hasFullAccess
            && model.hostNotice != nil
            && !model.isWarmAvailable
            && model.stagePhase != .recording
            && model.stagePhase != .transcribing

        return ZStack(alignment: .leading) {
            HStack(spacing: 6) {
                TyprStatusDot(color: TyprTheme.warmMic, size: 6)
                Text(KeyboardSetupCopy.fullAccessPath)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(p.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Full Access is off. \(KeyboardSetupCopy.fullAccessPath)")
            .typrTrayReveal(showNoAccess, reduceMotion: reduceMotion, offsetY: 2)

            HStack(spacing: 6) {
                TyprStatusDot(color: TyprTheme.danger, size: 6.5)
                KeyboardRecordingClockText(clock: model.clock, color: p.textBase)
            }
            .typrTrayReveal(showRecordingClock, reduceMotion: reduceMotion, offsetY: 2)

            Group {
                if let message = model.statusMessage {
                    HStack(spacing: 6) {
                        if model.stagePhase == .failed {
                            TyprStatusDot(color: TyprTheme.danger, size: 6)
                        }
                        Text(message)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(p.textMuted)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 5) {
                        TyprStatusDot(color: TyprTheme.warmMic, size: 6)
                        KeyboardWarmRemainingText(clock: model.clock, color: p.textMuted)
                    }
                }
            }
            .typrTrayReveal(showWarmStatus, reduceMotion: reduceMotion, offsetY: 2)

            Text(model.hostNotice ?? " ")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(p.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .typrTrayReveal(showHostNotice, reduceMotion: reduceMotion, offsetY: 2)
        }
    }

    private func styleTrigger(palette p: KeyboardChromePalette) -> some View {
        Button {
            model.setActiveTray(.style, reduceMotion: reduceMotion)
        } label: {
            HStack(spacing: 4) {
                Text(model.style.label)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(p.textMuted)
            }
            .foregroundStyle(p.textMuted)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(TopBarTriggerButtonStyle(palette: p))
        .accessibilityLabel("Style: \(model.style.label)")
    }

    private func closeTrayButton(palette p: KeyboardChromePalette) -> some View {
        Button {
            model.setActiveTray(.none, reduceMotion: reduceMotion)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(p.textMuted)
                .frame(width: 26, height: 26)
                .background(p.chipIdleFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    // MARK: - Unified 44 pt Recessed Stage Well (all controls permanently mounted)

    private var idleTriggerSpec: (icon: String, title: String, width: CGFloat) {
        if !model.hasFullAccess {
            return ("arrow.up.forward.app.fill", "Set up Typr", 112)
        }
        if !model.isModelInstalled {
            return ("mic.fill", "Set up", 88)
        }
        return ("mic.fill", "Dictate", 94)
    }

    private var primaryStage: some View {
        let p = palette
        let showRecordingControls = model.stagePhase == .recording
        let showIdleTrigger = model.stagePhase == .idle || model.stagePhase == .failed
        let spec = idleTriggerSpec

        let leadInset: Float = showRecordingControls
            ? Float(Self.wellInset + Self.cancelWidth + 6)
            : 0.0
        let trailInset: Float = if showRecordingControls {
            Float(Self.wellInset + Self.doneWidth + 6)
        } else if showIdleTrigger {
            Float(Self.wellInset + spec.width + 6)
        } else {
            0.0
        }

        return ZStack {
            TyprRecessedWell(isDark: p.isDark)

            DotScopeView(
                phase: model.dotScopePhase,
                tuning: .bar(leadingInset: leadInset, trailingInset: trailInset, fade: 28.0, spacing: 3.5),
                drawPlate: false,
                loudnessProvider: { [weak model] in model?.liveLoudnessDB ?? -62.0 }
            )
            .clipShape(Capsule())
            .allowsHitTesting(false)

            // Recording peer controls (`✕` and `Done`), always mounted so enter/exit springs stay continuous.
            HStack(spacing: 8) {
                Button {
                    model.onCancelTap?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.textMuted)
                        .frame(width: Self.cancelWidth, height: Self.controlHeight)
                        .background(p.controlSubtleFill, in: Circle())
                        .frame(minWidth: 44, minHeight: Self.wellHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel dictation")
                .typrControlReveal(
                    showRecordingControls,
                    reduceMotion: reduceMotion,
                    scale: 0.90,
                    blur: 2.5,
                    anchor: .leading
                )

                Spacer(minLength: 0)

                Button {
                    model.onStopTap?()
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.textBase)
                        .frame(width: Self.doneWidth, height: Self.controlHeight)
                        .background(p.controlProminentFill, in: Capsule())
                        .frame(minHeight: Self.wellHeight, alignment: .trailing)
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
            .padding(.horizontal, Self.wellInset)

            // Single permanently mounted idle trigger (never swapped across 3 Button branches).
            Button {
                handleIdleStageTap()
            } label: {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: spec.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(p.textMuted)
                        Text(spec.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(p.textBase)
                    }
                    .frame(width: spec.width, height: Self.controlHeight)
                    .background(p.idleTriggerFill, in: Capsule())
                }
                .padding(.horizontal, Self.wellInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spec.title)
            .typrControlReveal(
                showIdleTrigger,
                reduceMotion: reduceMotion,
                scale: 0.92,
                blur: 2.5,
                anchor: .trailing
            )
        }
        .frame(height: Self.wellHeight)
        .clipShape(Capsule())
    }

    private func handleIdleStageTap() {
        if !model.hasFullAccess {
            model.onOpenURL?(KeyboardLaunchRequest.setup.url)
        } else if !model.isWarmAvailable || model.stagePhase == .failed {
            model.onColdStart?()
        } else {
            model.onDictateTap?()
        }
    }

    // MARK: - Bottom Utility Key Row (42 pt, shadow-grounded keycaps with zero strokes)

    private var utilityRow: some View {
        let p = palette
        return HStack(spacing: 6) {
            if model.showsFullKeyboardSwitch { // Typr
                Button {
                    model.onShowFullKeyboard?()
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(p.textBase)
                        .frame(width: 44, height: 42)
                        .contentShape(RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(KeyboardKeyButtonStyle(palette: p))
                .disabled(isStageActive)
                .accessibilityLabel("Show full keyboard")
            }

            if model.needsGlobeKey, model.globeKey != .hidden {
                Group {
                    if model.globeKey == .switches {
                        GlobeKeyRepresentable(controller: model.inputViewController, isDark: p.isDark)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(p.textBase.opacity(0.35))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 44, height: 42)
                .background(
                    p.keyFill,
                    in: RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous)
                )
                .shadow(color: p.keyShadow, radius: 0.5, x: 0, y: 1)
            }

            Button {
                if spaceHeldForNextKeyboard {
                    spaceHeldForNextKeyboard = false
                } else {
                    model.onSpace?()
                }
            } label: {
                Text("space")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(p.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .contentShape(RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(KeyboardKeyButtonStyle(palette: p))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: FullKeyboardEngine.nextKeyboardHoldDelay)
                    .onChanged { _ in spaceHeldForNextKeyboard = false }
                    .onEnded { _ in
                        spaceHeldForNextKeyboard = true
                        model.onNextKeyboard?()
                    },
                isEnabled: model.needsGlobeKey && model.globeKey != .switches
            )

            RepeatDeleteKey(palette: p) {
                model.onDelete?()
            }

            Button {
                model.onReturn?()
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(p.textBase)
                    .frame(width: 56, height: 42)
                    .contentShape(RoundedRectangle(cornerRadius: TyprTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(KeyboardKeyButtonStyle(palette: p))
            .accessibilityLabel(model.returnKeyLabel)
        }
    }
}
